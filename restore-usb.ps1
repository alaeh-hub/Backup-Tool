# restore-usb.ps1 - restore files from a backup made by backup-usb.ps1.   [hacker-ui edition]
# Works on any PC: plug in the backup drive, run this script, and pick
#   PC -> snapshot -> user -> folder(s) -> where to restore to.
# Needs restic.exe (next to this script, in C:\Backup, on the drive root, or in PATH)
# and the backup password (typed in, never saved).
#
# Usage:  powershell -ExecutionPolicy Bypass -File restore-usb.ps1
# Optional: -Target D:\Somewhere   -RepoRoot E:\CompanyBackup   -PasswordFile C:\path\pass.txt
#           -NoAnim   (no animation, keep colors)      -Plain   (no colors, no animation, ASCII only)
#           -TrustRestic   (run a restic.exe whose SHA-256 is not on the trusted list - see $TrustedResticSha256)
# Safety:   restic.exe is hash-checked and only taken from this folder, C:\Backup or PATH; restores into drive roots,
#           Windows/Program Files folders or the vault itself are refused; existing files are never silently overwritten.
#           After each restore you are asked whether to do another one from the same unlocked vault.
# Env:      NO_COLOR=1 or HACKERUI_FAST=1 also work. Output is auto-plain when piped/redirected.
#
# NOTE: all visuals are cosmetic. Every status line, count, size and progress bar below
#       reflects what restic actually reports - nothing is faked.

param(
    [string]$Target,
    [string]$RepoRoot,
    [string]$PasswordFile,
    [switch]$NoAnim,
    [switch]$Plain,
    [switch]$TrustRestic
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$FolderOnDrive = 'CompanyBackup'
$Version = '2.1'

# =====================================================================================
#  UI LAYER
# =====================================================================================
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
function W([string]$s = '')  { [Console]::Out.WriteLine($s) }
function Wn([string]$s)      { [Console]::Out.Write($s); [Console]::Out.Flush() }
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
        '██████╗ ███████╗███████╗████████╗ ██████╗ ██████╗ ███████╗',
        '██╔══██╗██╔════╝██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝',
        '██████╔╝█████╗  ███████╗   ██║   ██║   ██║██████╔╝█████╗  ',
        '██╔══██╗██╔══╝  ╚════██║   ██║   ██║   ██║██╔══██╗██╔══╝  ',
        '██║  ██║███████╗███████║   ██║   ╚██████╔╝██║  ██║███████╗',
        '╚═╝  ╚═╝╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝'
    )
    $logo = $null
    try { if ([Console]::WindowWidth -ge 98) { $logo = Get-LogoRows } } catch { }
    if (-not $script:Uni) {
        W
        W '  A L A   E H !   ::   R E S T O R E'
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
    $right += (C 220 "usb vault recovery  ::  v$Version")
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
    Wn ("`n  " + (C 94 $G.pt) + (C 208 'restore') + (C 94 $G.pm) + (C 255 $label) + (C 94 $G.pb) + $hintText + "`n  " + (C 94 $G.pl) + (C 220 '$ '))
    $a = [Console]::In.ReadLine()
    if ($null -eq $a) { return 'q' }
    return $a.Trim()
}

