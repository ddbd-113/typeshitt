# The table of bench runs (results.csv), newest last.
param([int]$Last = 20)
$csv = Join-Path $env:LOCALAPPDATA 'victory\gul-runs\results.csv'
if (-not (Test-Path $csv)) { 'no runs yet'; return }
Import-Csv $csv | Select-Object -Last $Last | Format-Table -AutoSize time, name, build, framegen, @{n='fps';e={$_.fps_median}}, @{n='p10';e={$_.fps_p10}}, @{n='title';e={$_.title_fps_median}}, @{n='shown';e={$_.title_shown_median}}, @{n='shownp10';e={$_.title_shown_p10}}, @{n='s<58';e={$_.seconds_under_58}}, @{n='fgx';e={$_.fg_ratio}}, @{n='ms';e={$_.ms_median}}, @{n='submit';e={$_.submit_worked_ms}}, @{n='wait';e={$_.waiting_card_ms}}, @{n='prep';e={$_.prep_ms}}, draws, set | Out-String -Width 250
