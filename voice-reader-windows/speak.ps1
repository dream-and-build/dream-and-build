# Stop hook: reads Claude's last reply aloud (Windows System.Speech, voice Irina).
# Disable: remove the "Stop" hook from ~/.claude/settings.json.
$ErrorActionPreference = 'SilentlyContinue'

$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)
$raw = $reader.ReadToEnd()
if (-not $raw) { exit 0 }
$payload = $raw | ConvertFrom-Json

# Prefer the field Claude Code passes directly; fall back to the transcript.
$text = $payload.last_assistant_message
if (-not $text -and $payload.transcript_path -and (Test-Path -LiteralPath $payload.transcript_path)) {
    $lines = Get-Content -LiteralPath $payload.transcript_path -Encoding UTF8 -Tail 200
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $entry = $lines[$i] | ConvertFrom-Json
        if ($entry.type -ne 'assistant') { continue }
        $parts = @($entry.message.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
        if ($parts.Count -gt 0) { $text = $parts -join "`n"; break }
    }
}
if (-not $text) { exit 0 }

# Strip what sounds bad aloud: code, markup, links, paths.
$t = $text
$t = [regex]::Replace($t, '(?s)```.*?```', ' ')
$t = [regex]::Replace($t, '\[([^\]]+)\]\([^)]*\)', '$1')
$t = [regex]::Replace($t, '`([^`]{1,30})`', '$1')
$t = [regex]::Replace($t, '`[^`]*`', ' ')
$t = [regex]::Replace($t, 'https?://\S+', ' ')
$t = [regex]::Replace($t, '[A-Za-z]:\\\S+', ' ')
$t = [regex]::Replace($t, '(?m)^\s*\|?[\s:|-]+\|[\s:|-]*$', ' ')
$t = [regex]::Replace($t, '(?m)^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+', '')
$t = $t -replace '\*\*|__|\*|~~|\|', ' '
$t = [regex]::Replace($t, '[ \t]+', ' ').Trim()
if (-not $t) { exit 0 }

# The desktop app keeps one JSON per session, local_<id>.json, holding its title.
$appFile = $null
foreach ($f in Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Claude-Data\*\claude-code-sessions\*\*\local_*.json')) {
    if ($payload.session_id -and [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8).Contains('"cliSessionId":"' + $payload.session_id + '"')) { $appFile = $f; break }
}
if ($appFile) {
    $title = ([IO.File]::ReadAllText($appFile.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json).title
    if ($title) { $t = "Сессия $title. $t" }
}

# LOCALAPPDATA, not TEMP: TEMP is an 8.3 short path that PowerShell cmdlets fail to resolve here.
# Each file: first line the app session id (local_<id>, empty outside the desktop app), then the text.
# The reader speaks it only while that session is the one open in the app.
$root = Join-Path $env:LOCALAPPDATA 'claude-tts'
$dir = Join-Path $root 'queue'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$sid = if ($appFile) { $appFile.BaseName } else { '' }
# Only the newest reply of a session waits: an older one still queued is dropped.
if ($sid) {
    foreach ($old in Get-ChildItem -LiteralPath $dir -Filter '*.txt') {
        if (([IO.File]::ReadAllLines($old.FullName, [Text.Encoding]::UTF8))[0] -eq $sid) { Remove-Item -LiteralPath $old.FullName }
    }
}
$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$textFile = Join-Path $dir ("$now-" + [guid]::NewGuid().ToString('N') + '.txt')
[IO.File]::WriteAllText($textFile, "$sid`n$t", [Text.Encoding]::UTF8)

# Start a reader; if one is already running it picks this file up and the new one exits.
$worker = Join-Path $PSScriptRoot 'speak-worker.ps1'
Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$worker`"", "`"$root`"")
exit 0
