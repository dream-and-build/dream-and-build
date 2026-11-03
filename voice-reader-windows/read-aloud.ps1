# Read anything aloud: a tray icon plus global hotkeys, running in the background.
#   Ctrl+Alt+R  read the selected text; with nothing selected, the text under the mouse
#               (in the Claude app: the whole message under the mouse)
#   Ctrl+Alt+S  stop reading
# Right-click the tray icon for the same commands and "read copied text".
# Also holds back sending a dictated prompt until its last words arrive (DictationGuard below),
# and tells whether anyone is at the computer (Presence below).
# Hands the text to speak-worker.ps1's queue (first line "*": read now, before replies).
$ErrorActionPreference = 'SilentlyContinue'
$single = New-Object System.Threading.Mutex($false, 'Local\claude-tts-hotkeys')
if (-not $single.WaitOne(0)) { exit 0 }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes, WindowsBase
# Real pixels, so mouse positions match what UI Automation reports.
Add-Type -Name Dpi -Namespace Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][Native.Dpi]::SetProcessDPIAware()
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Windows.Forms;
public class HotkeyWindow : NativeWindow {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public event Action<int> Pressed;
    public HotkeyWindow() { CreateHandle(new CreateParams()); }
    public bool Register(int id, uint mod, uint vk) { return RegisterHotKey(Handle, id, mod | 0x4000, vk); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && Pressed != null) Pressed(m.WParam.ToInt32());
        base.WndProc(ref m);
    }
}
"@

# Dictation guard. While the Claude app records a dictation a "Отправить" button sits beside
# "Остановить диктовку"; pressing it sends what has been recognized so far, losing the last
# words still being recognized (the text never shows in the prompt field). So "Отправить" or
# Enter pressed while recording is held back: until the recording stops (at most 10 s), then
# 2 s more plus a tenth of the recording's length for its tail to be recognized (at most 12 s
# in all), and then sent.
# The hooks run on a thread of their own and never touch UI Automation, so a slow app can't
# make Windows drop them; a second thread watches the app. Each hold goes to guard.log.
$uiaRefs = @(
    [System.Windows.Automation.AutomationElement].Assembly.Location,
    [System.Windows.Automation.ControlType].Assembly.Location,
    [System.Windows.Point].Assembly.Location,
    [System.Windows.Forms.Form].Assembly.Location)
