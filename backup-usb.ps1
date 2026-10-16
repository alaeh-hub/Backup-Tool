# backup-usb.ps1 - back up this PC/laptop to the plugged-in backup drive (restic: encrypted,   [hacker-ui edition]
# keeps history, only copies what changed). Runs from the drive itself on any PC.
# If no backup drive is plugged in, the script does nothing and exits.
#
# Usage:
#   Run-Backup.cmd                      (asks which folders and file types)
#   backup-usb.ps1                      (no questions: uses this PC's saved choices, or the defaults)
#   backup-usb.ps1 -Ask                 (always ask)
#   backup-usb.ps1 -Folders documents,music -Extensions pdf,docx,jpg -MaxFileSize 2G
#   backup-usb.ps1 -DryRun              (show what would happen, write nothing)
#   backup-usb.ps1 -Check               (force an integrity check this run)
#   backup-usb.ps1 -NoAnim | -Plain     (no animation / no colors + ASCII only)
#   backup-usb.ps1 -TrustRestic         (run a restic.exe whose SHA-256 is not on the trusted list)
#
# Safety: restic.exe is hash-checked; the vault password can be saved Windows-encrypted (DPAPI) on this PC
#         instead of as plain text on the drive; after a backup you are asked whether to run another one.
#
# Folder names: documents, desktop, downloads, pictures, videos, music, home, onedrive,
#               repos, ssh, appdata  - or any full path such as D:\Work
#
# The theme only appears when a person is at the keyboard. Scheduled / unattended runs print
# nothing and write backup-log.txt exactly as before. All numbers on screen come from restic.

param(
    [switch]$Ask,
    [switch]$DryRun,
    [switch]$Check,
    [string[]]$Folders,
    [string[]]$Extensions,
    [string]$MaxFileSize,
    [switch]$NoAnim,
    [switch]$Plain,
    [switch]$TrustRestic
)

# ================= CONFIG =================
# Looked up next to this script first, so it works straight from the backup drive.
# If restic-pass.txt isn't next to it, the script asks for the password.
$ResticCandidates = @("$PSScriptRoot\restic.exe", "C:\Backup\restic.exe")
$PasswordFile  = Join-Path $PSScriptRoot "restic-pass.txt"
$LogFile       = Join-Path $PSScriptRoot "backup-log.txt"
$SettingsFile  = Join-Path $PSScriptRoot "backup-settings-$($env:COMPUTERNAME).json"
$MaxLogMB      = 5

# Only use drives with this label (so personal USB sticks are ignored). "" = any USB drive.
$DriveLabel    = "COMPANY"
$FolderOnDrive = "CompanyBackup"
$HealthcheckUrl = ""          # Healthchecks.io ping URL ("" to disable)
$ShowPopup     = $true

# Used when nothing was chosen and nothing was saved yet
$DefaultFolderNames = @('documents', 'pictures', 'videos', 'music', 'downloads', 'ssh')

# Single quotes on purpose: '~$*' must not be treated as a PowerShell variable.
$ExcludeFilePatterns = @('*.tmp', '~$*', 'Thumbs.db', 'desktop.ini', '*.iso')
$ExcludeDirNames     = @('node_modules', '.gradle', '.cache', '__pycache__', '.venv', 'venv',
                         '$RECYCLE.BIN', 'System Volume Information')

$KeepDaily = 7; $KeepWeekly = 4; $KeepMonthly = 6
$MinFreeGB = 5
$CheckEveryDays = 7

# File-type groups offered in the picker
$TypeGroups = [ordered]@{
    'Office and documents' = 'doc docx xls xlsx ppt pptx pdf txt rtf odt ods odp csv md'
    'Pictures'             = 'jpg jpeg png gif bmp webp heic tif tiff svg raw cr2 nef arw'
    'Videos'               = 'mp4 mkv mov avi wmv webm m4v'
    'Music'                = 'mp3 wav flac m4a aac ogg wma'
    'Code and projects'    = 'cs py js ts tsx jsx html css java kt dart json xml yml yaml sql sh ps1 php go rs c cpp h sln'
    'Archives'             = 'zip rar 7z tar gz'
}
$Version = '2.1'
# ==========================================

$ErrorActionPreference = 'Continue'
$script:ExitCode = 0
$Interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
$script:Prog = 'backup'
$script:Quiet = -not ($Interactive -or $Ask)      # unattended run => the UI prints nothing at all

$script:E   = [string][char]27
$script:Rng = New-Object System.Random

# --- capability detection -------------------------------------------------------------
$script:IsTty = $true
try { if ([Console]::IsOutputRedirected) { $script:IsTty = $false } } catch { }
if ($env:HACKERUI_FORCE_TTY -eq '1') { $script:IsTty = $true }   # for testing only

$script:Color = $script:IsTty -and -not $Plain -and -not $env:NO_COLOR -and $env:TERM -ne 'dumb'
if ($script:Color) {
    # make sure the Windows console actually interprets ANSI escapes
    try {
        Add-Type -Namespace HK -Name Vt -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int m);
'@ -ErrorAction Stop
        $h = [HK.Vt]::GetStdHandle(-11); $m = 0
        if ([HK.Vt]::GetConsoleMode($h, [ref]$m)) { [void][HK.Vt]::SetConsoleMode($h, ($m -bor 4)) }
    } catch { }
}
$script:Fast = $NoAnim -or $Plain -or -not $script:IsTty -or [bool]$env:HACKERUI_FAST

# --- glyphs (unicode on a real terminal, ASCII when plain) ----------------------------
$script:Uni = $script:IsTty -and -not $Plain
if ($script:Uni) {
    $G = @{ tl='╔'; tr='╗'; bl='╚'; br='╝'; h='═'; v='║'; hl='─'; full='█'; empty='░'; dir='▸'; dot='·'
            pt='┌──['; pm=']──['; pb=']'; pl='└─' }
} else {
    $G = @{ tl='+'; tr='+'; bl='+'; br='+'; h='='; v='|'; hl='-'; full='#'; empty='.'; dir='>'; dot='.'
            pt='--['; pm=']--['; pb=']'; pl='`-' }
}

# --- primitives -----------------------------------------------------------------------
function C([int]$code, [string]$text) {
    if ($script:Color) { return "$($script:E)[38;5;${code}m$text$($script:E)[0m" }
    return $text
}
function W([string]$s = '')  { if (-not $script:Quiet) { [Console]::Out.WriteLine($s) } }
function Wn([string]$s)      { if (-not $script:Quiet) { [Console]::Out.Write($s); [Console]::Out.Flush() } }
function Strip([string]$s)   { [regex]::Replace($s, "$($script:E)\[[0-9;?]*[A-Za-z]", '') }
function Nap([int]$ms)       { if (-not $script:Fast) { Start-Sleep -Milliseconds $ms } }
function Term-Width {
    try { return [Math]::Max(60, [Math]::Min(100, [Console]::WindowWidth - 2)) } catch { return 80 }
}
# any keypress during an animation skips all remaining animation
function Test-Skip {
    if ($script:Fast) { return $true }
    try { if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); $script:Fast = $true; return $true } } catch { }
    return $false
}

