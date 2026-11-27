# Several bench runs one after another, then the table of results.
#   .\tools\gul\sweep.ps1 -Runs 'base|release|', 'fill|release|VICTORY_FILL_TITLE=1'
# Each entry: "<name>|<build>|<switches>[|<extra bench args as Key=Value,...>]".
param([Parameter(Mandatory)][string[]]$Runs, [int]$Seconds = 120)
foreach ($r in $Runs) {
    $name, $build, $set, $extra = $r -split '\|', 4
    $a = @{ Name = $name; Build = $(if ($build) { $build } else { 'release' }); Set = $set; Seconds = $Seconds }
    foreach ($kv in ($extra -split ',' | Where-Object { $_ -match '=' })) { $k, $v = $kv -split '=', 2; $a[$k.Trim()] = $v.Trim() }
    # (The whole output is taken: cutting the pipeline short would stop the run.)
    $out = @(& (Join-Path $PSScriptRoot 'bench.ps1') @a)
    $out | Where-Object { $_ -match '^(run |window-title|fps |\d\d:\d\d:\d\d (play|the game))' }
}
& (Join-Path $PSScriptRoot 'results.ps1') -Last $Runs.Count