Add-Type -ReferencedAssemblies $uiaRefs -TypeDefinition @"
using System; using System.Diagnostics; using System.Runtime.InteropServices; using System.Threading;
using System.Windows.Automation; using Microsoft.Win32;
public static class DictationGuard {
    delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc p, IntPtr mod, uint tid);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int c, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string n);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [StructLayout(LayoutKind.Sequential)] struct KbdLL { public uint vk, scan, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MouseLL { public int x, y; public uint data, flags, time; public IntPtr extra; }

    const int Marker = 0x5A5A;  // our own Enter, let through
    const string MicKey = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
    const string SendName = "Отправить", StopName = "Остановить диктовку";
    // Speed does not matter to the person, losing the last words does: never send sooner than MinHold.
    public static double MaxStopWait = 10, BaseTail = 5, TailShare = 0.15, MinHold = 12, MaxHold = 25;
    static readonly string LogPath = System.IO.Path.Combine(Environment.GetEnvironmentVariable("LOCALAPPDATA"), @"claude-tts\guard.log");

    static HookProc kbProc, msProc;
    // Written by the watcher, read by the hooks.
    static volatile bool claudeInFront, recording;
    static System.Windows.Rect sendRect = System.Windows.Rect.Empty;
    static readonly object rectLock = new object();
    // Set by a hook, served by the watcher.
    static volatile int pending;  // 0 none, 1 Enter, 2 send button
    static volatile bool swallowEnterUp, swallowMouseUp, busy;

    static void Log(string line) {
        try { System.IO.File.AppendAllText(LogPath, DateTime.Now.ToString("HH:mm:ss.fff") + " " + line + Environment.NewLine); } catch { }
    }

    public static void Start() {
        Thread hooks = new Thread(() => {
            kbProc = Keyboard; msProc = Mouse;
            IntPtr mod = GetModuleHandle(null);
            SetWindowsHookEx(13, kbProc, mod, 0);
            SetWindowsHookEx(14, msProc, mod, 0);
            System.Windows.Forms.Application.Run();
        });
        hooks.IsBackground = true;
        hooks.SetApartmentState(ApartmentState.STA);
        hooks.Start();
        Thread watcher = new Thread(Watch);
        watcher.IsBackground = true;
        watcher.Start();
        Log("guard started");
    }

    // Seconds since the Claude app last let go of the microphone; 0 while it records.
    // Length of the Claude app's latest recording, in seconds (so far, while it records).
    static double MicDuration() {
        using (RegistryKey root = Registry.CurrentUser.OpenSubKey(MicKey)) {
            if (root == null) return 0;
            foreach (string name in root.GetSubKeyNames()) {
                if (!name.StartsWith("Claude", StringComparison.OrdinalIgnoreCase)) continue;
                using (RegistryKey k = root.OpenSubKey(name)) {
                    object a = k.GetValue("LastUsedTimeStart"), b = k.GetValue("LastUsedTimeStop");
                    if (a == null || b == null) continue;
                    long start = Convert.ToInt64(a), stop = Convert.ToInt64(b);
                    DateTime end = stop < start ? DateTime.UtcNow : DateTime.FromFileTimeUtc(stop);
                    return Math.Max(0, (end - DateTime.FromFileTimeUtc(start)).TotalSeconds);
                }
            }
        }
        return 0;
    }

    public static double SinceMic() {
        double best = 1e9;
        using (RegistryKey root = Registry.CurrentUser.OpenSubKey(MicKey)) {
            if (root == null) return best;
            foreach (string name in root.GetSubKeyNames()) {
                if (!name.StartsWith("Claude", StringComparison.OrdinalIgnoreCase)) continue;
                using (RegistryKey k = root.OpenSubKey(name)) {
                    object a = k.GetValue("LastUsedTimeStart"), b = k.GetValue("LastUsedTimeStop");
                    if (a == null || b == null) continue;
                    long start = Convert.ToInt64(a), stop = Convert.ToInt64(b);
                    if (stop < start) return 0;
                    best = Math.Min(best, (DateTime.UtcNow - DateTime.FromFileTimeUtc(stop)).TotalSeconds);
                }
            }
        }
        return best;
    }

    static IntPtr ClaudeWindow() {
        IntPtr h = GetForegroundWindow(); uint pid;
        GetWindowThreadProcessId(h, out pid);
        try { return Process.GetProcessById((int)pid).ProcessName.Equals("claude", StringComparison.OrdinalIgnoreCase) ? h : IntPtr.Zero; }
        catch { return IntPtr.Zero; }
    }

    static AutomationElement Find(AutomationElement root, ControlType type, string name) {
        return root.FindFirst(TreeScope.Descendants, new AndCondition(
            new PropertyCondition(AutomationElement.ControlTypeProperty, type),
            new PropertyCondition(AutomationElement.NameProperty, name)));
    }

    static string PromptText(AutomationElement win) {
        try {
            AutomationElement e = Find(win, ControlType.Edit, "Промпт");
            object tp;
            if (e != null && e.TryGetCurrentPattern(TextPattern.Pattern, out tp)) return ((TextPattern)tp).DocumentRange.GetText(100000).Trim();
        } catch { }
        return null;
    }

    static bool Press(AutomationElement win, string name) {
        try {
            AutomationElement b = Find(win, ControlType.Button, name);
            object ip;
            if (b != null && b.TryGetCurrentPattern(InvokePattern.Pattern, out ip)) { ((InvokePattern)ip).Invoke(); return true; }
        } catch { }
        return false;
    }

    static void Watch() {
        while (true) {
            try {
                IntPtr h = ClaudeWindow();
                claudeInFront = h != IntPtr.Zero;
                if (!claudeInFront) { recording = false; Thread.Sleep(300); continue; }
                AutomationElement win = AutomationElement.FromHandle(h);
                recording = Find(win, ControlType.Button, StopName) != null;
                AutomationElement send = recording ? Find(win, ControlType.Button, SendName) : null;
                lock (rectLock) sendRect = send != null ? send.Current.BoundingRectangle : System.Windows.Rect.Empty;
                if (pending != 0) Serve(win, pending);
            } catch { }
            Thread.Sleep(120);
        }
    }

    // Let the recording run a little longer, so its last words are recognized, then send.
    static void Serve(AutomationElement win, int what) {
        busy = true;
        try {
            Log((what == 1 ? "Enter" : "send button") + " held while recording");
            DateTime started = DateTime.UtcNow;
            while (SinceMic() == 0 && (DateTime.UtcNow - started).TotalSeconds < MaxStopWait) Thread.Sleep(100);
            double tail = BaseTail + TailShare * MicDuration();
            while ((DateTime.UtcNow - started).TotalSeconds < MaxHold && ((DateTime.UtcNow - started).TotalSeconds < MinHold || SinceMic() < tail)) Thread.Sleep(100);
            if (GetForegroundWindow() != ClaudeWindowHandle(win)) { Log("not sent: another window in front"); System.Media.SystemSounds.Beep.Play(); return; }
            bool pressed = Press(win, SendName);
            if (!pressed) {
                keybd_event(0x0D, 0, 0, new UIntPtr(Marker));
                keybd_event(0x0D, 0, 2, new UIntPtr(Marker));
            }
            Log("sent after " + (DateTime.UtcNow - started).TotalSeconds.ToString("0.0") + " s (recording " + MicDuration().ToString("0") + " s, tail " + tail.ToString("0.0") + " s) by " + (pressed ? "send button" : "Enter"));
        } finally { pending = 0; busy = false; }
    }

    static IntPtr ClaudeWindowHandle(AutomationElement win) {
        try { return new IntPtr(win.Current.NativeWindowHandle); } catch { return IntPtr.Zero; }
    }

    static bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

    static IntPtr Keyboard(int code, IntPtr w, IntPtr l) {
        if (code >= 0) {
            KbdLL k = (KbdLL)Marshal.PtrToStructure(l, typeof(KbdLL));
            if (k.vk == 0x0D && k.extra.ToInt64() != Marker) {
                bool up = (k.flags & 0x80) != 0;
                if (up && swallowEnterUp) { swallowEnterUp = false; return (IntPtr)1; }
                if (!up && (busy || pending != 0)) return (IntPtr)1;
                if (!up && recording && claudeInFront && !Down(0x10) && !Down(0x11) && !Down(0x12)) {
                    swallowEnterUp = true;
                    pending = 1;
                    return (IntPtr)1;
                }
            }
        }
        return CallNextHookEx(IntPtr.Zero, code, w, l);
    }

    static IntPtr Mouse(int code, IntPtr w, IntPtr l) {
        if (code >= 0) {
            int msg = w.ToInt32();
            if (msg == 0x0202 && swallowMouseUp) { swallowMouseUp = false; return (IntPtr)1; }
            if (msg == 0x0201 && recording && claudeInFront && !busy && pending == 0) {
                MouseLL m = (MouseLL)Marshal.PtrToStructure(l, typeof(MouseLL));
                bool onSend;
                lock (rectLock) onSend = !sendRect.IsEmpty && sendRect.Contains(m.x, m.y);
                if (onSend) {
                    swallowMouseUp = true;
                    pending = 2;
                    return (IntPtr)1;
                }
            }
        }
        return CallNextHookEx(IntPtr.Zero, code, w, l);
    }
}
"@