function Type-Out([string]$text, [int]$code = 220, [int]$ms = 10) {
    if ($script:Fast -or -not $script:Color) { W (C $code $text); return }
    foreach ($ch in $text.ToCharArray()) {
        if (Test-Skip) { Wn (C $code $text.Substring($text.IndexOf($ch))); break }
        Wn (C $code ([string]$ch))
        Start-Sleep -Milliseconds ($ms + $script:Rng.Next(-4, 8))
    }
    W
}

# noise that resolves into the real text, left to right
function Glitch([string]$text, [int]$code = 255) {
    if ($script:Fast -or -not $script:Color) { W (C $code $text); return }
    $noise = '#$%&@01<>/\|{}[]=+*?'.ToCharArray()
    for ($i = 0; $i -le $text.Length; $i++) {
        if (Test-Skip) { break }
        for ($f = 0; $f -lt 2; $f++) {
            $tail = -join ($text.Substring($i).ToCharArray() | ForEach-Object { if ($_ -eq ' ') { ' ' } else { $noise[$script:Rng.Next($noise.Length)] } })
            Wn ("`r" + (C $code $text.Substring(0, $i)) + (C 94 $tail))
            Start-Sleep -Milliseconds 14
        }
    }
    Wn "`r$($script:E)[K"; W (C $code $text)
}

function Tag([string]$k) {
    switch ($k) {
        'ok'   { C 220  '[  OK  ]' } 'warn' { C 202 '[ WARN ]' } 'fail' { C 196 '[ FAIL ]' }
        'info' { C 208  '[ INFO ]' } 'run'  { C 94  '[ .... ]' } 'pwn'  { C 124 '[ PWND ]' }
        default { '[  --  ]' }
    }
}
function Status([string]$k, [string]$msg, [string]$extra = '') {
    $line = "  $(Tag $k) $msg"
    if ($extra) { $line += "  $(C 240 $extra)" }
    W $line
}

# a [ .... ] line that flips to [  OK  ] / [ FAIL ] once the work is really done
$script:StepLabel = ''
$script:StepClock = $null
function Step-Start([string]$label) {
    $script:StepLabel = $label
    $script:StepClock = [Diagnostics.Stopwatch]::StartNew()
    if ($script:Color -and -not $script:Fast) { Wn "  $(Tag 'run') $label" }
}
function Step-End([string]$kind, [string]$detail = '') {
    $ms = $script:StepClock.ElapsedMilliseconds
    if ($script:Color -and -not $script:Fast) { Wn "`r$($script:E)[K" }
    Status $kind $script:StepLabel $(if ($detail) { "$detail  (${ms}ms)" } else { "${ms}ms" })
}
# transient spinner line for slow reads; leaves no trace when done
function Working([string]$label, [scriptblock]$work) {
    $animate = $script:Color -and -not $script:Fast
    if ($animate) { Wn "  $(Tag 'run') $(C 240 $label)" }
    try { return @(& $work) }
    finally { if ($animate) { Wn "`r$($script:E)[K" } }
}

function Rule([string]$title = '') {
    $w = Term-Width
    if ($title) {
        $left = "$($G.hl)$($G.hl)[ "; $right = " ]"
        $fill = [Math]::Max(2, $w - $left.Length - $title.Length - $right.Length)
        W ("`n" + (C 94 $left) + (C 208 $title) + (C 94 ($right + ($G.hl * $fill))))
    } else { W (C 94 ($G.hl * $w)) }
}
function Header([string]$t) { Rule $t }

# elide the middle of long paths so boxes stay aligned
function Short([string]$s, [int]$max = 0) {
    if ($max -le 0) { $max = (Term-Width) - 16 }
    if ($s.Length -le $max) { return $s }
    $keep = $max - 3; $head = [int][Math]::Ceiling($keep * 0.4)
    return $s.Substring(0, $head) + '...' + $s.Substring($s.Length - ($keep - $head))
}

function Box([string]$title, [string[]]$lines, [int]$edge = 220) {
    $inner = $title.Length + 4
    foreach ($l in $lines) { $inner = [Math]::Max($inner, (Strip $l).Length + 2) }
    $inner = [Math]::Min($inner, (Term-Width) - 2)
    $top = "$($G.tl)$($G.h) $title " + ($G.h * [Math]::Max(0, $inner - $title.Length - 3)) + $G.tr
    W (C $edge $top)
    foreach ($l in $lines) {
        $pad = [Math]::Max(0, $inner - (Strip $l).Length - 1)
        W ((C $edge $G.v) + ' ' + $l + (' ' * $pad) + (C $edge $G.v))
    }
    W (C $edge ($G.bl + ($G.h * $inner) + $G.br))
}

# --- logo.png -> true-colour half-block pixel art (needs a real terminal; silently skipped otherwise) ---
$script:LogoRows = $null
function Get-LogoRows([int]$size = 32) {
    if ($script:LogoRows) { return $script:LogoRows }
    if (-not $script:Color -or -not $script:Uni) { return $null }
    $path = Join-Path $PSScriptRoot 'logo.png'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $src = [System.Drawing.Image]::FromFile($path)
        $bmp = New-Object System.Drawing.Bitmap $size, $size
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Black)
        $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'HighQuality'; $g.PixelOffsetMode = 'HighQuality'
        $g.DrawImage($src, 0, 0, $size, $size)
        $g.Dispose(); $src.Dispose()
        $e = $script:E; $rows = @()
        for ($y = 0; $y -lt $size; $y += 2) {
            $sb = New-Object System.Text.StringBuilder
            for ($x = 0; $x -lt $size; $x++) {
                $t = $bmp.GetPixel($x, $y); $b = $bmp.GetPixel($x, $y + 1)
                $tDark = [Math]::Max($t.R, [Math]::Max($t.G, $t.B)) -lt 24
                $bDark = [Math]::Max($b.R, [Math]::Max($b.G, $b.B)) -lt 24
                if ($tDark -and $bDark) { [void]$sb.Append("$e[0m ") }
                elseif ($tDark)         { [void]$sb.Append("$e[0m$e[38;2;$($b.R);$($b.G);$($b.B)m" + [char]0x2584) }
                elseif ($bDark)         { [void]$sb.Append("$e[0m$e[38;2;$($t.R);$($t.G);$($t.B)m" + [char]0x2580) }
                else                    { [void]$sb.Append("$e[38;2;$($t.R);$($t.G);$($t.B);48;2;$($b.R);$($b.G);$($b.B)m" + [char]0x2580) }
            }
            [void]$sb.Append("$e[0m"); $rows += $sb.ToString()
        }
        $bmp.Dispose()
        $script:LogoRows = $rows
        return $rows
    } catch { return $null }
}
function Banner {
    $art = @(
        '██████╗  █████╗  ██████╗██╗  ██╗██╗   ██╗██████╗ ',
        '██╔══██╗██╔══██╗██╔════╝██║ ██╔╝██║   ██║██╔══██╗',
        '██████╔╝███████║██║     █████╔╝ ██║   ██║██████╔╝',
        '██╔══██╗██╔══██║██║     ██╔═██╗ ██║   ██║██╔═══╝ ',
        '██████╔╝██║  ██║╚██████╗██║  ██╗╚██████╔╝██║     ',
        '╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝     '
    )
    $logo = $null
    try { if ([Console]::WindowWidth -ge 98) { $logo = Get-LogoRows } } catch { }
    if (-not $script:Uni) {
        W
        W '  A L A   E H !   ::   B A C K U P'
        W ('  ' + (C 240 "host $($env:COMPUTERNAME.ToLower())  |  user $($env:USERNAME.ToLower())  |  $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"))
        return
    }
    $shade = 226, 220, 220, 214, 208, 172
    $right = @()
    $right += (C 226 'A L A   E H !') + (C 94 '   ::   ') + (C 255 'F O O D   P R O D U C T S')
    $right += ''
    for ($i = 0; $i -lt $art.Count; $i++) { $right += (C $shade[$i] $art[$i]) }
    $right += ''
    $right += (C 208 'specially made recipe sa panlasang pinoy')
    $right += (C 220 "usb vault backup  ::  v$Version")
    $right += (C 240 "host $($env:COMPUTERNAME.ToLower())  |  user $($env:USERNAME.ToLower())  |  $((Get-Date).ToString('yyyy-MM-dd HH:mm'))")
    $right += (C 94 'press any key during animations to skip')
    W
    if ($logo) {
        $pad = ' ' * 32; $off = [Math]::Max(0, [int](($logo.Count - $right.Count) / 2))
        for ($i = 0; $i -lt $logo.Count; $i++) {
            $r = if ($i -ge $off -and ($i - $off) -lt $right.Count) { $right[$i - $off] } else { '' }
            W ('  ' + $logo[$i] + '  ' + $r); Nap 30
        }
    } else {
        foreach ($r in $right) { W ('  ' + $r); Nap 30 }
    }
}

