# One measured run without anyone at the keyboard: starts the game, goes from its menus into play with scripted
# keys, records -Seconds of play (window title each second, screenshots, the layer's log), closes the game and
# writes a report. Results: %LOCALAPPDATA%\victory\gul-runs\<time>-<name>\ (report.txt, report.json, samples.csv,
# shots\) and one line per run in %LOCALAPPDATA%\victory\gul-runs\results.csv.
#
#   .\tools\gul\bench.ps1 -Name base
#   .\tools\gul\bench.ps1 -Name filltitle -Set 'VICTORY_FILL_TITLE=1'
#   .\tools\gul\bench.ps1 -Name fast -Build fast -Set 'VICTORY_FILL_TITLE=1;VICTORY_THIN_THREADS=12'
#   .\tools\gul\bench.ps1 -Name look -BootOnly          (start, go through the menus with screenshots, stay running)
param(
    [string]$Name = 'run',
    [int]$Seconds = 120,
    [ValidateSet('release', 'diag', 'fast')][string]$Build = 'release',
    # Switches for this run: 'A=1;B=2'.
    [string]$Set = '',
    # Launcher options: DLSS mode, frame generation (2-6, 0: ready but off), frame rate cap.
    [ValidateSet('off', 'dlaa', 'quality', 'balanced', 'performance')][string]$Dlss = 'quality',
    [int]$FrameGen = 0,
    [int]$Fps = 1000,
    # Menu keys, sent until play is seen: "<seconds after the window> <key> [hold]" per entry, ';' between.
    [string]$Menu = '',
    # Keys held during play, repeated: e.g. 'W 4;S 4' (walk ahead 4 s, back 4 s). Empty: stand still.
    [string]$Walk = '',
    [int]$BootMinutes = 8,
    # Seconds between play being seen and the recording: the save opens with a cutscene of about 70 s.
    [int]$Settle = 80,
    [int]$ShotEvery = 30,
    [switch]$BootOnly,
    # Where the game's window is made: 'secondary' (the first monitor that is not the primary one, its work
    # area), 'primary' (as the layer does by default), or 'X,Y,W,H'.
    [string]$Monitor = 'secondary',
    # The title's executable; by default game_scarlett_master.exe in victory.toml's game_dir.
    [string]$Exe = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
if (-not $Exe) {
    $toml = Join-Path $script:GulRoot 'victory.toml'
    $dirLine = if (Test-Path $toml) { Get-Content $toml | Where-Object { $_ -match "^\s*game_dir\s*=\s*['""](.+)['""]" } | Select-Object -First 1 }
    if (-not $dirLine) { throw 'no -Exe and no game_dir in victory.toml' }
    $null = $dirLine -match "^\s*game_dir\s*=\s*['""](.+)['""]"
    $Exe = Join-Path $Matches[1] 'game_scarlett_master.exe'
}
$inv = [Globalization.CultureInfo]::InvariantCulture

if (-not $Menu) {
    $menuFile = Join-Path $PSScriptRoot 'menu.txt'
    $Menu = if (Test-Path $menuFile) { ((Get-Content $menuFile | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }) -join ';') } else { '' }
}

# The run's folder.
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dir = Join-Path $script:GulRuns "$stamp-$Name"
New-Item -ItemType Directory -Force (Join-Path $dir 'shots') | Out-Null

# Nothing else of the title may run.
Get-Process victory -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2

# The launcher clears VICTORY_* from the environment, so the switches go in through its -More.
$more = [ordered]@{ VICTORY_KEYS_FILE = $script:GulKeys }
if ($Monitor -eq 'secondary') {
    Add-Type -AssemblyName System.Windows.Forms
    $screen = [System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary } | Select-Object -First 1
    if ($screen) { $w = $screen.WorkingArea; $more.VICTORY_WINDOW_AREA = '{0},{1},{2},{3}' -f $w.X, $w.Y, $w.Width, $w.Height }
} elseif ($Monitor -match '^-?\d+,-?\d+,\d+,\d+$') { $more.VICTORY_WINDOW_AREA = $Monitor }
foreach ($pair in ($Set -split ';' | Where-Object { $_ -match '=' })) { $k, $v = $pair -split '=', 2; $more[$k.Trim()] = $v.Trim() }
$moreText = ($more.GetEnumerator() | ForEach-Object { "'{0}' = '{1}'" -f $_.Key, ($_.Value -replace "'", "''") }) -join '; '
$fg = if ($FrameGen -ge 2) { "-FrameGen -FrameGenX $FrameGen" } else { '' }
$runner = Join-Path $dir 'runner.ps1'
@"
`$env:VICTORY_STREAMLINE_DIR = Join-Path `$env:LOCALAPPDATA 'victory\nvidia-sdk\Streamline\bin\x64'
& '$((Join-Path $script:GulRoot 'scripts\play-foxhound.ps1') -replace "'", "''")' -Exe '$($Exe -replace "'", "''")' -Build $Build -Dlss $Dlss -Fps $Fps $fg -More @{ $moreText } | Out-Null
"@ | Set-Content -Encoding utf8 $runner
# (Nothing goes to a console: a console that stops taking output, as one in a selection does, stopped the
# game's log and then its window.)
# The menu's saved choices would go over these: kept aside for the run.
$menuSaved = Join-Path $script:GulRoot 'victory-settings.txt'
$menuAside = "$menuSaved.gul-aside"
if (Test-Path $menuSaved) { Move-Item -Force $menuSaved $menuAside }