$root = Join-Path $env:LOCALAPPDATA 'claude-tts'
$queue = Join-Path $root 'queue'
New-Item -ItemType Directory -Force -Path $queue | Out-Null
$worker = Join-Path $PSScriptRoot 'speak-worker.ps1'
$AE = [System.Windows.Automation.AutomationElement]
$TP = [System.Windows.Automation.TextPattern]::Pattern
$VP = [System.Windows.Automation.ValuePattern]::Pattern
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$textType = [System.Windows.Automation.ControlType]::Text

function Speak-Now([string]$text) {
    $text = [regex]::Replace($text, '[ \t]+', ' ').Trim()
    if (-not $text) { [System.Media.SystemSounds]::Beep.Play(); return }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    [IO.File]::WriteAllText((Join-Path $queue "$now-manual.txt"), "*`n$text", [Text.Encoding]::UTF8)
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$worker`"", "`"$root`"")
}

function Stop-Reading { [IO.File]::WriteAllText((Join-Path $root 'stop.flag'), '') }

# The selection as the app reports it through UI Automation; no keystrokes.
function Get-UiaSelection {
    try {
        $tp = $AE::FocusedElement.GetCurrentPattern($TP)
        (@($tp.GetSelection()) | ForEach-Object { $_.GetText(100000) }) -join "`n"
    } catch { '' }
}

