# Reads a victory log: the layer's frame-rate lines (one a second) and the last breakdown lines.
#   .\tools\gul\parse.ps1 -Log <file> [-From <UTC DateTime>] [-To <UTC DateTime>] [-MinDraws 2500] [-Json]
param(
    [Parameter(Mandatory)][string]$Log,
    [Nullable[datetime]]$From = $null,
    [Nullable[datetime]]$To = $null,
    [int]$MinDraws = 2500,
    [switch]$Json,
    [switch]$Timeline
)
$fs = [IO.File]::Open($Log, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs); $all = $sr.ReadToEnd(); $sr.Close()
$all = $all -replace "\x1b\[[0-9;]*m", ''
$lines = $all -split "`n"
$inv = [Globalization.CultureInfo]::InvariantCulture
function When([string]$l) {
    if ($l -match '^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z') { return [datetime]::Parse($Matches[1], $inv, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal) }
    $null
}
function Inside([string]$l) {
    if (-not $From -and -not $To) { return $true }
    $t = When $l
    if (-not $t) { return $false }
    (-not $From -or $t -ge $From) -and (-not $To -or $t -le $To)
}
$rx = '(?<fps>[\d.]+) fps, (?<ms>[\d.]+) ms/frame \((?<prep>[\d.]+) preparing: copies (?<cp>[\d.]+) ms (?<cpmb>[\d.]+) MB, textures (?<tx>[\d.]+) ms [\d.]+ MB; (?<gpu>[\d.]+) on the GPU; (?<back>[\d.]+) copying back.*?(?<draws>\d+) draws/frame'
$rows = foreach ($l in $lines) {
    if ($l -match $rx -and (Inside $l)) {
        [pscustomobject]@{ t = When $l; fps = [double]$Matches.fps; ms = [double]$Matches.ms; prep = [double]$Matches.prep; copies = [double]$Matches.cp; gpu = [double]$Matches.gpu; back = [double]$Matches.back; draws = [int]$Matches.draws }
    }
}
$play = @($rows | Where-Object { $_.draws -ge $MinDraws })
function Q($xs, [double]$q) { $s = @($xs | Sort-Object); if ($s.Count -eq 0) { return $null }; $s[[int][math]::Min($s.Count - 1, [math]::Floor($s.Count * $q))] }
function Stat($xs) { [ordered]@{ p10 = Q $xs 0.1; median = Q $xs 0.5; p90 = Q $xs 0.9; min = Q $xs 0; max = Q $xs 1 } }
# Per-frame numbers from the breakdown lines, as medians over the window.
function Series([string]$like, [string]$pattern) {
    @($lines | Where-Object { $_ -like "*$like*" -and (Inside $_) } | ForEach-Object { if ($_ -match $pattern) { [double]$Matches[1] } })
}
$waitCard = Series 'preparing per frame, the submitting thread' ' ([\d.]+) waiting for flights'
$worked = Series 'submissions prepared by a thread of ours' 'that thread worked ([\d.]+) ms'
$steps = Series 'preparing per frame, the submitting thread' ' ([\d.]+) in the lists'' steps'
$refresh = Series 'preparing per frame, the submitting thread' 'refreshes ([\d.]+) in'
$planning = Series 'preparing per frame, the submitting thread' ' ([\d.]+) planning steps done on the card'
$cardBusy = Series "the card's clock per frame" 'the card about (\d+)% busy'
$reasons = @($lines | Where-Object { $_ -like '*of the waiting for the card in settles*' -and (Inside $_) } | Select-Object -Last 1)
$settled = @($lines | Where-Object { $_ -like '*submissions sent ahead per frame*' -and (Inside $_) } | Select-Object -Last 1)
$blame = @($lines | Where-Object { $_ -like '*waited for flights, per frame*' -and (Inside $_) } | Select-Object -Last 5)
# Frame generation: frames shown for each one rendered, from Streamline's own count.
$fgOn = 0; $fgOff = 0; $fgShown = 0
foreach ($l in $lines) {
    if ($l -match 'DLSS Frame Generation: (\d+) presents with it on, (\d+) off, (\d+) frames shown by it' -and (Inside $l)) { $fgOn += [int]$Matches[1]; $fgOff += [int]$Matches[2]; $fgShown += [int]$Matches[3] }
}
$fgRatio = if ($fgOn + $fgOff -gt 0) { [math]::Round(($fgOn + $fgOff + $fgShown) / ($fgOn + $fgOff), 2) } else { 1 }
$ab = @($lines | Where-Object { $_ -like '*A/B phase*' -and (Inside $_) } | ForEach-Object { ($_ -replace '^.*?INFO\s+', '').Trim() })
$warn = @($lines | Where-Object { $_ -match ' (WARN|ERROR) ' -and (Inside $_) }).Count
$crash = @($lines | Where-Object { $_ -match 'device (removed|lost|hung)|panicked|access violation|crash' } | Select-Object -First 3)

