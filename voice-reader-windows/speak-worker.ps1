# Reads queued replies aloud, oldest first, one at a time (a named mutex keeps a single reader).
# A reply is read only while its session is the one open in the Claude app (the page address,
# read through UI Automation). Reading pauses while the person writes or dictates a prompt
# (text in the prompt field, or the microphone in use). Leaving that session for more than 3 s
# puts the reply back in the queue, read from the start on return, so other sessions go on.
# Replies older than an hour are dropped. Nothing new starts while the person is away
# (presence.json from read-aloud.ps1); speaking.flag tells it a reply is being read.
# A file whose first line is "*" was asked for by hand (read-aloud.ps1): it goes first, interrupts
# a reply (read again from the start afterwards) and pauses only for the microphone.
# stop.flag in the root stops what is being read and drops what was asked for by hand.
param([string]$Root)
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Speech, UIAutomationClient, UIAutomationTypes
$queue = Join-Path $Root 'queue'
New-Item -ItemType Directory -Force -Path $queue | Out-Null
$mutex = New-Object System.Threading.Mutex($false, 'Local\claude-tts-reader')

$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]::Descendants
$docCond = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'RootWebArea')
$editCond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)),
    (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Промпт')))
$micKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'

function Value($el) { try { $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { $null } }

# Which session the app shows (local_<id>, or $null), and whether the prompt field holds text.
function Get-View {
    $view = @{ Session = $null; Typing = $false }
    $p = Get-Process claude | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { return $view }
    try {
        # The app's shell is a page too (file://...); the session is the page whose address names one.
        foreach ($doc in $AE::FromHandle($p.MainWindowHandle).FindAll($Scope, $docCond)) {
            $m = [regex]::Match([string](Value $doc), 'local_[0-9a-f-]{36}')
            if (-not $m.Success) { continue }
            $view.Session = $m.Value
            $view.Typing = -not [string]::IsNullOrWhiteSpace([string](Value ($doc.FindFirst($Scope, $editCond))))
            break
        }
    } catch { }
    $view
}

# An app records the microphone in use (LastUsedTimeStop 0 or before its start) within the last 3 hours.
function Mic-Busy {
    $recent = [DateTime]::UtcNow.AddHours(-3).ToFileTimeUtc()
    foreach ($k in Get-ChildItem $micKey -Recurse) {
        $v = Get-ItemProperty $k.PSPath
        if ($null -ne $v.LastUsedTimeStart -and $v.LastUsedTimeStart -gt $recent -and $v.LastUsedTimeStop -lt $v.LastUsedTimeStart) { return $true }
    }
    $false
}

function Queued {
    $old = [DateTime]::Now.AddHours(-1)
    Get-ChildItem -LiteralPath $queue -Filter '*.txt' | Where-Object { $_.LastWriteTime -lt $old } | Remove-Item
    @(Get-ChildItem -LiteralPath $queue -Filter '*.txt' | Sort-Object Name)
}
function Manual { @(Get-ChildItem -LiteralPath $queue -Filter '*-manual.txt' | Sort-Object Name) }
$stopFlag = Join-Path $Root 'stop.flag'
$speakingFlag = Join-Path $Root 'speaking.flag'
$presenceFile = Join-Path $Root 'presence.json'

# Away by presence.json, if read-aloud.ps1 updated it within the last minute.
function Is-Away {
    try {
        $p = [IO.File]::ReadAllText($presenceFile) | ConvertFrom-Json
        $p.away -and ([DateTime]::UtcNow - [DateTime]::Parse($p.updatedAt).ToUniversalTime()).TotalSeconds -lt 60
    } catch { $false }
}

# The oldest reply of the session on screen, or one from outside the desktop app.
function Next-Reply($session) {
    $m = Manual | Select-Object -First 1
    if ($m) { return $m }
    foreach ($f in Queued) {
        $sid = ([IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8))[0]
        if (-not $sid -or $sid -eq $session) { return $f }
    }
}

while ($true) {
    try { if (-not $mutex.WaitOne(0)) { exit 0 } } catch [System.Threading.AbandonedMutexException] { }
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $synth.SelectVoice('Microsoft Irina Desktop')
    $synth.Rate = 7  # ~2.2x normal speed (scale -10..10, +10 = 3x)
    while ((Queued).Count -gt 0) {
        Remove-Item -LiteralPath $stopFlag
        $view = Get-View
        $f = if ((Mic-Busy) -or (Is-Away)) { $null } elseif ($view.Typing) { Manual | Select-Object -First 1 } else { Next-Reply $view.Session }
        if (-not $f) { Start-Sleep -Milliseconds 400; continue }
        $lines = [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)
        [IO.File]::Delete($f.FullName)
        $sid = $lines[0]
        $text = ($lines | Select-Object -Skip 1) -join "`n"
        if (-not $text) { continue }
        $manual = $sid -eq '*'
        [IO.File]::WriteAllText($speakingFlag, '')
        $prompt = $synth.SpeakAsync($text)
        $paused = $false
        $awaySince = $null
        while (-not $prompt.IsCompleted) {
            Start-Sleep -Milliseconds 250
            if (Test-Path -LiteralPath $stopFlag) {
                Remove-Item -LiteralPath $stopFlag
                Manual | Remove-Item
                if ($paused) { $synth.Resume() }
                $synth.SpeakAsyncCancelAll()
                break
            }
            if (-not $manual -and (Manual).Count -gt 0) {
                # Asked for by hand: put this reply back where it was and give way.
                [IO.File]::WriteAllLines($f.FullName, $lines, [Text.Encoding]::UTF8)
                if ($paused) { $synth.Resume() }
                $synth.SpeakAsyncCancelAll()
                break
            }
            $view = Get-View
            $away = -not $manual -and $sid -and $view.Session -ne $sid
            if (-not $away) { $awaySince = $null }
            elseif (-not $awaySince) { $awaySince = [DateTime]::UtcNow }
            elseif (([DateTime]::UtcNow - $awaySince).TotalSeconds -gt 3) {
                # Gone to another session: keep this reply for later and let others be read.
                [IO.File]::WriteAllLines($f.FullName, $lines, [Text.Encoding]::UTF8)
                if ($paused) { $synth.Resume() }
                $synth.SpeakAsyncCancelAll()
                break
            }
            $hold = (Mic-Busy) -or $away -or (-not $manual -and $view.Typing)
            if ($hold -and -not $paused) { $synth.Pause(); $paused = $true }
            elseif (-not $hold -and $paused) { $synth.Resume(); $paused = $false }
        }
        while (-not $prompt.IsCompleted) { Start-Sleep -Milliseconds 50 }
        Remove-Item -LiteralPath $speakingFlag
    }
    $synth.Dispose()
    $mutex.ReleaseMutex()
    # A reply queued while we were releasing would have found the mutex taken: look once more.
    if ((Queued).Count -eq 0) { exit 0 }
}