Set-Content -Encoding ascii $script:GulKeys ''
$logs = Join-Path $env:LOCALAPPDATA 'victory\logs'
$before = Get-Date
$proc = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner
"run $Name ($Build; $Set) started; folder $dir"

function Note([string]$text) { $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $text; Add-Content -Encoding utf8 (Join-Path $dir 'events.txt') $line; $line }

# Watchdog: the game's log has to keep growing (a frame-rate line a second); 60 s without: the run is stopped.
$script:logSeen = @{ size = -1; at = Get-Date }
function Test-LogStalled {
    $l = Get-ChildItem $logs -Filter 'foxhound-*.log' | Where-Object { $_.LastWriteTime -ge $before } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $l) { return ((Get-Date) - $before).TotalSeconds -gt 120 }
    $l.Refresh()
    if ($l.Length -ne $script:logSeen.size) { $script:logSeen.size = $l.Length; $script:logSeen.at = Get-Date; return $false }
    ((Get-Date) - $script:logSeen.at).TotalSeconds -gt 60
}
# Frame generation needs the game's window in front.
function Set-GameFront {
    if ($FrameGen -lt 2) { return }
    $p = Get-GulGame
    if ($p -and -not [GulWin]::IsFront($p.MainWindowHandle)) {
        $ok = [GulWin]::Front($p.MainWindowHandle)
        Note "game window brought to the front for frame generation: $ok"
    }
}
$stalled = $false

# Boot: wait for the window, send the menu keys at their times, screenshots as it goes; play is seen when
# the title line says more than 2,500 draws a frame three times running.
$steps = @($Menu -split ';' | Where-Object { $_ -match '\S' } | ForEach-Object {
    $w = $_.Trim() -split '\s+'
    [pscustomobject]@{ at = [double]::Parse($w[0], $inv); key = $w[1]; hold = $(if ($w.Count -gt 2) { [double]::Parse($w[2], $inv) } else { 0.2 }); sent = $false }
})
$deadline = (Get-Date).AddMinutes($BootMinutes)
$windowAt = $null; $inPlay = 0; $lastShot = Get-Date '2000-01-01'; $playAt = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1000
    $t = Get-GulTitle
    if (-not $t) {
        if ($windowAt -and -not (Get-Process victory -ErrorAction SilentlyContinue)) { Note 'the game exited during boot'; break }
        continue
    }
    if (-not $windowAt) { $windowAt = Get-Date; Note "window: $($t.title)" }
    if (Test-LogStalled) { Note 'the log stopped growing for 60 s during boot: run stopped'; $stalled = $true; break }
    $since = ((Get-Date) - $windowAt).TotalSeconds
    foreach ($s in $steps) { if (-not $s.sent -and $since -ge $s.at) { Send-GulKey $s.key $s.hold; $s.sent = $true; Note ("key {0} at {1:N0} s" -f $s.key, $since) } }
    if (((Get-Date) - $lastShot).TotalSeconds -ge 10) {
        $lastShot = Get-Date
        $shot = Save-GulShot (Join-Path $dir ('shots\boot-{0:000}s.jpg' -f $since))
        Note ("boot {0:N0} s: {1}{2}" -f $since, $t.title, $(if ($shot) { " shot" } else { '' }))
    }
    if ($t.draws -ge 2500) { $inPlay++ } else { $inPlay = 0 }
    if ($inPlay -ge 3) { $playAt = Get-Date; Note "play seen: $($t.title)"; break }
}
$log = Get-ChildItem $logs -Filter 'foxhound-*.log' | Where-Object { $_.LastWriteTime -ge $before } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($BootOnly) { Note "boot only: the game stays running; log $($log.FullName)"; if (Test-Path $menuAside) { Move-Item -Force $menuAside $menuSaved }; return }

