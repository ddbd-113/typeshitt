# Shared helpers for the GUL bench tools: the game's window, its title line, keys, screenshots.
$script:GulRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:GulRuns = Join-Path $env:LOCALAPPDATA 'victory\gul-runs'
$script:GulKeys = Join-Path $script:GulRuns 'keys.txt'
New-Item -ItemType Directory -Force $script:GulRuns | Out-Null

if (-not ('GulWin' -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Runtime.InteropServices;
public static class GulWin {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref Point p);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    // Frame generation runs only while the game's window has the focus: brought to the front (an Alt tap first,
    // which Windows asks of a background process before it lets it change the foreground window).
    public static bool Front(IntPtr h) {
        if (GetForegroundWindow() == h) return true;
        keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero);
        ShowWindow(h, 9);
        SetForegroundWindow(h);
        return GetForegroundWindow() == h;
    }
    public static bool IsFront(IntPtr h) { return GetForegroundWindow() == h; }
    public static Bitmap Capture(IntPtr h, bool fromScreen) {
        RECT r; GetClientRect(h, out r);
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        if (w <= 0 || ht <= 0) return null;
        var bmp = new Bitmap(w, ht);
        using (var g = Graphics.FromImage(bmp)) {
            if (fromScreen) {
                var p = new Point(0, 0); ClientToScreen(h, ref p);
                g.CopyFromScreen(p.X, p.Y, 0, 0, new Size(w, ht));
            } else {
                IntPtr dc = g.GetHdc();
                PrintWindow(h, dc, 3); // client area, full content (D3D)
                g.ReleaseHdc(dc);
            }
        }
        return bmp;
    }
}
'@
}

function Get-GulGame {
    Get-Process victory -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
}

# The layer's own line in the window title: "<region> | VIctory 25.4 fps 39.4 ms/frame 5592 draws/frame".
function Get-GulTitle {
    $p = Get-GulGame
    if (-not $p) { return $null }
    $p.Refresh()
    $t = $p.MainWindowTitle
    # With frame generation: "... 38 fps (frame gen 75 fps) 26.6 ms/frame ...".
    $o = [ordered]@{ title = $t; fps = $null; shown = $null; ms = $null; draws = $null }
    if ($t -match '([\d.]+) fps (?:\(frame gen ([\d.]+) fps\) )?([\d.]+) ms/frame (\d+) draws/frame') {
        $o.fps = [double]$Matches[1]; $o.ms = [double]$Matches[3]; $o.draws = [int]$Matches[4]
        $o.shown = if ($Matches[2]) { [double]$Matches[2] } else { $o.fps }
    }
    [pscustomobject]$o
}

# Keys go to the game through VICTORY_KEYS_FILE, with or without focus: "<key> [<hold s> [<after s>]]".
# Keys: a letter, a digit, Enter, Esc, Tab, Back, Up, Down, Left, Right (letters also press the stand-in pad's buttons).
function Send-GulKey([string]$Key, [double]$Hold = 0.2, [double]$After = 0) {
    $line = ('{0} {1} {2}' -f $Key, $Hold.ToString([Globalization.CultureInfo]::InvariantCulture), $After.ToString([Globalization.CultureInfo]::InvariantCulture))
    [IO.File]::AppendAllText($script:GulKeys, $line + "`n")
}

function Save-GulShot([string]$Path, [int]$Width = 1280) {
    $p = Get-GulGame
    if (-not $p) { return $null }
    # From the screen only: PrintWindow waits for the window's thread, and that hung a run when the game's
    # thread stood still (run fg2, 2026-11-27). The picture is what is on screen where the window is.
    if (-not $p.Responding) { return $null }
    $bmp = [GulWin]::Capture($p.MainWindowHandle, $true)
    if (-not $bmp) { return $null }
    $h = [int]($bmp.Height * $Width / $bmp.Width)
    $small = New-Object System.Drawing.Bitmap $bmp, $Width, $h
    $small.Save($Path, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $small.Dispose(); $bmp.Dispose()
    $Path
}