# Ctrl+C, then the clipboard put back. Never in a console: there Ctrl+C stops the running program.
function Get-CopiedSelection {
    $fg = [HotkeyWindow]::GetForegroundWindow(); [uint32]$procId = 0
    [void][HotkeyWindow]::GetWindowThreadProcessId($fg, [ref]$procId)
    $name = (Get-Process -Id $procId).ProcessName
    if (-not $name -or $name -match '^(WindowsTerminal|conhost|cmd|powershell|pwsh|OpenConsole|mintty|bash|wsl)$') { return '' }
    $saved = [System.Windows.Forms.Clipboard]::GetDataObject()
    $before = [HotkeyWindow]::GetClipboardSequenceNumber()
    [System.Windows.Forms.SendKeys]::SendWait('^c')
    for ($i = 0; $i -lt 12 -and [HotkeyWindow]::GetClipboardSequenceNumber() -eq $before; $i++) { Start-Sleep -Milliseconds 25 }
    if ([HotkeyWindow]::GetClipboardSequenceNumber() -eq $before) { return '' }
    $text = [System.Windows.Forms.Clipboard]::GetText()
    if ($saved) { try { [System.Windows.Forms.Clipboard]::SetDataObject($saved, $true) } catch { } }
    $text
}

# Paragraph texts inside an element: Text nodes not nested in another Text, a button or a status line.
function Collect-Text($el) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $textType)
    $parts = foreach ($t in $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
        $pt = $walker.GetParent($t).Current.ControlType
        if ($pt -eq $textType -or $pt -eq [System.Windows.Automation.ControlType]::Button -or $pt -eq [System.Windows.Automation.ControlType]::StatusBar) { continue }
        $t.Current.Name
    }
    (($parts | Where-Object { $_ }) -join "`n") -replace '^(Ответ Claude|Вы написали|Ваше сообщение):\s*', ''
}

function Get-TextUnderMouse {
    $pos = [System.Windows.Forms.Cursor]::Position
    $el = $AE::FromPoint((New-Object System.Windows.Point($pos.X, $pos.Y)))
    if (-not $el) { return '' }
    # In the Claude app a message is a group named "Сообщение N": read all of it.
    $cur = $el
    for ($i = 0; $i -lt 15 -and $cur; $i++) {
        if ($cur.Current.Name -match '^Сообщение \d+$') { return Collect-Text $cur }
        $cur = $walker.GetParent($cur)
    }
    try { $t = $el.GetCurrentPattern($TP).DocumentRange.GetText(100000); if ($t.Trim()) { return $t } } catch { }
    try { $t = $el.GetCurrentPattern($VP).Current.Value; if ($t.Trim()) { return $t } } catch { }
    # A short label: read its block instead (the parent's paragraphs).
    $parent = $walker.GetParent($el)
    $t = if ($parent) { Collect-Text $parent } else { '' }
    if ($t.Length -gt $el.Current.Name.Length) { $t } else { $el.Current.Name }
}

function Read-Selection {
    # Let go of Ctrl/Alt first, or the copy would be Ctrl+Alt+C.
    for ($i = 0; $i -lt 60 -and (([HotkeyWindow]::GetAsyncKeyState(0x11) -band 0x8000) -or ([HotkeyWindow]::GetAsyncKeyState(0x12) -band 0x8000)); $i++) { Start-Sleep -Milliseconds 25 }
    $text = Get-UiaSelection
    if (-not "$text".Trim()) { $text = Get-CopiedSelection }
    if (-not "$text".Trim()) { $text = Get-TextUnderMouse }
    Speak-Now $text
}

$hk = New-Object HotkeyWindow
$MOD = 0x0001 -bor 0x0002  # Alt + Ctrl
$okRead = $hk.Register(1, $MOD, 0x52)  # R
$okStop = $hk.Register(2, $MOD, 0x53)  # S
$hk.add_Pressed({ param($id) if ($id -eq 1) { Read-Selection } elseif ($id -eq 2) { Stop-Reading } })

$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Прочитать скопированный текст', $null, { Speak-Now ([System.Windows.Forms.Clipboard]::GetText()) })
[void]$menu.Items.Add('Остановить чтение   Ctrl+Alt+S', $null, { Stop-Reading })
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Выход', $null, { $icon.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = [System.Drawing.SystemIcons]::Information
$icon.Text = 'Озвучка: Ctrl+Alt+R прочитать, Ctrl+Alt+S стоп'
$icon.ContextMenuStrip = $menu
$icon.Visible = $true
if (-not ($okRead -and $okStop)) { $icon.ShowBalloonTip(5000, 'Озвучка', 'Ctrl+Alt+R или Ctrl+Alt+S уже занята другой программой', 'Warning') }
[DictationGuard]::Start()

