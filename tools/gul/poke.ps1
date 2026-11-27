# While the game runs: send keys, wait, take a screenshot, print the title line.
#   .\tools\gul\poke.ps1 -Keys 'Enter' -Wait 3            (keys ';'-separated, "<key> [hold]")
#   .\tools\gul\poke.ps1 -Shot                             (screenshot only)
param([string]$Keys = '', [double]$Wait = 2, [switch]$Shot, [string]$Out = '')
. (Join-Path $PSScriptRoot 'common.ps1')
$inv = [Globalization.CultureInfo]::InvariantCulture
foreach ($k in ($Keys -split ';' | Where-Object { $_ -match '\S' })) {
    $w = $k.Trim() -split '\s+'
    $hold = if ($w.Count -gt 1) { [double]::Parse($w[1], $inv) } else { 0.2 }
    Send-GulKey $w[0] $hold
    Start-Sleep -Milliseconds ([int](($hold + 0.4) * 1000))
}
if ($Wait -gt 0) { Start-Sleep -Milliseconds ([int]($Wait * 1000)) }
$t = Get-GulTitle
if (-not $t) { 'no game window'; return }
$t.title
if (-not $Out) { $Out = Join-Path $script:GulRuns ('poke-{0:HHmmss}.jpg' -f (Get-Date)) }
$p = Save-GulShot $Out
if ($p) { "shot: $p" } else { 'no shot' }
