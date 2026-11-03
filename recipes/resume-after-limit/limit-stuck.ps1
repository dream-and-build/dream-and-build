# Lists sessions whose last turn was stopped by the usage limit, as JSON:
# [{ sessionId, title, stoppedAt }]. Used by the "resume after limit" scheduled task.
param([double]$Days = 2)
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$skip = '^(❓ )?(🏃 Напоминание размяться|Сессии, которым нужно моё внимание|🔁 Продолжить после лимита)'
$since = (Get-Date).ToUniversalTime().AddDays(-$Days)
$projects = Join-Path $HOME '.claude\projects'
$out = @()

# Transcripts touched in the window, by CLI session id (top level of each project folder only).
$transcripts = @{}
foreach ($d in Get-ChildItem -Path $projects -Directory) {
    foreach ($j in Get-ChildItem -Path $d.FullName -Filter '*.jsonl' -File) {
        if ($j.LastWriteTimeUtc -ge $since) { $transcripts[$j.BaseName] = $j }
    }
}

# Session files are large (they carry MCP configs): read the few fields with regexes, not a JSON parse.
function Field($json, $name) {
    $m = [regex]::Match($json, '"' + $name + '":"((?:[^"\\]|\\.)*)"')
    if ($m.Success) { [regex]::Unescape($m.Groups[1].Value) }
}

foreach ($f in Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Claude-Data\*\claude-code-sessions\*\*\local_*.json')) {
    if ($f.LastWriteTimeUtc -lt $since) { continue }
    $json = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
    if ($json.Contains('"isArchived":true')) { continue }
    $title = Field $json 'title'
    if ($title -match $skip) { continue }
    $t = $transcripts[(Field $json 'cliSessionId')]
    if (-not $t) { continue }

    # The last real message, skipping meta lines and bookkeeping records.
    $last = $null
    # Get-Content -Tail crawls on long transcripts; read the last 2 MB directly.
    $fs = [IO.File]::Open($t.FullName, 'Open', 'Read', 'ReadWrite')
    $n = [Math]::Min($fs.Length, 2MB)
    [void]$fs.Seek(-$n, 'End')
    $buf = New-Object byte[] $n
    [void]$fs.Read($buf, 0, $n)
    $fs.Close()
    $lines = [Text.Encoding]::UTF8.GetString($buf) -split "`n"
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $l = $lines[$i]
        if ($l -notmatch '"type":"(user|assistant)"' -or $l.Contains('"isMeta":true')) { continue }
        $last = $l; break
    }
    if (-not $last -or -not $last.Contains('"error":"rate_limit"')) { continue }
    $at = Field $last 'timestamp'
    if (-not $at -or [DateTime]::Parse($at).ToUniversalTime() -lt $since) { continue }
    $out += [pscustomobject]@{ sessionId = Field $json 'sessionId'; title = $title; stoppedAt = $at }
}

ConvertTo-Json -InputObject @($out) -Compress
