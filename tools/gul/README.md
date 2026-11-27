# Bench tools: measured runs without anyone at the keyboard

PowerShell scripts that start the game, go from its menus into play with scripted
keys (`VICTORY_KEYS_FILE`), record a stretch of play, close the game and write a
report. Results go to `%LOCALAPPDATA%\victory\gul-runs\`: one folder per run
(`report.txt`, `report.json`, `samples.csv`, `events.txt`, `shots\`) and one line
per run in `results.csv`.

| Script | Does |
|---|---|
| `bench.ps1` | one run: `-Name`, `-Seconds 120`, `-Build release/diag/fast`, `-Set 'VICTORY_X=1;VICTORY_Y=2'`, `-Dlss`, `-FrameGen 2..6`, `-Fps`, `-Walk 'W 4;S 4'`, `-Monitor secondary/primary/X,Y,W,H`, `-BootOnly` |
| `sweep.ps1` | several runs in a row, then the table: `-Runs 'name|build|switches|Key=Value,...'` |
| `results.ps1` | the table of runs |
| `parse.ps1` | a log's frame-rate lines and breakdowns (`-From`/`-To` UTC, `-Json`, `-Timeline`) |
| `poke.ps1` | while the game runs: keys, a wait, a screenshot |
| `menu.txt` | the keys from the window to play (Enter on the account screen loads the last save) |

The game's executable is taken from `victory.toml`'s `game_dir`. The window is made
on the first monitor that is not the primary one (`VICTORY_WINDOW_AREA`), so runs do
not cover the main screen. Frame generation runs only while the game's window has the
focus. A run stops itself if the game's log stops growing for 60 s.

Measured in the save's first room (Series X profile, 2560x1440, DLSS Quality,
RTX 5080, Ryzen 9 9950X3D), release build: about 36 fps rendered; the submitting
thread works about 27 ms a frame and is the limit there.