function Invoke-Rain([int]$ms = 1100) {
    if ($script:Fast -or -not $script:Color) { return }
    try { $w = [Math]::Min([Console]::WindowWidth, 160); $h = [Console]::WindowHeight - 1 } catch { return }
    if ($w -lt 20 -or $h -lt 8) { return }
    $e = $script:E
    $glyphs = '01<>/\|#$%&@:;=+*~^'.ToCharArray()
    $head = New-Object 'int[]' $w
    for ($x = 0; $x -lt $w; $x++) { $head[$x] = -$script:Rng.Next(0, $h) }
    $sb = New-Object System.Text.StringBuilder
    Wn "$e[?1049h$e[?25l$e[2J"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($clock.ElapsedMilliseconds -lt $ms) {
            if (Test-Skip) { break }
            [void]$sb.Clear()
            for ($x = 0; $x -lt $w; $x += 2) {
                $y = $head[$x]
                foreach ($cell in @(@(0, 230), @(-1, 220), @(-4, 94), @(-9, -1))) {
                    $row = $y + $cell[0]
                    if ($row -lt 0 -or $row -ge $h) { continue }
                    $ch = if ($cell[1] -lt 0) { ' ' } else { $glyphs[$script:Rng.Next($glyphs.Length)] }
                    $col = if ($cell[1] -lt 0) { '' } else { "$e[38;5;$($cell[1])m" }
                    [void]$sb.Append("$e[$($row + 1);$($x + 1)H$col$ch")
                }
                $head[$x] = $y + 1
                if ($y -gt $h + 9) { $head[$x] = -$script:Rng.Next(0, 8) }
            }
            Wn $sb.ToString()
            Start-Sleep -Milliseconds 26
        }
    } finally { Wn "$e[0m$e[?25h$e[?1049l" }
}

# styled two-line prompt; returns trimmed text ('q' on EOF)
function Ask([string]$label, [string]$hint = '') {
    $hintText = if ($hint) { '  ' + (C 240 $hint) } else { '' }
    Wn ("`n  " + (C 94 $G.pt) + (C 208 $script:Prog) + (C 94 $G.pm) + (C 255 $label) + (C 94 $G.pb) + $hintText + "`n  " + (C 94 $G.pl) + (C 220 '$ '))
    $a = [Console]::In.ReadLine()
    if ($null -eq $a) { return 'q' }
    return $a.Trim()
}


# Ask for a number (or several). Returns int[]; $null = quit.
function Pick([string]$prompt, [int]$count, [switch]$Multi) {
    while ($true) {
        $a = Ask $prompt
        if ($a -match '^(q|quit|exit)$') { return $null }
        if ($Multi -and $a -match '^all$') { return 1..$count }
        $nums = @($a -split '[,\s]+' | Where-Object { $_ })
        $ok = $nums.Count -gt 0 -and ($Multi -or $nums.Count -eq 1)
        foreach ($n in $nums) { if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt $count) { $ok = $false } }
        if ($ok) { return @($nums | ForEach-Object { [int]$_ }) }
        Status 'warn' "enter a number from 1 to $count$(if ($Multi) { ' (or several like 1,3 / all)' }), or q to quit."
    }
}

function Menu-Line([int]$n, [string]$text, [string]$extra = '') {
    $line = '  ' + (C 94 '[') + (C 255 ('{0,2}' -f $n)) + (C 94 ']') + ' ' + $text
    if ($extra) { $line += '  ' + (C 240 $extra) }
    W $line
}

function Fmt-Size($b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) } else { "$b B" }
}
function Fmt-Span($sec) { $t = [TimeSpan]::FromSeconds([Math]::Max(0, [Math]::Round($sec))); '{0:00}:{1:00}' -f [int][Math]::Floor($t.TotalMinutes), $t.Seconds }

# real progress bar, driven by numbers restic reports
$script:BarLast = -1
function Draw-Bar([double]$pct, [string]$right, [string]$note = '') {
    $width = 34
    $filled = [int][Math]::Floor($pct * $width)
    $bar = (C 220 ($G.full * $filled)) + (C 94 ($G.empty * ($width - $filled)))
    $line = '  ' + (C 94 '[') + $bar + (C 94 ']') + ' ' + (C 255 ('{0,5:N1}%' -f ($pct * 100))) + '  ' + (C 240 $right)
    if ($note) { $line += '  ' + (C 202 $note) }
    if ($script:Color -and -not $script:Fast) { Wn ("`r$($script:E)[K" + $line) }
    else {
        $bucket = [int][Math]::Floor($pct * 10)          # plain mode: one line per 10%
        if ($bucket -gt $script:BarLast) { $script:BarLast = $bucket; W $line }
    }
}



# ---- shared helpers: yes/no + restic trust -------------------------------------------
function Ask-Again([string]$question) {
    $a = Ask $question
    return [bool]($a -match '^(y|yes)$')
}
# SHA-256 of the restic builds this tool trusts (restic 0.19.1, windows/amd64).
# Upgrading restic? Run once with -TrustRestic, then add the printed hash here.
$TrustedResticSha256 = @('b0dd1fd21eea5d8fe1325f55f7118213c21f36de8a261e04c0624a5ab9fd7830')
function Get-FileSha256([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function Get-ResticVersion([string]$exe) {
    try { return ((("$(& $exe version 2>&1)") -replace '^restic\s+', '' -replace '\s+compiled.*$', '')) } catch { return '?' }
}

function Log($msg) {
    try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch { }
}
function LogLines { process { $line = "$_".TrimEnd(); if ($line) { Log $line } } }

function Rotate-Log {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt ($MaxLogMB * 1MB)) { Move-Item $LogFile "$LogFile.old" -Force }
    } catch { }
}
function Ping($suffix) {
    if ($HealthcheckUrl) { try { Invoke-RestMethod -Uri "$HealthcheckUrl$suffix" -TimeoutSec 15 | Out-Null } catch { } }
}
function Notify($text) {
    if ($ShowPopup -and [Environment]::UserInteractive) {
        try { (New-Object -ComObject WScript.Shell).Popup($text, 8, "Backup", 64) | Out-Null } catch { }
    }
}