function Fail($msg) {
    W
    Box 'FATAL' @((C 196 $msg)) 196
    exit 1
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

# =====================================================================================
#  RESTORE LOGIC
# =====================================================================================

# Friendly folder names -> real paths on THIS PC (follows OneDrive redirection).
# A full path (C:\..., D:\..., \\server\share) is accepted as-is, even if it doesn't exist yet.
# Returns $null for anything else (e.g. a bare word that isn't a known name).
function Resolve-Destination([string]$name) {
    $n = "$name".Trim().Trim('"')
    if (-not $n) { return $null }
    if ($n -match '^[A-Za-z]:[\\/]' -or $n -match '^\\\\') { $r = $n.TrimEnd('\','/'); if ($r -match '^[A-Za-z]:$') { $r += '\' }; return $r }
    $p = switch -regex ($n.TrimEnd('\').ToLower()) {
        '^(documents|docs|my documents)$' { [Environment]::GetFolderPath('MyDocuments') }
        '^desktop$'                       { [Environment]::GetFolderPath('Desktop') }
        '^downloads?$'                    { Join-Path $env:USERPROFILE 'Downloads' }
        '^(pictures|photos|images)$'      { [Environment]::GetFolderPath('MyPictures') }
        '^(videos|movies)$'               { [Environment]::GetFolderPath('MyVideos') }
        '^music$'                         { [Environment]::GetFolderPath('MyMusic') }
        '^(home|profile|user)$'           { $env:USERPROFILE }
        '^onedrive$'                      { $env:OneDrive }
        '^(repos|source|projects)$'       { Join-Path $env:USERPROFILE 'source\repos' }
        '^(restore|restored)$'            { 'C:\Restore' }
        default                           { $null }
    }
    if ($p) { return $p }
    return $null
}

# Why a restore target can be refused: returns $null when fine, otherwise the reason.
function Test-SafeTarget([string]$path) {
    try { $full = [IO.Path]::GetFullPath($path) } catch { return 'that is not a valid path' }
    $full = $full.TrimEnd('\')
    if ($full -match '^[A-Za-z]:$' -or $full -eq '') { return 'a drive root is not allowed (pick a folder, e.g. C:\Restore)' }
    if ($full -like '\\*' -and ($full.TrimStart('\') -split '\\').Count -lt 2) { return 'a bare network server is not allowed' }
    $blocked = @($env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData) | Where-Object { $_ }
    foreach ($b in $blocked) {
        $bb = $b.TrimEnd('\')
        if ($full -ieq $bb -or $full.StartsWith($bb + '\', [StringComparison]::OrdinalIgnoreCase)) { return "system folder ($bb) - restoring there could break Windows" }
    }
    if ($RepoRoot) {
        $rr = ([IO.Path]::GetFullPath($RepoRoot)).TrimEnd('\')
        if ($full -ieq $rr -or $full.StartsWith($rr + '\', [StringComparison]::OrdinalIgnoreCase)) { return 'that is inside the backup vault itself' }
    }
    return $null
}
function Test-NonEmptyDir([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $false }
    return [bool](Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
}
# restic --include treats * ? [ as pattern characters; match file names literally
function Escape-Glob([string]$s) { [regex]::Replace($s, '[\*\?\[]', '[$0]') }

# ---- 0. Intro ----
Invoke-Rain
Banner

# ---- 1. Find restic (only from places you control; other drives are never scanned) ----
Header 'boot sequence'
Step-Start 'locating restic engine'
$Restic = @("$PSScriptRoot\restic.exe", "$PSScriptRoot\restic.exe.exe", 'C:\Backup\restic.exe', 'C:\Backup\restic.exe.exe') |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $Restic) {
    $cmd = Get-Command restic -ErrorAction SilentlyContinue
    if ($cmd) { $Restic = $cmd.Source }
}
if (-not $Restic) { Step-End 'fail'; Fail "restic.exe not found. Copy it next to this script (or onto C:\Backup) and run again." }
$resticHash = Get-FileSha256 $Restic
$resticVer = Get-ResticVersion $Restic
if ($TrustedResticSha256 -contains $resticHash) {
    Step-End 'ok' "$Restic  [$resticVer]  sha256 $($resticHash.Substring(0, 12)) verified"
} else {
    Step-End 'warn' "$Restic  [$resticVer]" "sha256 $resticHash is NOT on the trusted list"
    if (-not $TrustRestic -and -not (Ask-Again 'this restic.exe is not recognised. run it anyway? (y/n)')) {
        Fail "refusing to run an unrecognised restic.exe. Use the one that came with this tool, or run with -TrustRestic."
    }
}

# Run restic, return output lines. Throws on a non-zero exit unless -Soft.
function Restic([string[]]$ArgList, [switch]$Soft) {
    $ErrorActionPreference = 'Continue'   # PS 5.1: native stderr must not become a terminating error
    $out = & $Restic @ArgList 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0 -and -not $Soft) { throw "restic failed (exit $LASTEXITCODE): $($out -join ' ')" }
    return $out
}

# ---- 2. Find the backup drive / repository root ----
Step-Start 'scanning drives for vault'
if (-not $RepoRoot) {
    $vaults = @(Get-PSDrive -PSProvider FileSystem |
        Where-Object { Test-Path -LiteralPath "$($_.Root)$FolderOnDrive" } |
        ForEach-Object { "$($_.Root)$FolderOnDrive" })
    if ($vaults.Count -eq 0) { Step-End 'fail'; Fail "No drive with a '$FolderOnDrive' folder found. Plug in the backup drive, or pass -RepoRoot." }
    if ($vaults.Count -eq 1) { $RepoRoot = $vaults[0]; Step-End 'ok' "vault found: $RepoRoot" }
    else {
        Step-End 'info' "$($vaults.Count) vaults found"
        Header 'backup drive'
        for ($i = 0; $i -lt $vaults.Count; $i++) { Menu-Line ($i + 1) (C 208 $vaults[$i]) }
        $p = Pick 'which drive' $vaults.Count
        if (-not $p) { exit 0 }
        $RepoRoot = $vaults[$p[0] - 1]
    }
} else {
    if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { Step-End 'fail'; Fail "-RepoRoot '$RepoRoot' does not exist." }
    Step-End 'ok' "vault set: $RepoRoot"
}

# ---- 3. Choose the PC (one repository per computer name) ----
Step-Start 'enumerating machines'
$pcs = @(Get-ChildItem -LiteralPath $RepoRoot -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'config') })
if ($pcs.Count -eq 0) { Step-End 'fail'; Fail "No backups found in $RepoRoot." }
Step-End 'ok' "$($pcs.Count) machine(s) in vault"

Header "target machine"
for ($i = 0; $i -lt $pcs.Count; $i++) {
    Menu-Line ($i + 1) (C 208 $pcs[$i].Name) ("last written {0:yyyy-MM-dd HH:mm}" -f $pcs[$i].LastWriteTime)
}
if ($pcs.Count -eq 1) { $pc = $pcs[0]; Status 'info' "only one machine: $(C 208 $pc.Name)" }
else { $p = Pick 'pc number' $pcs.Count; if (-not $p) { exit 0 }; $pc = $pcs[$p[0] - 1] }
$Repo = $pc.FullName

# ---- 4. Password (kept in memory for this session only, never written anywhere) ----
Header 'authentication'
$env:RESTIC_REPOSITORY = $Repo
Remove-Item Env:\RESTIC_PASSWORD_FILE -ErrorAction SilentlyContinue
$unlocked = $false
for ($try = 1; $try -le 3 -and -not $unlocked; $try++) {
    if ($PasswordFile -and $try -eq 1) {
        try { $env:RESTIC_PASSWORD = (Get-Content -LiteralPath $PasswordFile -Raw -ErrorAction Stop).Trim() }
        catch { Fail "cannot read the password file: $PasswordFile" }
        Status 'warn' 'using a plain-text password file - typing the password is safer' $PasswordFile
    } else {
        Wn ("`n  " + (C 94 $G.pt) + (C 208 'restore') + (C 94 $G.pm) + (C 202 'password (hidden)') + (C 94 $G.pb) + "`n")
        $sec = Read-Host "  $($G.pl)`$ " -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $env:RESTIC_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); $sec.Dispose() }
    }
    Step-Start "handshaking with vault (attempt $try/3)"
    $ErrorActionPreference = 'Continue'
    $cfg = & $Restic cat config 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -eq 0) { $unlocked = $true; Step-End 'ok' 'key accepted' }
    else { Step-End 'fail' 'wrong password (or damaged repository)' }
}
if (-not $unlocked) { Fail "Could not open the repository." }
$repoId = ''
try { $repoId = ((($cfg -join '') | ConvertFrom-Json).id).Substring(0, 16) } catch { }
W
Glitch '>> ACCESS GRANTED <<' 255
if ($repoId) { W ('  ' + (C 240 "repo id $repoId...  |  $Repo")) }

$firstTarget = $Target     # -Target only applies to the first restore of a session
$overall = 0
$round = 0
try {
    do {
        $round++
        if ($round -gt 1) { Header "round $round" }

        # ---- 5. Choose the snapshot ----
        Header 'select snapshot'
        # PS 5.1: ConvertFrom-Json emits a JSON array as ONE object; assign first so the array is enumerated into real snapshots
        $snapJson = (Working 'reading snapshot index' { (Restic @('snapshots', '--json')) -join '' }) -join ''
        $snapAll = $snapJson | ConvertFrom-Json
        $snaps = @($snapAll | ForEach-Object { $_ } | Sort-Object { [datetime]$_.time } -Descending)
        if ($snaps.Count -eq 0) { Fail "This repository has no snapshots yet." }
        for ($i = 0; $i -lt $snaps.Count; $i++) {
            $s = $snaps[$i]
            $size = if ($s.summary) { Fmt-Size $s.summary.total_bytes_processed } else { '?' }
            $files = if ($s.summary) { $s.summary.total_files_processed } else { '?' }
            $when = (C 208 ('{0:yyyy-MM-dd HH:mm}' -f ([datetime]$s.time)))
            $info = "$(C 255 $s.short_id)  $files files, $size"
            if ($i -eq 0) { $info += '  ' + (C 220 '<- newest') }
            Menu-Line ($i + 1) "$when  $info"
            $pp = @($s.paths)
            $shown = if ($pp.Count -le 3) { $pp -join '; ' } else { ((($pp | Select-Object -First 2) -join '; ') + "; ... (+$($pp.Count - 2) more)") }
            W ('       ' + (C 240 "contains: $(Short $shown ((Term-Width) - 18))"))
        }
        $default = 1
        while ($true) {
            $a = Ask 'snapshot' 'Enter = 1, newest'
            if ($a -match '^(q|quit|exit)$') { exit $overall }
            if (-not $a) { break }
            if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $snaps.Count) { $default = [int]$a; break }
            Status 'warn' "enter a number from 1 to $($snaps.Count), or q to quit."
        }
        $snap = $snaps[$default - 1]
        $sid = $snap.short_id
        Status 'ok' "locked on snapshot $(C 255 $sid)" ([datetime]$snap.time).ToString('yyyy-MM-dd HH:mm:ss')

        # List the children of a directory inside the snapshot (non-recursive).
        function Get-Children([string]$path) {
            $lines = Restic @('ls', $sid, $path, '--json')
            $nodes = foreach ($l in $lines) {
                if ($l -notmatch '^\{') { continue }
                $o = $l | ConvertFrom-Json
                if ($o.struct_type -eq 'node' -and $o.path -ne $path) { $o }
            }
            # Keep direct children only, folders first
            @($nodes | Where-Object { ($_.path -replace '/[^/]+$', '') -eq $path.TrimEnd('/') -or ($path -eq '/' -and ($_.path -split '/').Count -eq 2) } |
                Sort-Object @{ e = { $_.type -ne 'dir' } }, name)
        }

        # ---- 6. Choose the user ----
        Header 'select user'
        $users = @(Working 'mapping filesystem' {
            foreach ($drive in (Get-Children '/' | Where-Object { $_.type -eq 'dir' })) {
                foreach ($u in (Get-Children "$($drive.path)/Users" | Where-Object { $_.type -eq 'dir' })) {
                    [pscustomobject]@{ Name = $u.name; Path = $u.path; Label = "$($u.name)   ($($drive.name):\Users\$($u.name))" }
                }
            }
        })
        if ($users.Count -eq 0) {
            Status 'warn' 'No C:\Users\... structure in this snapshot; browsing from the top.'
            $startPath = '/'
            $userName = 'files'
        } else {
            for ($i = 0; $i -lt $users.Count; $i++) { Menu-Line ($i + 1) (C 208 $users[$i].Label) }
            if ($users.Count -eq 1) { $u = $users[0]; Status 'info' "only one user: $(C 208 $u.Name)" }
            else { $p = Pick 'user number' $users.Count; if (-not $p) { exit $overall }; $u = $users[$p[0] - 1] }
            $startPath = $u.Path
            $userName = $u.Name
        }

        # ---- 7. Choose the folder(s) / file(s); can open folders to look inside ----
        $cur = $startPath
        $selected = @()
        while ($true) {
            Header "browse  $cur"
            $kids = @(Working "listing $cur" { Get-Children $cur })
            if ($kids.Count -eq 0) { W ('  ' + (C 240 '(empty)')); $cmd = 'up' }
            else {
                for ($i = 0; $i -lt $kids.Count; $i++) {
                    $k = $kids[$i]
                    if ($k.type -eq 'dir') { Menu-Line ($i + 1) ((C 208 "$($G.dir) $($k.name)/")) }
                    else { Menu-Line ($i + 1) ((C 220 "  $($k.name)")) (Fmt-Size $k.size) }
                }
                W
                W ('  ' + (C 240 'numbers to RESTORE ') + (C 255 '2') + (C 240 '  or  ') + (C 255 '1,3') + (C 240 '  or  ') + (C 255 'all'))
                W ('  ' + (C 255 'o 2') + (C 240 '  open folder 2   ') + (C 255 'u') + (C 240 '  up one level   ') + (C 255 'q') + (C 240 '  quit'))
                $cmd = Ask 'choice'
            }
            if ($cmd -match '^(q|quit|exit)$') { exit $overall }
            if ($cmd -match '^(u|up|\.\.)$') {
                if ($cur -ne $startPath -and $cur -ne '/') { $cur = ($cur -replace '/[^/]+$', ''); if (-not $cur) { $cur = '/' } }
                else { Status 'warn' 'already at the top.' }
                continue
            }
            if ($cmd -match '^o(pen)?\s*(\d+)$') {
                $n = [int]$Matches[2]
                if ($n -ge 1 -and $n -le $kids.Count -and $kids[$n - 1].type -eq 'dir') { $cur = $kids[$n - 1].path }
                else { Status 'warn' 'not a folder.' }
                continue
            }
            if ($cmd -match '^all$') { $selected = $kids; break }
            $nums = @($cmd -split '[,\s]+' | Where-Object { $_ })
            $valid = $nums.Count -gt 0
            foreach ($n in $nums) { if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt $kids.Count) { $valid = $false } }
            if (-not $valid) { Status 'warn' 'not understood.'; continue }
            $selected = @($nums | ForEach-Object { $kids[[int]$_ - 1] } | Select-Object -Unique)
            break
        }

        # ---- 8. Where to restore (with safety checks) ----
        Header 'destination'
        $defaultTarget = "C:\Restore\$($pc.Name)\$userName"
        $Target = $null
        if ($round -eq 1 -and $firstTarget) {
            $t = Resolve-Destination $firstTarget
            if (-not $t) { Fail "-Target '$firstTarget' is not a full path or a known name (documents, desktop, downloads, pictures, videos, music, home, onedrive, repos)." }
            $Target = $t
        } else { $Target = $defaultTarget }
        W ('  ' + (C 240 'type a full path (C:\Restore\Test) or a name: ') + (C 255 'documents desktop downloads pictures videos music home onedrive'))
        Status 'info' 'a name restores into that folder on THIS PC.'
        while ($true) {
            $a = Ask 'restore into' "Enter = $(Short $Target ((Term-Width) - 24))"
            if ($a -match '^(q|quit|exit)$') { exit $overall }
            $candidate = $Target
            if ($a) {
                $candidate = Resolve-Destination $a
                if (-not $candidate) { Status 'warn' "'$a' is not a full path or a known name. Use e.g. C:\Restore\Test or documents."; continue }
            }
            $why = Test-SafeTarget $candidate
            if ($why) { Status 'fail' "refused: $why"; continue }
            $Target = $candidate
            break
        }
        $proceed = $true
        # restoring onto the backup drive itself defeats the point of a backup
        try {
            if ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Target)) -ieq [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($RepoRoot))) {
                Status 'warn' 'that target is on the SAME drive as the backup vault.'
                if (-not (Ask-Again 'restore onto the backup drive anyway? (y/n)')) { $proceed = $false }
            }
        } catch { }
        # never silently overwrite: let the user pick
        if ($proceed -and (Test-NonEmptyDir $Target)) {
            Status 'warn' "$(Short $Target ((Term-Width) - 30)) already contains files."
            W ('  ' + (C 255 'o') + (C 240 '  overwrite same-name files   ') + (C 255 'n') + (C 240 '  restore into a NEW timestamped folder   ') + (C 255 'c') + (C 240 '  cancel'))
            $c = Ask 'existing files' 'o / n / c'
            if ($c -match '^(n|new)$') { $Target = "$Target-$(Get-Date -Format 'yyyyMMdd-HHmmss')"; Status 'info' "new folder: $Target" }
            elseif ($c -notmatch '^(o|overwrite)$') { $proceed = $false }
        }

        if ($proceed) {
            $brief = @(
                ((C 240 'snapshot ') + (C 255 $sid) + (C 240 '  ') + (C 208 ([datetime]$snap.time).ToString('yyyy-MM-dd HH:mm'))),
                ((C 240 'target   ') + (C 208 (Short $Target)))
            )
            foreach ($s in $selected) { $brief += ((C 240 'extract  ') + (C 220 (Short $s.path))) }
            W
            Box 'MISSION BRIEF' $brief 208
            Status 'info' 'your original files are never touched; same-name files in the target may be overwritten.'
            $proceed = Ask-Again 'continue? (y/n)'
            if (-not $proceed) { Status 'info' 'cancelled. nothing was written.' }
        } else { Status 'info' 'cancelled. nothing was written.' }

        if ($proceed) {
            New-Item -ItemType Directory -Force -Path $Target | Out-Null

            # ---- 9. Restore each selection (live progress is real: parsed from restic --json) ----
            $failed = 0
            $totalBytes = 0L; $totalFiles = 0; $sessionClock = [Diagnostics.Stopwatch]::StartNew()
            foreach ($s in $selected) {
                Header "extracting $($s.name)"
                if ($s.type -eq 'dir') {
                    $dest = Join-Path $Target $s.name
                    $rargs = @('restore', "${sid}:$($s.path)", '--target', $dest, '--verify', '--json')
                } else {
                    $parent = ($s.path -replace '/[^/]+$', ''); if (-not $parent) { $parent = '/' }
                    $rargs = @('restore', "${sid}:$parent", '--target', $Target, '--include', "/$(Escape-Glob $s.name)", '--verify', '--json')
                }
                $script:BarLast = -1
                $script:Summary = $null; $script:Errs = New-Object System.Collections.ArrayList
                $script:LastDraw = 0; $script:Seen = $false
                $itemClock = [Diagnostics.Stopwatch]::StartNew()
                $ErrorActionPreference = 'Continue'
                & $Restic @rargs 2>&1 | ForEach-Object {
                    $line = "$_"
                    if ($line -notmatch '^\{') { if ($line.Trim()) { [void]$script:Errs.Add($line.Trim()) }; return }
                    try { $m = $line | ConvertFrom-Json } catch { return }
                    switch ($m.message_type) {
                        'status' {
                            if ($m.total_bytes) {
                                $script:Seen = $true
                                $now = $itemClock.ElapsedMilliseconds
                                if (($now - $script:LastDraw) -ge 90 -or $m.percent_done -ge 1) {
                                    $script:LastDraw = $now
                                    $secs = [Math]::Max(0.001, $now / 1000.0)
                                    $rate = $m.bytes_restored / $secs
                                    $eta = if ($rate -gt 0) { ($m.total_bytes - $m.bytes_restored) / $rate } else { 0 }
                                    $right = "{0} / {1}  {2}/{3} files  {4}/s  eta {5}" -f (Fmt-Size $m.bytes_restored), (Fmt-Size $m.total_bytes), $m.files_restored, $m.total_files, (Fmt-Size $rate), (Fmt-Span $eta)
                                    Draw-Bar ([double]$m.percent_done) $right $(if ($m.percent_done -ge 1) { 'verifying' } else { '' })
                                }
                            }
                        }
                        'summary' { $script:Summary = $m }
                        'error'   { [void]$script:Errs.Add("$($m.item): $($m.error.message)") }
                        'exit_error' { [void]$script:Errs.Add("$($m.message)") }
                    }
                }
                $rc = $LASTEXITCODE
                $ErrorActionPreference = 'Stop'
                if ($script:Color -and -not $script:Fast -and $script:Seen) { W }
                foreach ($e in ($script:Errs | Select-Object -First 8)) { Status 'warn' (Short $e ((Term-Width) - 14)) }
                if ($script:Errs.Count -gt 8) { Status 'warn' "... and $($script:Errs.Count - 8) more" }
                $sum = $script:Summary
                if ($rc -ne 0) { $failed++; Status 'fail' "FAILED: $($s.path)" "exit $rc" }
                else {
                    $nf = if ($sum.files_restored) { $sum.files_restored } else { 0 }
                    $nb = if ($sum.bytes_restored) { [long]$sum.bytes_restored } else { 0L }
                    $sk = if ($sum.files_skipped) { ", $($sum.files_skipped) already up to date" } else { '' }
                    $totalFiles += $nf; $totalBytes += $nb
                    Status 'ok' "$($s.name)  -  $nf file(s), $(Fmt-Size $nb)$sk" ("{0:N1}s, verified" -f ($itemClock.ElapsedMilliseconds / 1000.0))
                }
            }

            W
            $secsAll = '{0:N1}s' -f ($sessionClock.ElapsedMilliseconds / 1000.0)
            if ($failed) {
                $overall = 1
                Box 'RESTORE INCOMPLETE' @(
                    ((C 202 "$failed item(s) failed")),
                    ((C 240 'target ') + (C 208 (Short $Target)))
                ) 202
            } else {
                Glitch '>> RESTORE COMPLETE <<' 220
                Box 'SUMMARY' @(
                    ((C 240 'files   ') + (C 255 "$totalFiles")),
                    ((C 240 'data    ') + (C 255 (Fmt-Size $totalBytes))),
                    ((C 240 'time    ') + (C 255 $secsAll)),
                    ((C 240 'target  ') + (C 208 (Short $Target))),
                    ((C 240 'verify  ') + (C 220 'all files checked against the vault'))
                ) 220
            }
            if ($script:IsTty) { try { Start-Process explorer.exe -ArgumentList "`"$Target`"" } catch { } }
        }

        # ---- 10. Another one? ----
        $again = Ask-Again 'restore something else from this vault? (y/n)'
    } while ($again)
    Status 'info' 'vault closed. password wiped from memory.'
    exit $overall
}
catch {
    Fail $_.Exception.Message
}
finally {
    Remove-Item Env:\RESTIC_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:\RESTIC_REPOSITORY -ErrorAction SilentlyContinue
    if ($script:Color) { Wn "$($script:E)[0m$($script:E)[?25h" }
}