# Presence: away after 5 minutes with no keyboard, mouse or microphone, unless a full-screen
# window (a video) is in front or a reply is being read aloud. The state goes to presence.json
# (the reader and the reminder task read it); coming back after 5+ minutes away is written to
# the exercise log as a break, so the sitting timer starts over.
Add-Type -ReferencedAssemblies ([System.Windows.Forms.Form].Assembly.Location), ([System.Drawing.Rectangle].Assembly.Location) -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class Presence {
    [StructLayout(LayoutKind.Sequential)] struct LastInput { public uint cbSize; public uint dwTime; }
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LastInput p);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);

    public static double IdleSeconds() {
        LastInput l = new LastInput(); l.cbSize = 8;
        GetLastInputInfo(ref l);
        return unchecked((uint)Environment.TickCount - l.dwTime) / 1000.0;
    }

    public static bool FullScreen() {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return false;
        StringBuilder c = new StringBuilder(64); GetClassName(h, c, 64);
        string k = c.ToString();
        if (k == "Progman" || k == "WorkerW" || k == "Shell_TrayWnd") return false;
        Rect r; if (!GetWindowRect(h, out r)) return false;
        System.Drawing.Rectangle b = System.Windows.Forms.Screen.FromHandle(h).Bounds;
        return r.L <= b.Left && r.T <= b.Top && r.R >= b.Right && r.B >= b.Bottom;
    }
}
"@

$AwayAfter = 300  # seconds without input
$presenceFile = Join-Path $root 'presence.json'
$speakingFlag = Join-Path $root 'speaking.flag'
$activityLog = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Физическая активность\activity-log.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$script:awaySince = $null
$script:busyAt = [DateTime]::UtcNow

function Iso([DateTime]$t) { $t.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }

# Back after $from..$to away: a break in the exercise log (at most 10 minutes count as movement).
function Record-Return([DateTime]$from, [DateTime]$to) {
    $minutes = [int][Math]::Round(($to - $from).TotalMinutes)
    if ($minutes -lt 5 -or -not (Test-Path -LiteralPath $activityLog)) { return }
    try {
        $log = [IO.File]::ReadAllText($activityLog, $utf8) | ConvertFrom-Json
        if (-not $log.dayStart -or $log.dayStart.date -ne (Get-Date).ToString('yyyy-MM-dd')) { return }
        $entries = @($log.entries) + [pscustomobject]@{
            at = Iso $to; what = "Отошёл от компьютера на $minutes мин"; minutes = [Math]::Min($minutes, 10); kind = 'away' }
        $log.entries = $entries
        $log.lastBreakAt = Iso $to
        [IO.File]::WriteAllText($activityLog, ($log | ConvertTo-Json -Depth 6) + "`n", $utf8)
    } catch { }
}

function Check-Presence {
    $now = [DateTime]::UtcNow
    $idle = [Presence]::IdleSeconds()
    $speaking = (Test-Path -LiteralPath $speakingFlag) -and (Get-Item -LiteralPath $speakingFlag).LastWriteTimeUtc -gt $now.AddMinutes(-15)
    if ([Presence]::FullScreen() -or $speaking -or [DictationGuard]::SinceMic() -lt 5) { $script:busyAt = $now }
    $lastInput = $now.AddSeconds(-$idle)
    if (-not $script:awaySince) {
        $quietSince = if ($lastInput -gt $script:busyAt) { $lastInput } else { $script:busyAt }
        if (($now - $quietSince).TotalSeconds -ge $AwayAfter) { $script:awaySince = $quietSince }
    } elseif ($lastInput -gt $script:awaySince) {
        Record-Return $script:awaySince $lastInput
        $script:awaySince = $null
    }
    $state = [ordered]@{
        away = [bool]$script:awaySince
        since = if ($script:awaySince) { Iso $script:awaySince } else { $null }
        idleSeconds = [int]$idle
        updatedAt = Iso $now
    }
    try { [IO.File]::WriteAllText($presenceFile, ($state | ConvertTo-Json), $utf8) } catch { }
}

$presenceTimer = New-Object System.Windows.Forms.Timer
$presenceTimer.Interval = 5000
$presenceTimer.add_Tick({ Check-Presence })
$presenceTimer.Start()
Check-Presence

[System.Windows.Forms.Application]::Run()
$icon.Dispose()