# Friendly folder names -> real paths on THIS PC (follows OneDrive redirection). $null = unknown/missing.
function Resolve-Folder([string]$name) {
    $n = "$name".Trim().Trim('"').TrimEnd('\')
    if (-not $n) { return $null }
    if ($n -match '^[A-Za-z]:' -or $n -match '^\\\\') {
        if ($n -match '^[A-Za-z]:$') { $n += '\' }
        if (Test-Path -LiteralPath $n) { return (Resolve-Path -LiteralPath $n).ProviderPath }
        return $null
    }
    $p = switch -regex ($n.ToLower()) {
        '^(documents|docs|my documents)$' { [Environment]::GetFolderPath('MyDocuments') }
        '^desktop$'                       { [Environment]::GetFolderPath('Desktop') }
        '^downloads?$'                    { Join-Path $env:USERPROFILE 'Downloads' }
        '^(pictures|photos|images)$'      { [Environment]::GetFolderPath('MyPictures') }
        '^(videos|movies)$'               { [Environment]::GetFolderPath('MyVideos') }
        '^music$'                         { [Environment]::GetFolderPath('MyMusic') }
        '^(home|profile|user)$'           { $env:USERPROFILE }
        '^onedrive$'                      { $env:OneDrive }
        '^(repos|source|projects)$'       { Join-Path $env:USERPROFILE 'source\repos' }
        '^ssh$'                           { Join-Path $env:USERPROFILE '.ssh' }
        '^appdata$'                       { $env:APPDATA }
        default                           { $null }
    }
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    return $null
}

# Remove duplicates and folders already covered by a parent folder in the list
function Reduce-Folders($list) {
    $l = @($list | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') } | Select-Object -Unique)
    @($l | Where-Object {
        $f = $_
        -not ($l | Where-Object { $_ -ne $f -and $f.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) })
    })
}

function Normalize-Ext($list) {
    @($list | ForEach-Object { "$_" -split '[,;\s]+' } | Where-Object { $_ } |
        ForEach-Object { $_.TrimStart('*', '.').ToLower() } | Where-Object { $_ } | Select-Object -Unique)
}

function Parse-Size([string]$s) {
    if (-not $s) { return 0 }
    if ($s -match '^\s*(\d+(\.\d+)?)\s*([kmgt])?b?\s*$') {
        $v = [double]$Matches[1]
        switch ($Matches[3]) { 'k' { $v *= 1KB } 'm' { $v *= 1MB } 'g' { $v *= 1GB } 't' { $v *= 1TB } }
        return [long]$v
    }
    return -1
}

function Read-Choice([string]$prompt, [string]$hint = '') {
    $a = Ask $prompt $hint
    if ($a -match '^(q|quit|exit)$') { Status 'info' 'cancelled. nothing was written.'; exit 0 }
    "$a".Trim()
}

# ---- Interactive picker: which folders and which file types ----
function Pick-Selection($current) {
    Header '1. which folders?'
    $opts = @()
    foreach ($nm in 'documents', 'desktop', 'downloads', 'pictures', 'videos', 'music', 'home', 'onedrive', 'repos', 'ssh') {
        $p = Resolve-Folder $nm
        if ($p -and -not ($opts | Where-Object { $_.Path -ieq $p })) { $opts += [pscustomobject]@{ Name = $nm; Path = $p } }
    }
    for ($i = 0; $i -lt $opts.Count; $i++) { Menu-Line ($i + 1) (C 208 ('{0,-10}' -f $opts[$i].Name)) $opts[$i].Path }
    W
    W ('  ' + (C 240 'numbers ') + (C 255 '1,3,4') + (C 240 '  a name ') + (C 255 'documents') + (C 240 '  a full path ') + (C 255 'D:\Work') + (C 240 '  or a mix, comma separated'))
    $curTxt = if ($current.Folders.Count) { ($current.Folders -join '; ') } else { '' }
    $hint = if ($curTxt) { "Enter = keep: $(Short $curTxt)" } else { '' }
    while ($true) {
        $a = Read-Choice 'folders' $hint
        if (-not $a) { $chosen = $current.Folders; break }
        $chosen = @(); $bad = @()
        foreach ($tok in ($a -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            if ($tok -match '^\d+$' -and [int]$tok -ge 1 -and [int]$tok -le $opts.Count) { $chosen += $opts[[int]$tok - 1].Path }
            else { $r = Resolve-Folder $tok; if ($r) { $chosen += $r } else { $bad += $tok } }
        }
        if ($bad.Count) { Status 'warn' "not found / not understood: $($bad -join ', '). use a number, a known name, or a full path."; continue }
        break
    }
    $chosen = Reduce-Folders $chosen
    if (-not $chosen.Count) { Status 'info' 'no folders chosen.'; exit 0 }

    Header '2. which file types?'
    Menu-Line 1 (C 220 'Everything (all file types)')
    $gi = 2; $groupKeys = @($TypeGroups.Keys)
    foreach ($k in $groupKeys) { Menu-Line $gi (C 208 ('{0,-22}' -f $k)) ($TypeGroups[$k] -replace ' ', ', '); $gi++ }
    Menu-Line $gi (C 208 'Custom: type your own extensions')
    W
    W ('  ' + (C 240 'combine with commas, e.g. ') + (C 255 '2,3') + (C 240 ' = documents + pictures'))
    $curExt = if ($current.Extensions.Count) { ($current.Extensions -join ', ') } else { 'everything' }
    $hint = "Enter = keep: $(Short $curExt)"
    $exts = @()
    while ($true) {
        $a = Read-Choice 'file types' $hint
        if (-not $a) { $exts = $current.Extensions; break }
        $nums = @($a -split '[,\s]+' | Where-Object { $_ })
        $ok = $true; foreach ($n in $nums) { if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt $gi) { $ok = $false } }
        if (-not $ok) { Status 'warn' "enter numbers from 1 to $gi."; continue }
        $exts = @()
        if ($nums -contains '1') { $exts = @(); break }
        foreach ($n in $nums) {
            $n = [int]$n
            if ($n -eq $gi) {
                $c = Normalize-Ext (Read-Choice 'extensions' 'e.g. pdf,dwg,psd')
                if (-not $c.Count) { Status 'warn' 'no extensions entered.'; $exts = $null; break }
                $exts += $c
            } else { $exts += Normalize-Ext $TypeGroups[$groupKeys[$n - 2]] }
        }
        if ($null -eq $exts) { continue }
        $exts = Normalize-Ext $exts
        break
    }

    Header '3. skip very large files?'
    W ('  ' + (C 240 'examples: ') + (C 255 '500M') + (C 240 ', ') + (C 255 '2G') + (C 240 "   Enter = no limit$(if ($current.MaxSize) { ' (current: ' + $current.MaxSize + ')' })"))
    while ($true) {
        $a = Read-Choice 'max file size'
        if (-not $a) { $ms = $current.MaxSize; break }
        if ($a -match '^(none|no|0)$') { $ms = ''; break }
        if ((Parse-Size $a) -gt 0) { $ms = $a.ToUpper(); break }
        Status 'warn' 'use a size like 500M or 2G.'
    }
    [pscustomobject]@{ Folders = @($chosen); Extensions = @($exts); MaxSize = $ms }
}

# Build the list of files to back up (used when file types are filtered) and count them
function Get-FileList($folders, $exts, $maxBytes) {
    $extSet = @{}; foreach ($e in $exts) { $extSet[".$e"] = $true }
    $dirRx = '(^|[\\/])(' + (($ExcludeDirNames | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')([\\/]|$)'
    $skipAttr = 0x400000 -bor 0x40000 -bor 0x1000      # online-only OneDrive/offline placeholders
    $files = New-Object System.Collections.Generic.List[string]; $bytes = [long]0
    foreach ($f in $folders) {
        Get-ChildItem -LiteralPath $f -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if ($exts.Count -and -not $extSet.ContainsKey($_.Extension.ToLower())) { return }
            if (([int]$_.Attributes -band $skipAttr) -ne 0) { return }
            if ($maxBytes -gt 0 -and $_.Length -gt $maxBytes) { return }
            if ($_.FullName -match $dirRx) { return }
            foreach ($pat in $ExcludeFilePatterns) { if ($_.Name -like $pat) { return } }
            $files.Add($_.FullName); $bytes += $_.Length
        }
    }
    [pscustomobject]@{ Files = $files; Bytes = $bytes }
}

# ---- Password storage -------------------------------------------------------------------
# Typed passwords can be saved ENCRYPTED with Windows DPAPI on THIS PC: only this Windows user on this
# PC can decrypt it, and it never sits on the backup drive. (A plain restic-pass.txt still works but is
# offered for conversion.)
$CredDir  = Join-Path $env:LOCALAPPDATA 'UsbBackup'
$CredFile = Join-Path $CredDir "vault-$($env:COMPUTERNAME).cred"

function ConvertTo-Plain([securestring]$sec) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
function Load-Cred {
    if (-not (Test-Path -LiteralPath $CredFile)) { return $null }
    try {
        $sec = (Get-Content -LiteralPath $CredFile -Raw -ErrorAction Stop).Trim() | ConvertTo-SecureString -ErrorAction Stop
        $p = ConvertTo-Plain $sec; $sec.Dispose()
        if ($p) { return $p }
    } catch { Log "WARNING: saved password could not be decrypted (different user/PC?)" }
    return $null
}
function Save-Cred([string]$plain) {
    try {
        New-Item -ItemType Directory -Force -Path $CredDir | Out-Null
        ConvertTo-SecureString $plain -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -LiteralPath $CredFile -Encoding ASCII
        try { & icacls.exe $CredFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" 2>&1 | Out-Null } catch { }
        Log "Encrypted password saved for this PC and user"
        return $true
    } catch { Log "WARNING: could not save the encrypted password: $($_.Exception.Message)"; return $false }
}
# best-effort wipe: overwrite with zeros, then delete (SSD/flash wear-levelling can keep old copies)
function Remove-PlainFile([string]$path) {
    try {
        $len = (Get-Item -LiteralPath $path).Length
        [IO.File]::WriteAllBytes($path, (New-Object byte[] ([Math]::Max($len, 1))))
        Remove-Item -LiteralPath $path -Force
        return $true
    } catch { return $false }
}
function Request-Password {
    Wn ("`n  " + (C 94 $G.pt) + (C 208 'backup') + (C 94 $G.pm) + (C 202 'password (hidden)') + (C 94 $G.pb) + "`n")
    $sec = Read-Host "  $($G.pl)`$ " -AsSecureString
    $plain = ConvertTo-Plain $sec; $sec.Dispose()
    if (-not $plain) { return $false }
    $env:RESTIC_PASSWORD = $plain
    return $true
}
function Get-Base([string]$repo) {
    $b = @('--repo', $repo)
    if ($script:UsePasswordFile) { $b += @('--password-file', $PasswordFile) }   # otherwise RESTIC_PASSWORD is used
    return $b
}

# ---- Pre-flight ----
Rotate-Log
if (-not $script:Quiet) { Invoke-Rain; Banner }
Header 'pre-flight'

# restic is only taken from places you control (this folder, C:\Backup, PATH) - other drives are never scanned
Step-Start 'locating restic engine'
$ResticExe = $ResticCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $ResticExe) { $cmd = Get-Command restic -ErrorAction SilentlyContinue; if ($cmd) { $ResticExe = $cmd.Source } }
if (-not $ResticExe) {
    Log "ERROR: restic not found (tried: $($ResticCandidates -join ', '))"
    Step-End 'fail'; Status 'fail' 'restic.exe not found next to this script.'; exit 1
}
$resticHash = Get-FileSha256 $ResticExe
$resticVer = Get-ResticVersion $ResticExe
if ($TrustedResticSha256 -contains $resticHash) {
    Step-End 'ok' "$ResticExe  [$resticVer]  sha256 $($resticHash.Substring(0, 12)) verified"
} else {
    Step-End 'warn' "$ResticExe  [$resticVer]" "sha256 $resticHash is NOT on the trusted list"
    Log "WARNING: restic.exe sha256 $resticHash is not on the trusted list"
    $okToRun = $TrustRestic
    if (-not $okToRun -and $Interactive) { $okToRun = Ask-Again 'this restic.exe is not recognised. run it anyway? (y/n)' }
    if (-not $okToRun) {
        Log "ERROR: refusing to run an unrecognised restic.exe (sha256 $resticHash). Run interactively or pass -TrustRestic once, then add the hash to the script."
        Status 'fail' 'refusing to run an unrecognised restic.exe (see backup-log.txt).'
        Notify "Backup NOT run: restic.exe is not recognised. See the log."
        exit 1
    }
}

# Legacy plain-text password file next to the script (still supported, but see the offer to convert it)
$script:UsePasswordFile = (Test-Path -LiteralPath $PasswordFile) -and ((Get-Item -LiteralPath $PasswordFile).Length -gt 0)
$script:PwSource = if ($script:UsePasswordFile) { 'file' } else { '' }
if ($script:UsePasswordFile) {
    try { & icacls.exe $PasswordFile /inheritance:r /grant:r "$($env:USERNAME):(R)" "SYSTEM:(R)" "Administrators:(R)" 2>&1 | Out-Null } catch { }
}

$mutex = New-Object System.Threading.Mutex($false, "Local\CompanyUsbBackup")
$hasMutex = $false
try { $hasMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $hasMutex = $true }
if (-not $hasMutex) { Log "Another backup is already running, exiting"; Status 'warn' 'another backup is already running.'; exit 0 }

$script:ListFile = $null
$script:LastSel = $null
$script:SaveOffered = $false
$script:AskAgain = $false

# One complete backup: choose what -> scan -> confirm -> transfer -> prune -> check.
# Sets $script:AskAgain when it is worth offering another run.
function Invoke-BackupRun([bool]$ForcePick) {
    $script:AskAgain = $false

    # ---- 1. Look for plugged-in backup drives ----
    Step-Start 'scanning USB ports for vault'
    $drives = @(
        Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq 'USB' } |
            Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } |
            Get-Volume | Where-Object { $_.FileSystem -and $_.DriveType -in 'Removable', 'Fixed' }
    )
    if ($DriveLabel) { $drives = @($drives | Where-Object { $_.FileSystemLabel -eq $DriveLabel }) }

    if ($drives.Count -eq 0) {
        # Quiet in the log (scheduled runs happen often), but tell a person at the keyboard
        Step-End 'warn' "no backup drive found (looking for a USB drive labelled '$DriveLabel')"
        return
    }
    Step-End 'ok' ("vault online: " + (($drives | ForEach-Object { "$($_.DriveLetter): '$($_.FileSystemLabel)' ($([math]::Round($_.SizeRemaining / 1GB, 1)) GB free)" }) -join ', '))

    # ---- 2. Password: password file > encrypted copy saved on this PC > ask ----
    if (-not $script:UsePasswordFile -and -not $env:RESTIC_PASSWORD) {
        $stored = Load-Cred
        if ($stored) {
            $env:RESTIC_PASSWORD = $stored; $script:PwSource = 'stored'
            Status 'info' 'using the encrypted password saved on this PC'
        } elseif (-not $Interactive) {
            Log "ERROR: no saved password and not interactive, cannot ask for the password (run Run-Backup.cmd once and choose to save it)"
            Status 'fail' 'no saved password and nobody at the keyboard.'
            exit 1
        } else {
            Header 'authentication'
            Status 'info' 'backup drive found. enter the backup password.'
            if (-not (Request-Password)) { Log "ERROR: empty password"; Status 'fail' 'empty password.'; exit 1 }
            $script:PwSource = 'typed'
        }
    } elseif ($script:UsePasswordFile) { Status 'warn' 'using a plain-text password file next to the script' }

    # ---- 3. What to back up: picker > parameters > saved choices > defaults ----
    $saved = $null
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $j = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
            $saved = [pscustomobject]@{
                Folders    = @($j.Folders | ForEach-Object { Resolve-Folder $_ } | Where-Object { $_ })
                Extensions = Normalize-Ext $j.Extensions
                MaxSize    = "$($j.MaxSize)"
            }
        } catch { Log "WARNING: could not read $SettingsFile, ignoring it" }
    }
    $defaultFolders = Reduce-Folders ($DefaultFolderNames | ForEach-Object { Resolve-Folder $_ })
    $current = if ($saved -and $saved.Folders.Count) { $saved } else { [pscustomobject]@{ Folders = $defaultFolders; Extensions = @(); MaxSize = '' } }

    $sel = $null; $fromPicker = $false
    if ($ForcePick) {
        $sel = Pick-Selection $(if ($script:LastSel) { $script:LastSel } else { $current }); $fromPicker = $true
    }
    elseif ($Folders -or $Extensions -or $MaxFileSize) {
        $fl = @(); $bad = @()
        if ($Folders) {
            foreach ($t in ($Folders | ForEach-Object { $_ -split ',' } | Where-Object { $_ })) {
                $r = Resolve-Folder $t; if ($r) { $fl += $r } else { $bad += $t }
            }
            if ($bad.Count) { Log "ERROR: unknown or missing folder(s): $($bad -join ', ')"; Status 'fail' "unknown or missing folder(s): $($bad -join ', '). use a known name or a full path."; exit 1 }
        } else { $fl = $current.Folders }
        $sel = [pscustomobject]@{
            Folders    = @(Reduce-Folders $fl)
            Extensions = $(if ($Extensions) { Normalize-Ext $Extensions } else { $current.Extensions })
            MaxSize    = $(if ($MaxFileSize) { $MaxFileSize.ToUpper() } else { $current.MaxSize })
        }
    }
    elseif ($Ask -or ($Interactive -and -not $saved)) {
        $sel = Pick-Selection $current; $fromPicker = $true
    }
    else { $sel = $current }
    $script:LastSel = $sel

    $maxBytes = Parse-Size $sel.MaxSize
    if ($maxBytes -lt 0) { Log "ERROR: bad -MaxFileSize '$($sel.MaxSize)'"; Status 'fail' "bad max file size '$($sel.MaxSize)'. use e.g. 500M or 2G."; exit 1 }
    if (-not $sel.Folders.Count) { Log "ERROR: none of the configured folders exist"; Status 'fail' 'none of the chosen folders exist on this PC.'; exit 1 }

    # ---- 4. Scan (counts, size, and the file list when filtering by type) ----
    $filtering = $sel.Extensions.Count -gt 0
    Header 'recon'
    $null = Working 'scanning your files' { $script:scan = Get-FileList $sel.Folders $sel.Extensions $maxBytes }
    $scan = $script:scan
    $extTxt = if ($filtering) { ($sel.Extensions -join ', ') } else { 'everything' }
    $summary = "{0} files, {1}" -f $scan.Files.Count, (Fmt-Size $scan.Bytes)
    Status 'ok' "scan complete" $summary
    $brief = @(((C 240 'payload   ') + (C 255 $summary)))
    foreach ($f in $sel.Folders) { $brief += ((C 240 'folder    ') + (C 208 (Short $f))) }
    $brief += ((C 240 'types     ') + (C 220 (Short $extTxt)))
    $brief += ((C 240 'max size  ') + (C 220 $(if ($sel.MaxSize) { $sel.MaxSize } else { 'no limit' })))
    if ($DryRun) { $brief += ((C 240 'mode      ') + (C 202 'DRY RUN - nothing will be written')) }
    W
    Box 'MISSION BRIEF' $brief 208
    Log "Selection: folders=[$($sel.Folders -join '; ')] types=[$extTxt] max=[$($sel.MaxSize)] -> $summary"

    if ($scan.Files.Count -eq 0) { Log "Nothing matches the selection, nothing to back up"; Status 'warn' 'no files match that selection. nothing to do.'; $script:AskAgain = $true; return }

    if ($fromPicker) {
        if (-not (Ask-Again 'start the backup? (y/n)')) { Status 'info' 'cancelled. nothing was written.'; $script:AskAgain = $true; return }
        if (Ask-Again 'remember these choices on this PC for next time and for scheduled runs? (y/n)') {
            try {
                [pscustomobject]@{ Folders = $sel.Folders; Extensions = $sel.Extensions; MaxSize = $sel.MaxSize } |
                    ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
                Status 'ok' 'choices saved' $SettingsFile
            } catch { Status 'warn' "could not save the choices: $($_.Exception.Message)" }
        }
    }

    # Snapshots with different selections are kept separately (tag), so a small backup
    # never replaces the history of a bigger one.
    $selKey = (($sel.Folders | Sort-Object) -join '|') + '#' + (($sel.Extensions | Sort-Object) -join ',') + '#' + $sel.MaxSize
    $sha = [Security.Cryptography.SHA1]::Create()
    $selTag = 'sel-' + ((($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($selKey.ToLower())) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8))

    # When filtering by type, hand restic the exact file list (random name, removed afterwards)
    if ($filtering) {
        $script:ListFile = Join-Path $env:TEMP ("backup-list-" + [IO.Path]::GetRandomFileName() + ".txt")
        [IO.File]::WriteAllLines($script:ListFile, $scan.Files, (New-Object Text.UTF8Encoding($false)))
    }

    Ping "/start"
    $anyFailed = $false
    $anySucceeded = $false
    $script:AskAgain = $true

    # ---- 5. Back up to each matching drive ----
    foreach ($vol in $drives) {
        $letter = $vol.DriveLetter
        $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
        $repo   = "${letter}:\$FolderOnDrive\$env:COMPUTERNAME"

        Header "vault ${letter}:"
        Log "Found drive ${letter}: '$($vol.FileSystemLabel)' ($freeGB GB free). Repository: $repo"

        if ($freeGB -lt $MinFreeGB) {
            Log "ERROR: only $freeGB GB free on ${letter}:, skipping"
            Status 'fail' "only $freeGB GB free on ${letter}: - skipping"
            Notify "Backup drive ${letter}: is almost full ($freeGB GB free). Backup skipped."
            $anyFailed = $true; continue
        }
        if ($scan.Bytes -gt ($vol.SizeRemaining * 0.95)) {
            Log "WARNING: selection ($(Fmt-Size $scan.Bytes)) is close to or larger than the free space ($freeGB GB). Compression/dedup may help, but it may not fit."
            Status 'warn' "the selection ($(Fmt-Size $scan.Bytes)) may not fit in $freeGB GB free."
        }

        Step-Start 'opening repository'
        $configPath = Join-Path $repo 'config'
        if (-not (Test-Path -LiteralPath $configPath)) {
            if ($DryRun) { Step-End 'info' 'new repository (dry run: not created)'; Log "[dry-run] would initialize repository $repo; nothing more to simulate"; continue }
            Log "Initializing new repository on ${letter}:"
            $base = Get-Base $repo
            & $ResticExe @base init 2>&1 | LogLines
            if ($LASTEXITCODE -ne 0) { Log "ERROR: restic init failed on ${letter}: (exit $LASTEXITCODE)"; Step-End 'fail' 'restic init failed'; $anyFailed = $true; continue }
            Step-End 'ok' 'new encrypted repository initialised'
        } else {
            $opened = $false
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                $base = Get-Base $repo
                & $ResticExe @base cat config 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $opened = $true; break }
                if ($Interactive -and $attempt -lt 3) {
                    Step-End 'fail' "wrong password (attempt $attempt/3)"
                    if ($script:PwSource -eq 'file')   { $script:UsePasswordFile = $false }
                    if ($script:PwSource -eq 'stored') { Remove-Item -LiteralPath $CredFile -Force -ErrorAction SilentlyContinue; Status 'info' 'removed the outdated saved password' }
                    if (-not (Request-Password)) { break }
                    $script:PwSource = 'typed'
                    Step-Start 'opening repository'
                } else { break }
            }
            if (-not $opened) {
                Log "ERROR: cannot open existing repository on ${letter}: (wrong password or damaged). Not touching it."
                Step-End 'fail' 'cannot open the repository: wrong password or damaged'
                Notify "Backup to ${letter}: FAILED - cannot open repository. See log."
                $anyFailed = $true; continue
            }
            Step-End 'ok' 'repository unlocked'
        }
        $base = Get-Base $repo

        # Offer safer password storage once the password is proven right
        if ($Interactive -and -not $script:SaveOffered) {
            if ($script:PwSource -eq 'typed') {
                $script:SaveOffered = $true
                if (Ask-Again 'save this password ENCRYPTED on this PC so scheduled/unattended backups work? (y/n)') {
                    if (Save-Cred $env:RESTIC_PASSWORD) { Status 'ok' 'saved (Windows-encrypted, only this user on this PC can read it)' $CredFile }
                    else { Status 'warn' 'could not save the password (see log).' }
                }
            } elseif ($script:PwSource -eq 'file') {
                $script:SaveOffered = $true
                Status 'warn' "the password sits in plain text in $PasswordFile"
                if (Ask-Again 'convert it to Windows-encrypted storage on this PC and wipe the plain file? (y/n)') {
                    $plain = (Get-Content -LiteralPath $PasswordFile -Raw).Trim()
                    if ($plain -and (Save-Cred $plain)) {
                        if (Remove-PlainFile $PasswordFile) { Status 'ok' 'plain-text password file wiped' } else { Status 'warn' 'saved the encrypted copy but could not delete the plain file - delete it yourself.' }
                        $script:UsePasswordFile = $false; $env:RESTIC_PASSWORD = $plain; $script:PwSource = 'stored'; $base = Get-Base $repo
                    } else { Status 'warn' 'could not convert (see log); plain file left untouched.' }
                }
            }
        }

        if (-not $DryRun) { & $ResticExe @base unlock 2>&1 | Out-Null }
        Notify "Backup to drive ${letter}: starting. Please don't unplug it until you see 'finished'."
        W
        Status 'warn' "transferring to ${letter}: - don't unplug the drive until it says finished"

        $excludeArgs = @()
        foreach ($p in $ExcludeFilePatterns + $ExcludeDirNames) { $excludeArgs += '--exclude', $p }
        if ($maxBytes -gt 0) { $excludeArgs += '--exclude-larger-than', ($sel.MaxSize -replace 'B$', '') }
        $backupArgs = @('backup', '--json', '--exclude-caches', '--exclude-cloud-files', '--compression', 'auto',
                        '--tag', 'usb-auto', '--tag', $selTag, '--group-by', 'host,tags', '--host', $env:COMPUTERNAME)
        if ($DryRun) { $backupArgs += '--dry-run' }
        # @(...) matters: with a single folder the bare result collapses to a string and restic gets it split into characters
        $targets = @(if ($filtering) { @('--files-from-verbatim', $script:ListFile) } else { $sel.Folders })

        Log "Backing up: $($sel.Folders -join '; ') [types: $extTxt]"

        # Live progress is parsed from restic --json; the log gets the summary and any warnings.
        $script:BarLast = -1; $script:Summary = $null; $script:Seen = $false; $script:LastDraw = 0
        $script:Warns = New-Object System.Collections.ArrayList
        $clock = [Diagnostics.Stopwatch]::StartNew()
        & $ResticExe @base @backupArgs @excludeArgs @targets 2>&1 | ForEach-Object {
            $line = "$_"
            if ($line -notmatch '^\{') { if ($line.Trim()) { Log $line.Trim(); [void]$script:Warns.Add($line.Trim()) }; return }
            if ($script:Quiet -and $line -match '"message_type":"status"') { return }
            try { $m = $line | ConvertFrom-Json } catch { return }
            switch ($m.message_type) {
                'status' {
                    if ($m.total_bytes) {
                        $script:Seen = $true
                        $now = $clock.ElapsedMilliseconds
                        if (($now - $script:LastDraw) -ge 90 -or $m.percent_done -ge 1) {
                            $script:LastDraw = $now
                            $secs = if ($m.seconds_elapsed -gt 0) { $m.seconds_elapsed } else { [Math]::Max(0.001, $now / 1000.0) }
                            $rate = $m.bytes_done / $secs
                            $right = '{0} / {1}  {2}/{3} files  {4}/s  eta {5}' -f (Fmt-Size $m.bytes_done), (Fmt-Size $m.total_bytes), $m.files_done, $m.total_files, (Fmt-Size $rate), (Fmt-Span $m.seconds_remaining)
                            Draw-Bar ([double]$m.percent_done) $right
                        }
                    }
                }
                'summary' { $script:Summary = $m }
                'error'   { $msg = "$($m.item): $($m.error.message)"; Log "WARNING: $msg"; [void]$script:Warns.Add($msg) }
                'exit_error' { Log "restic: $($m.message)"; [void]$script:Warns.Add("$($m.message)") }
            }
        }
        $rc = $LASTEXITCODE
        if ($script:Seen -and -not $script:Quiet -and $script:Color -and -not $script:Fast) { W }
        $sum = $script:Summary
        if ($sum) {
            Log ("Snapshot {0}: {1} new, {2} changed, {3} unmodified files; {4} added to repository; {5} files / {6} processed in {7:N1}s{8}" -f
                $sum.snapshot_id, $sum.files_new, $sum.files_changed, $sum.files_unmodified, (Fmt-Size $sum.data_added),
                $sum.total_files_processed, (Fmt-Size $sum.total_bytes_processed), $sum.total_duration, $(if ($DryRun) { ' (dry run)' } else { '' }))
        }
        foreach ($wmsg in ($script:Warns | Select-Object -First 5)) { Status 'warn' (Short $wmsg ((Term-Width) - 14)) }
        if ($script:Warns.Count -gt 5) { Status 'warn' "... and $($script:Warns.Count - 5) more (see log)" }

        if ($rc -eq 3) { Log "WARNING: backup to ${letter}: finished but some files were unreadable (exit 3)"; Status 'warn' 'finished, but some files were unreadable' }
        elseif ($rc -ne 0) {
            Log "ERROR: backup to ${letter}: failed (exit code $rc). Was the drive unplugged?"
            Status 'fail' "backup FAILED (exit $rc)" "see $LogFile"
            Notify "Backup to ${letter}: FAILED. Check the log: $LogFile"
            $anyFailed = $true; continue
        }
        if ($sum) {
            $sid8 = "$($sum.snapshot_id)"; $sid8 = $sid8.Substring(0, [Math]::Min(8, $sid8.Length))
            Status 'ok' ("snapshot {0}  -  {1} new, {2} changed, {3} unchanged" -f (C 255 $sid8), $sum.files_new, $sum.files_changed, $sum.files_unmodified) ("{0} written, {1:N1}s" -f (Fmt-Size $sum.data_added), $sum.total_duration)
        }

        if (-not $DryRun) {
            Step-Start "pruning old snapshots (keep ${KeepDaily}d / ${KeepWeekly}w / ${KeepMonthly}m)"
            & $ResticExe @base forget --group-by 'host,tags' --keep-daily $KeepDaily --keep-weekly $KeepWeekly `
                --keep-monthly $KeepMonthly --prune 2>&1 | LogLines
            if ($LASTEXITCODE -ne 0) { Log "WARNING: forget/prune returned exit $LASTEXITCODE"; Step-End 'warn' "forget/prune returned exit $LASTEXITCODE" }
            else { Step-End 'ok' }

            $stamp = Join-Path $repo 'last-check.txt'
            $due = $Check -or -not (Test-Path -LiteralPath $stamp) -or
                   ((Get-Date) - (Get-Item -LiteralPath $stamp).LastWriteTime).TotalDays -ge $CheckEveryDays
            if ($due) {
                Log "Running integrity check (5% data sample)"
                Step-Start 'integrity check (5% data sample)'
                & $ResticExe @base check --read-data-subset 5% 2>&1 | LogLines
                if ($LASTEXITCODE -eq 0) { Get-Date -Format s | Set-Content -LiteralPath $stamp; Log "Integrity check OK"; Step-End 'ok' 'no errors found' }
                else {
                    Log "ERROR: integrity check FAILED on ${letter}: - the backup may be damaged"
                    Step-End 'fail' 'integrity check FAILED - the backup may be damaged'
                    Notify "Backup integrity check FAILED on ${letter}:. See log."
                    $anyFailed = $true; continue
                }
            } else { Status 'info' "integrity check not due (every $CheckEveryDays days)" }
        }

        Log "Backup to ${letter}: finished OK"
        W
        Glitch ">> BACKUP COMPLETE $(if ($DryRun) { '(DRY RUN) ' })<<" 220
        $lines = @()
        if ($sum) {
            $lines += ((C 240 'files    ') + (C 255 "$($sum.total_files_processed)") + (C 240 "  ($($sum.files_new) new, $($sum.files_changed) changed)"))
            $lines += ((C 240 'payload  ') + (C 255 (Fmt-Size $sum.total_bytes_processed)))
            $lines += ((C 240 'written  ') + (C 255 (Fmt-Size $sum.data_added)) + (C 240 '  (deduplicated + compressed)'))
        }
        $lines += ((C 240 'vault    ') + (C 208 "${letter}: $FolderOnDrive\$env:COMPUTERNAME"))
        $lines += ((C 240 'status   ') + (C 220 $(if ($DryRun) { 'dry run - nothing was written' } else { 'encrypted, versioned, safe to eject' })))
        Box 'SUMMARY' $lines 220
        Notify "Backup to ${letter}: finished. You can safely eject the drive now."
        $anySucceeded = $true
    }

    if ($anyFailed) { $script:ExitCode = 1 }
    if ($anySucceeded -and -not $anyFailed) { Ping "" } elseif ($anyFailed) { Ping "/fail" }
}

try {
    $round = 0
    do {
        $round++
        if ($round -gt 1) { Header "round $round" }
        try { $null = Invoke-BackupRun ($round -gt 1) }
        finally {
            if ($script:ListFile -and (Test-Path -LiteralPath $script:ListFile)) { Remove-Item -LiteralPath $script:ListFile -Force -ErrorAction SilentlyContinue }
            $script:ListFile = $null
        }
        # another one? only when a person is at the keyboard
        $again = $false
        if ($script:AskAgain -and -not $script:Quiet) { $again = Ask-Again 'run another backup (different folders / file types)? (y/n)' }
    } while ($again)
}
catch {
    Log "ERROR: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    Status 'fail' $_.Exception.Message
    Ping "/fail"
    $script:ExitCode = 1
}
finally {
    if ($script:ListFile -and (Test-Path -LiteralPath $script:ListFile)) { Remove-Item -LiteralPath $script:ListFile -Force -ErrorAction SilentlyContinue }
    if ($hasMutex) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
    Remove-Item Env:\RESTIC_PASSWORD -ErrorAction SilentlyContinue
    if ($script:Color -and -not $script:Quiet) { [Console]::Out.Write("$($script:E)[0m$($script:E)[?25h") }
}
exit $script:ExitCode