$r = [ordered]@{
    log = $Log
    lines = @($rows).Count
    gameplay_lines = $play.Count
    fps = Stat $play.fps
    fg_shown_per_rendered = $fgRatio
    shown_fps = Stat @($play.fps | ForEach-Object { $_ * $fgRatio })
    ms = Stat $play.ms
    preparing_ms = Stat $play.prep
    copies_ms = Stat $play.copies
    gpu_ms = Stat $play.gpu
    copy_back_ms = Stat $play.back
    draws = Stat $play.draws
    submit_thread_worked_ms = (Q $worked 0.5)
    submit_waiting_for_card_ms = (Q $waitCard 0.5)
    lists_steps_ms = (Q $steps 0.5)
    refreshes_ms = (Q $refresh 0.5)
    planning_card_steps_ms = (Q $planning 0.5)
    card_busy_pct = (Q $cardBusy 0.5)
    wait_reasons = (($reasons | ForEach-Object { ($_ -replace '^.*?INFO\s+', '').Trim() }) -join '')
    settles = (($settled | ForEach-Object { ($_ -replace '^.*?INFO\s+', '').Trim() }) -join '')
    blame = @($blame | ForEach-Object { ($_ -replace '^.*?INFO\s+', '').Trim() })
    ab = $ab
    warnings = $warn
    faults = @($crash | ForEach-Object { ($_ -replace '^.*?(INFO|WARN|ERROR)\s+', '').Trim() })
}
if ($Json) { $r | ConvertTo-Json -Depth 5; return }
'log: {0}' -f $r.log
'frame-rate lines {0}, gameplay (draws >= {1}) {2}' -f $r.lines, $MinDraws, $r.gameplay_lines
'frame generation: {0} frames shown for each rendered' -f $r.fg_shown_per_rendered
foreach ($k in 'fps', 'shown_fps', 'ms', 'preparing_ms', 'copies_ms', 'gpu_ms', 'copy_back_ms', 'draws') {
    $s = $r[$k]; if ($null -eq $s.median) { continue }
    '{0,-14} p10 {1,7:N1}  median {2,7:N1}  p90 {3,7:N1}  min {4,7:N1}  max {5,8:N1}' -f $k, $s.p10, $s.median, $s.p90, $s.min, $s.max
}
'submitting thread: worked {0} ms, of it waiting for the card {1}, lists'' steps {2} (refreshes {3}), planning card steps {4}; card busy {5}%' -f $r.submit_thread_worked_ms, $r.submit_waiting_for_card_ms, $r.lists_steps_ms, $r.refreshes_ms, $r.planning_card_steps_ms, $r.card_busy_pct
if ($r.wait_reasons) { 'wait reasons: ' + $r.wait_reasons }
foreach ($b in $r.blame) { 'blame: ' + $b }
foreach ($a in $r.ab) { $a }
'warnings {0}; faults: {1}' -f $r.warnings, ($(if ($r.faults.Count) { $r.faults -join ' | ' } else { 'none' }))
if ($Timeline) { $rows | ForEach-Object { '{0:HH:mm:ss} {1,6:N1} fps {2,7:N1} ms prep {3,5:N1} gpu {4,5:N1} draws {5}' -f $_.t, $_.fps, $_.ms, $_.prep, $_.gpu, $_.draws } }