$samples = New-Object System.Collections.Generic.List[object]
$fromUtc = $null; $toUtc = $null
if ($playAt -and -not $stalled) {
    # Let the scene settle (the save's opening cutscene, streaming after the load), then record.
    Note "settling $Settle s"
    Set-GameFront
    Start-Sleep $Settle
    Set-GameFront
    $null = Save-GulShot (Join-Path $dir 'shots\play-start.jpg')
    $fromUtc = (Get-Date).ToUniversalTime()
    $end = (Get-Date).AddSeconds($Seconds)
    $walkSteps = @($Walk -split ';' | Where-Object { $_ -match '\S' } | ForEach-Object { $w = $_.Trim() -split '\s+'; [pscustomobject]@{ key = $w[0]; hold = [double]::Parse($w[1], $inv) } })
    $nextWalk = Get-Date; $wi = 0; $nextShot = Get-Date
    while ((Get-Date) -lt $end) {
        if ($walkSteps.Count -and (Get-Date) -ge $nextWalk) { $w = $walkSteps[$wi % $walkSteps.Count]; Send-GulKey $w.key $w.hold; $nextWalk = (Get-Date).AddSeconds($w.hold + 0.3); $wi++ }
        $t = Get-GulTitle
        if (-not $t) { Note 'the game is gone during play'; break }
        if (Test-LogStalled) { Note 'the log stopped growing for 60 s during play: run stopped'; break }
        if ($samples.Count % 15 -eq 0) { Set-GameFront }
        $samples.Add([pscustomobject]@{ time = (Get-Date).ToString('HH:mm:ss'); fps = $t.fps; shown = $t.shown; ms = $t.ms; draws = $t.draws })
        if ((Get-Date) -ge $nextShot) { $nextShot = (Get-Date).AddSeconds($ShotEvery); $null = Save-GulShot (Join-Path $dir ('shots\play-{0:HHmmss}.jpg' -f (Get-Date))) }
        Start-Sleep -Milliseconds 1000
    }
    $toUtc = (Get-Date).ToUniversalTime()
} else { Note 'play was not reached' }

# Close the game and the launcher.
Get-Process victory -ErrorAction SilentlyContinue | Stop-Process -Force
try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch {}
Start-Sleep 2
if (Test-Path $menuAside) { Move-Item -Force $menuAside $menuSaved }
$samples | Export-Csv -NoTypeInformation -Encoding utf8 (Join-Path $dir 'samples.csv')

if (-not $log) { Note 'no log was written'; return }
$args2 = @{ Log = $log.FullName }
if ($fromUtc) { $args2.From = $fromUtc; $args2.To = $toUtc }
$text = & (Join-Path $PSScriptRoot 'parse.ps1') @args2
$json = & (Join-Path $PSScriptRoot 'parse.ps1') @args2 -Json
$fpsTitle = @($samples | Where-Object { $_.fps } | ForEach-Object { $_.fps } | Sort-Object)
$titleMedian = if ($fpsTitle.Count) { $fpsTitle[[int]($fpsTitle.Count / 2)] } else { $null }
$titleP10 = if ($fpsTitle.Count) { $fpsTitle[[int]($fpsTitle.Count / 10)] } else { $null }
$shownTitle = @($samples | Where-Object { $_.shown } | ForEach-Object { $_.shown } | Sort-Object)
$shownMedian = if ($shownTitle.Count) { $shownTitle[[int]($shownTitle.Count / 2)] } else { $null }
$shownP10 = if ($shownTitle.Count) { $shownTitle[[int]($shownTitle.Count / 10)] } else { $null }
$shownP1 = if ($shownTitle.Count) { $shownTitle[[int]($shownTitle.Count / 100)] } else { $null }
$under60 = @($shownTitle | Where-Object { $_ -lt 58 }).Count
$header = @(
    "run: $Name   build: $Build   dlss: $Dlss   framegen: $FrameGen   fps cap: $Fps"
    "switches: $Set"
    "window-title fps over $($fpsTitle.Count) s of play: rendered median $titleMedian, p10 $titleP10; shown median $shownMedian, p10 $shownP10, p1 $shownP1; seconds under 58 shown: $under60"
)
($header + $text) | Set-Content -Encoding utf8 (Join-Path $dir 'report.txt')
$json | Set-Content -Encoding utf8 (Join-Path $dir 'report.json')
$j = $json | ConvertFrom-Json
$row = [pscustomobject]@{
    time = $stamp; name = $Name; build = $Build; set = $Set; dlss = $Dlss; framegen = $FrameGen
    play_seconds = $fpsTitle.Count; fps_median = $j.fps.median; fps_p10 = $j.fps.p10; fps_p90 = $j.fps.p90
    title_fps_median = $titleMedian; title_shown_median = $shownMedian; title_shown_p10 = $shownP10; seconds_under_58 = $under60; shown_fps_median = $j.shown_fps.median; shown_fps_p10 = $j.shown_fps.p10; fg_ratio = $j.fg_shown_per_rendered; ms_median = $j.ms.median; gpu_ms = $j.gpu_ms.median; prep_ms = $j.preparing_ms.median
    submit_worked_ms = $j.submit_thread_worked_ms; waiting_card_ms = $j.submit_waiting_for_card_ms; draws = $j.draws.median
    faults = ($j.faults -join ' | '); folder = $dir
}
$csv = Join-Path $script:GulRuns 'results.csv'
$row | Export-Csv -NoTypeInformation -Encoding utf8 -Append $csv
($header + $text)
