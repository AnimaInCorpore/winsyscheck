param(
    [switch]$Web,
    [int]$Port = 8888,
    [int]$Days = 7
)

$Since = (Get-Date).AddDays(-$Days)

# --- Helpers ---

function Get-TimeAgo($dt) {
    $diff = (Get-Date) - $dt
    if     ($diff.TotalMinutes -lt 60)  { "$([int]$diff.TotalMinutes)m ago" }
    elseif ($diff.TotalHours   -lt 24)  { "$([int]$diff.TotalHours)h ago" }
    elseif ($diff.TotalDays    -lt 2)   { "yesterday" }
    elseif ($diff.TotalDays    -lt 7)   { "$([int]$diff.TotalDays) days ago" }
    elseif ($diff.TotalDays    -lt 14)  { "last week" }
    else                                { "$([int]($diff.TotalDays/7)) weeks ago" }
}

function Get-LevelSeverity($level) {
    switch ($level) {
        1 { "CRITICAL" }
        2 { "HIGH" }
        3 { "MEDIUM" }
        default { "LOW" }
    }
}

function Get-SecuritySeverity($id) {
    switch ($id) {
        4726 { "CRITICAL" }                              # User account deleted
        { $_ -in 4625, 4720, 4732, 4740, 4776 } { "HIGH" }   # Logon failure, account created, group change, lockout, NTLM failure
        { $_ -in 4648, 4672 } { "MEDIUM" }              # Explicit credentials, special privileges
        default { "LOW" }
    }
}

function Get-LevelEvents($logs, $startTime) {
    $seen   = [System.Collections.Generic.HashSet[string]]::new()
    $filter = @{LogName=$logs; Level=$null}
    if ($startTime) { $filter.StartTime = $startTime }
    1..3 | ForEach-Object {
        $filter.Level = $_
        Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue |
            Where-Object { $seen.Add("$($_.ProviderName)-$($_.Id)") } |
            Select-Object -First 5
    } | Where-Object { $_ -ne $null } |
        Sort-Object TimeCreated -Descending |
        Select-Object @{n='Severity';e={Get-LevelSeverity $_.Level}},
                      @{n='When';e={Get-TimeAgo $_.TimeCreated}},
                      TimeCreated, LogName, ProviderName, Id,
                      @{n='Message';e={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(200,$_.Message.Length))}}
}

function Invoke-LlmAnalysis($category, $events) {
    $eventText = $events | Out-String
    $fence = '```'
    $userMessage = @"
Analyze the following Windows [$category] events and report each issue using the template below. Be short and concise.

Use the following template for each issue, separated by a blank line. Sort by severity (CRITICAL first):

Event:       <short event name>
Severity:    <CRITICAL | HIGH | MEDIUM | LOW>
Date:        <date and time> (<time ago>)
Source:      <log name> / <provider name> (Event ID: <id>)
Description: <one sentence explaining what happened>
Action:      <one sentence describing the fix or next step>

${fence}text
$eventText
${fence}
"@
    $payload = @{
        model    = "local-model"
        messages = @(
            @{ role = "system"; content = "You are a Windows system service professional" },
            @{ role = "user";   content = $userMessage }
        )
        temperature = 0.2
    } | ConvertTo-Json -Depth 5

    try {
        $response = Invoke-RestMethod -Uri $ApiUrl -Method Post -Body $payload -ContentType "application/json" -TimeoutSec 300
        $response.choices[0].message.content
    } catch {
        Write-Host "  Failed to reach LLM: $_" -ForegroundColor Red
    }
}

# --- Configuration ---

$ApiUrl = "http://localhost:8080/v1/chat/completions" # Update port if using LM Studio (1234) or Ollama (11434)

# Source groups ordered by importance
$SourceGroups = @(
    @{
        Category = "Security"
        Mode     = "ids"
        Logs     = "Security"
        Ids      = @(4625, 4648, 4672, 4720, 4726, 4732, 4740, 4776)
        # 4625=logon failure, 4648=explicit credentials, 4672=special privileges,
        # 4720=account created, 4726=account deleted, 4732=group change, 4740=lockout, 4776=NTLM failure
    },
    @{
        Category = "Hardware & Power"
        Mode     = "levels"
        Logs     = @('Hardware Events', 'Microsoft-Windows-Kernel-Power/Operational', 'Microsoft-Windows-Ntfs/Operational')
    },
    @{
        Category = "Core OS"
        Mode     = "levels"
        Logs     = @('System', 'Application')
    },
    @{
        Category = "Drivers"
        Mode     = "levels"
        Logs     = @('Microsoft-Windows-DriverFrameworks-UserMode/Operational')
    },
    @{
        Category = "Network"
        Mode     = "levels"
        Logs     = @('Microsoft-Windows-NetworkProfile/Operational', 'Microsoft-Windows-DNS-Client/Operational')
    },
    @{
        Category = "Performance"
        Mode     = "levels"
        Logs     = @('Microsoft-Windows-Diagnostics-Performance/Operational', 'Microsoft-Windows-WMI-Activity/Operational')
    },
    @{
        Category = "Antivirus & Defense"
        Mode     = "levels"
        Logs     = @('Microsoft-Windows-Windows Defender/Operational')
    },
    @{
        Category = "Updates & Tasks"
        Mode     = "levels"
        Logs     = @('Microsoft-Windows-WindowsUpdateClient/Operational', 'Microsoft-Windows-Bits-Client/Operational', 'Microsoft-Windows-TaskScheduler/Operational')
    }
)

# --- Web Mode ---

if ($Web) {
    $html = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Windows System Check</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { background: #0d1117; color: #c9d1d9; font-family: 'Segoe UI', system-ui, sans-serif; min-height: 100vh; }

header {
    background: #161b22;
    border-bottom: 1px solid #30363d;
    padding: 18px 28px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
}
.header-left { display: flex; flex-direction: column; gap: 3px; }
h1 { font-size: 1.25rem; font-weight: 600; color: #58a6ff; letter-spacing: .3px; }
.sysinfo { font-size: 0.72rem; color: #484f58; letter-spacing: .2px; }
.llminfo { font-size: 0.72rem; color: #484f58; letter-spacing: .2px; }
.llminfo .dot-online  { color: #3fb950; }
.llminfo .dot-offline { color: #f85149; }

.header-right { display: flex; align-items: center; gap: 12px; }
.preset-btns { display: flex; gap: 4px; }
.preset {
    background: #21262d;
    color: #8b949e;
    border: 1px solid #30363d;
    padding: 5px 11px;
    border-radius: 5px;
    font-size: 0.75rem;
    cursor: pointer;
    transition: background .15s, color .15s, border-color .15s;
    white-space: nowrap;
}
.preset:hover:not(:disabled) { background: #2d333b; color: #c9d1d9; border-color: #484f58; }
.preset.active { background: #1f3a5f; color: #58a6ff; border-color: #388bfd; }
.preset:disabled { opacity: .4; cursor: not-allowed; }

#btn-start {
    background: #238636;
    color: #fff;
    border: 1px solid #2ea043;
    padding: 9px 22px;
    border-radius: 6px;
    font-size: 0.88rem;
    font-weight: 700;
    letter-spacing: .5px;
    cursor: pointer;
    transition: background .15s, border-color .15s;
    white-space: nowrap;
}
#btn-start:hover:not(:disabled) { background: #2ea043; }
#btn-start:disabled { background: #21262d; border-color: #30363d; color: #484f58; cursor: not-allowed; }

#status-bar {
    padding: 7px 28px;
    font-size: 0.76rem;
    color: #8b949e;
    background: #0d1117;
    border-bottom: 1px solid #21262d;
    min-height: 29px;
    transition: color .2s;
}

.grid {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 20px 28px;
    max-width: 860px;
    margin: 0 auto;
}

.card { border-bottom: 1px solid #21262d; }
.card:last-child { border-bottom: none; }

.card-header {
    padding: 10px 4px 10px 12px;
    display: flex;
    align-items: center;
    gap: 9px;
    border-left: 3px solid #30363d;
    cursor: pointer;
    user-select: none;
    transition: border-left-color .3s;
}
.card-header:hover { background: rgba(255,255,255,.03); }

.card.analyzing .card-header { border-left-color: #d29922; }
.card.clean     .card-header { border-left-color: #3fb950; }
.card.critical  .card-header { border-left-color: #f85149; }
.card.high      .card-header { border-left-color: #bd561d; }
.card.medium    .card-header { border-left-color: #d29922; }
.card.low       .card-header { border-left-color: #388bfd; }
.card.llm-error .card-header { border-left-color: #8b5cf6; }

.chevron { font-size: 0.65rem; color: #484f58; transition: transform .2s; margin-left: 2px; }
.card.collapsed .chevron { transform: rotate(-90deg); }
.card.collapsed .card-body { display: none; }

@keyframes blink { 0%,100% { opacity:1; } 50% { opacity:.25; } }

.card-title {
    font-size: 0.88rem; font-weight: 600; flex: 1;
    color: #8b949e;
    transition: color .3s;
}
.card.analyzing .card-title { color: #d29922; animation: blink 1.1s ease-in-out infinite; }
.card.clean     .card-title { color: #3fb950; }
.card.critical  .card-title { color: #f85149; }
.card.high      .card-title { color: #bd561d; }
.card.medium    .card-title { color: #d29922; }
.card.low       .card-title { color: #e6edf3; }
.card.llm-error .card-title { color: #8b5cf6; }

.card-status { font-size: 0.72rem; color: #484f58; white-space: nowrap; }
.card.analyzing .card-status { color: #d29922; }
.card.clean     .card-status { color: #3fb950; }
.card.critical  .card-status { color: #f85149; }
.card.high      .card-status { color: #bd561d; }
.card.medium    .card-status { color: #d29922; }
.card.low       .card-status { color: #388bfd; }

.card-body { padding: 8px 0 14px 15px; }
.card-body:empty::after { content: "Waiting…"; color: #30363d; font-size: 0.78rem; font-style: italic; }
.card.collapsed .card-body:empty::after { display: none; }

.issue {
    background: #161b22;
    border-radius: 4px;
    padding: 10px 13px;
    margin-bottom: 8px;
    border-left: 3px solid #30363d;
}
.issue:last-child { margin-bottom: 0; }
.issue.old { opacity: 0.45; }
.issue.CRITICAL { border-left-color: #f85149; }
.issue.HIGH     { border-left-color: #bd561d; }
.issue.MEDIUM   { border-left-color: #d29922; }
.issue.LOW      { border-left-color: #388bfd; }

.issue-top  { display: flex; align-items: center; gap: 8px; margin-bottom: 5px; }
.issue-name { font-size: 0.85rem; font-weight: 600; color: #e6edf3; }
.sev-badge  {
    font-size: 0.63rem; font-weight: 700; letter-spacing: .5px;
    padding: 2px 6px; border-radius: 3px; white-space: nowrap; flex-shrink: 0;
}
.sev-CRITICAL { background: #3d0f0f; color: #f85149; }
.sev-HIGH     { background: #3d1f0f; color: #e0734a; }
.sev-MEDIUM   { background: #3d330f; color: #d29922; }
.sev-LOW      { background: #0f1f3d; color: #388bfd; }

.issue-meta   { font-size: 0.73rem; color: #484f58; line-height: 1.4; margin-bottom: 6px; }
.issue-desc   { font-size: 0.82rem; color: #c9d1d9; line-height: 1.5; margin-bottom: 5px; }
.issue-action { font-size: 0.78rem; color: #58a6ff; line-height: 1.4; }
.issue-action::before { content: "→ "; }

.clean-msg { color: #3fb950; font-size: 0.82rem; padding: 4px 0; }
.error-msg { color: #8b5cf6; font-size: 0.82rem; padding: 4px 0; white-space: pre-wrap; word-break: break-word; }

.note {
    padding: 10px 28px 24px;
    font-size: 0.72rem;
    color: #484f58;
    line-height: 1.5;
}
</style>
</head>
<body>
<header>
    <div class="header-left">
        <h1>Windows System Check</h1>
        <span class="sysinfo">{{SYSINFO}}</span>
        <span class="llminfo">{{LLMINFO}}</span>
    </div>
    <div class="header-right">
        <div class="preset-btns" id="presets">
            <button class="preset" data-days="-1"        onclick="selectPreset(this)">since boot</button>
            <button class="preset" data-days="1"        onclick="selectPreset(this)">24 hours</button>
            <button class="preset" data-days="7"        onclick="selectPreset(this)">one week</button>
            <button class="preset" data-days="0"        onclick="selectPreset(this)">all</button>
        </div>
        <button id="btn-start" onclick="startCheck()">START CHECK</button>
    </div>
</header>
<div id="status-bar">Ready — click START CHECK to begin</div>
<div class="grid" id="grid"></div>
<div class="note" id="note"></div>

<script>
const CATEGORIES = [
    "Security", "Hardware & Power", "Core OS", "Drivers",
    "Network", "Performance", "Antivirus & Defense", "Updates & Tasks"
];

function slug(s) { return s.replace(/[^a-z0-9]+/gi, '-').toLowerCase(); }

function esc(s) {
    return String(s)
        .replace(/&/g,'&amp;').replace(/</g,'&lt;')
        .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function buildGrid() {
    const grid = document.getElementById('grid');
    grid.innerHTML = CATEGORIES.map(cat => `
        <div class="card collapsed" id="card-${slug(cat)}">
            <div class="card-header" onclick="toggleCard('${slug(cat)}')">
                <span class="card-title">${esc(cat)}</span>
                <span class="card-status">Waiting</span>
                <span class="chevron">&#9660;</span>
            </div>
            <div class="card-body"></div>
        </div>`).join('');
}

function toggleCard(id) {
    const card = document.getElementById('card-' + id);
    if (card) card.classList.toggle('collapsed');
}

function setCard(cat, state, statusText, bodyHtml) {
    const card = document.getElementById('card-' + slug(cat));
    if (!card) return;
    const wasCollapsed = card.classList.contains('collapsed');
    card.className = 'card ' + state + (wasCollapsed ? ' collapsed' : '');
    card.querySelector('.card-status').textContent = statusText;
    if (bodyHtml !== undefined) {
        card.querySelector('.card-body').innerHTML = bodyHtml;
        card.classList.remove('collapsed'); // auto-expand when result arrives
    }
}

function parseIssues(text) {
    // Split on blank lines, keep blocks that look like an issue entry
    return text.split(/\n\s*\n/)
        .filter(b => /^Event:/mi.test(b))
        .map(b => {
            const get = key => { const m = b.match(new RegExp('^' + key + ':\\s*(.+)', 'mi')); return m ? m[1].trim() : ''; };
            return {
                event:       get('Event'),
                severity:    get('Severity').toUpperCase(),
                date:        get('Date'),
                source:      get('Source'),
                description: get('Description'),
                action:      get('Action')
            };
        })
        .filter(i => i.event);
}

function highestSeverity(issues) {
    if (issues.some(i => i.severity === 'CRITICAL')) return 'critical';
    if (issues.some(i => i.severity === 'HIGH'))     return 'high';
    if (issues.some(i => i.severity === 'MEDIUM'))   return 'medium';
    return 'low';
}

const SEV_ORDER = { CRITICAL: 0, HIGH: 1, MEDIUM: 2, LOW: 3 };

function isOlderThanWeek(dateStr) {
    if (!dateStr) return false;
    const m = dateStr.match(/^(.+?)\s*\(/);
    const d = new Date(m ? m[1].trim() : dateStr.trim());
    return !isNaN(d) && (Date.now() - d.getTime()) > 7 * 24 * 60 * 60 * 1000;
}

function renderIssues(text) {
    const issues = parseIssues(text);
    if (!issues.length) {
        return `<div class="issue LOW"><div class="issue-desc" style="white-space:pre-wrap;font-size:.73rem">${esc(text.trim())}</div></div>`;
    }
    issues.sort((a, b) => (SEV_ORDER[a.severity] ?? 4) - (SEV_ORDER[b.severity] ?? 4));
    return issues.map(i => `
        <div class="issue ${i.severity}${isOlderThanWeek(i.date) ? ' old' : ''}">
            <div class="issue-top">
                <span class="sev-badge sev-${i.severity}">${esc(i.severity)}</span>
                <span class="issue-name">${esc(i.event)}</span>
            </div>
            ${i.date        ? `<div class="issue-meta">${esc(i.date)}${i.source ? ' &nbsp;&middot;&nbsp; ' + esc(i.source) : ''}</div>` : ''}
            ${i.description ? `<div class="issue-desc">${esc(i.description)}</div>` : ''}
            ${i.action      ? `<div class="issue-action">${esc(i.action)}</div>` : ''}
        </div>`).join('');
}

function selectPreset(el) {
    document.querySelectorAll('.preset').forEach(b => b.classList.remove('active'));
    el.classList.add('active');
}

function activePresetDays() {
    const active = document.querySelector('.preset.active');
    return active ? active.dataset.days : '7';
}

function setPresetsDisabled(on) {
    document.querySelectorAll('.preset').forEach(b => b.disabled = on);
}

document.querySelector('.preset[data-days="0"]').classList.add('active');

function startCheck() {
    const btn = document.getElementById('btn-start');
    btn.disabled = true;
    btn.textContent = 'RUNNING…';
    document.getElementById('note').textContent = '';
    buildGrid();

    const days = activePresetDays();
    setPresetsDisabled(true);
    const es = new EventSource('/stream?days=' + days);
    let done = 0;

    es.onmessage = e => {
        const msg = JSON.parse(e.data);

        if (msg.type === 'start') {
            setCard(msg.category, 'analyzing', 'Analyzing…');
            document.getElementById('status-bar').textContent = 'Analyzing: ' + msg.category;

        } else if (msg.type === 'result') {
            if (msg.clean) {
                setCard(msg.category, 'clean', 'Clean', '<div class="clean-msg">&#10003; No issues found</div>');
            } else if (msg.error) {
                setCard(msg.category, 'llm-error', 'LLM error', `<div class="error-msg">${esc(msg.text)}</div>`);
            } else {
                const issues = parseIssues(msg.text);
                const sev = issues.length ? highestSeverity(issues) : 'low';
                const label = issues.length ? issues.length + ' issue' + (issues.length > 1 ? 's' : '') : 'Issues';
                setCard(msg.category, sev, label, renderIssues(msg.text));
            }
            done++;

        } else if (msg.type === 'done') {
            es.close();
            btn.disabled = false;
            btn.textContent = 'RUN AGAIN';
            setPresetsDisabled(false);
            const label = days == 0 ? 'all time' : days == -1 ? 'since last boot' : days == 1 ? 'last 24 hours' : 'last ' + days + ' days';
            document.getElementById('status-bar').textContent = 'Check complete — ' + done + ' categories analyzed (' + label + ')';
            document.getElementById('note').textContent =
                'NOTE: Suggested actions are recommendations only and not guaranteed solutions. ' +
                'Review carefully before applying any changes to your system.';
        }
    };

    es.onerror = () => {
        es.close();
        btn.disabled = false;
        btn.textContent = 'RETRY';
        setPresetsDisabled(false);
        document.getElementById('status-bar').textContent = 'Connection lost — is the server still running?';
    };
}

buildGrid();
</script>
</body>
</html>
'@

    $osInfo  = Get-CimInstance Win32_OperatingSystem
    $cpuInfo = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim() -replace '\s{2,}', ' '
    $ramGb   = [math]::Round($osInfo.TotalVisibleMemorySize / 1MB, 1)
    $sysInfo = "$env:COMPUTERNAME  ·  $($osInfo.Caption)  ·  $cpuInfo  ·  $ramGb GB RAM"
    $html    = $html.Replace('{{SYSINFO}}', $sysInfo)
    $html    = $html.Replace('{{DAYS}}', $Days)

    $modelsUrl = $ApiUrl -replace '/chat/completions$', '/models'
    try {
        $models    = Invoke-RestMethod -Uri $modelsUrl -Method Get -TimeoutSec 5 -ErrorAction Stop
        $modelName = if ($models.data -and $models.data.Count -gt 0) { $models.data[0].id } else { "unknown model" }
        $llmHtml   = '<span class="dot-online">●</span> ' + [System.Net.WebUtility]::HtmlEncode($modelName)
    } catch {
        $llmHtml   = '<span class="dot-offline">●</span> LLM offline  (' + [System.Net.WebUtility]::HtmlEncode(($ApiUrl -replace '/v1/.*$', '')) + ')'
    }
    $html = $html.Replace('{{LLMINFO}}', $llmHtml)

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
    Write-Host "Web UI running at http://localhost:$Port  --  press Ctrl+C to stop" -ForegroundColor Cyan
    Start-Process "http://localhost:$Port"

    try {
        while ($true) {
            $async = $listener.BeginGetContext($null, $null)
            while (-not $async.AsyncWaitHandle.WaitOne(500)) {}
            $context = $listener.EndGetContext($async)
            $path    = $context.Request.Url.LocalPath

            if ($path -eq "/") {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
                $context.Response.ContentType     = "text/html; charset=utf-8"
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.OutputStream.Close()

            } elseif ($path -eq "/stream") {
                $context.Response.ContentType = "text/event-stream"
                $context.Response.Headers.Add("Cache-Control", "no-cache")
                $context.Response.Headers.Add("X-Accel-Buffering", "no")
                $context.Response.SendChunked = $true

                $writer          = [System.IO.StreamWriter]::new($context.Response.OutputStream, [System.Text.Encoding]::UTF8)
                $writer.AutoFlush = $true
                $writer.NewLine   = "`n"

                try {
                    $daysParam   = $context.Request.QueryString["days"]
                    $streamDays  = if ($daysParam -match '^-?\d+$') { [int]$daysParam } else { $Days }
                    $streamSince = switch ($streamDays) {
                        -1   { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
                         0   { $null }
                        default { (Get-Date).AddDays(-$streamDays) }
                    }

                    foreach ($group in $SourceGroups) {
                        $startEvt = [ordered]@{ type = "start"; category = $group.Category } | ConvertTo-Json -Compress
                        $writer.Write("data: $startEvt`n`n")

                        if ($group.Mode -eq "ids") {
                            $idsFilter = @{LogName=$group.Logs; Id=$group.Ids}
                            if ($streamSince) { $idsFilter.StartTime = $streamSince }
                            $events = Get-WinEvent -FilterHashtable $idsFilter -MaxEvents 10 -ErrorAction SilentlyContinue |
                                Where-Object { $_ -ne $null } |
                                Sort-Object TimeCreated -Descending |
                                Select-Object @{n='Severity';e={Get-SecuritySeverity $_.Id}},
                                              @{n='When';e={Get-TimeAgo $_.TimeCreated}},
                                              TimeCreated, LogName, ProviderName, Id,
                                              @{n='Message';e={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(200,$_.Message.Length))}}
                        } else {
                            $events = Get-LevelEvents $group.Logs $streamSince
                        }

                        if (-not $events) {
                            $resultEvt = [ordered]@{ type = "result"; category = $group.Category; clean = $true } | ConvertTo-Json -Compress
                        } else {
                            $analysis  = Invoke-LlmAnalysis $group.Category $events
                            $resultEvt = [ordered]@{
                                type     = "result"
                                category = $group.Category
                                clean    = $false
                                error    = [bool](-not $analysis)
                                text     = if ($analysis) { $analysis } else { "Could not reach LLM at $ApiUrl" }
                            } | ConvertTo-Json -Compress
                        }
                        $writer.Write("data: $resultEvt`n`n")
                    }
                    $writer.Write("data: {`"type`":`"done`"}`n`n")
                } catch {
                    # Client disconnected mid-stream — ignore
                }
                $context.Response.OutputStream.Close()

            } else {
                $context.Response.StatusCode = 404
                $context.Response.OutputStream.Close()
            }
        }
    } finally {
        $listener.Stop()
    }
    exit
}

# --- Main ---

Write-Host "Windows System Check" -ForegroundColor Cyan
Write-Host "====================" -ForegroundColor Cyan

foreach ($group in $SourceGroups) {
    Write-Host "`nAnalyzing $($group.Category)..." -ForegroundColor Cyan

    if ($group.Mode -eq "ids") {
        $events = Get-WinEvent -FilterHashtable @{LogName=$group.Logs; Id=$group.Ids; StartTime=$Since} -MaxEvents 10 -ErrorAction SilentlyContinue |
            Where-Object { $_ -ne $null } |
            Sort-Object TimeCreated -Descending |
            Select-Object @{n='Severity';e={Get-SecuritySeverity $_.Id}},
                          @{n='When';e={Get-TimeAgo $_.TimeCreated}},
                          TimeCreated, LogName, ProviderName, Id,
                          @{n='Message';e={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(200,$_.Message.Length))}}
    } else {
        $events = Get-LevelEvents $group.Logs $Since
    }

    if (-not $events) {
        Write-Host "  No issues found." -ForegroundColor Green
        continue
    }

    Write-Host "`n--- $($group.Category) ---`n" -ForegroundColor Green
    Invoke-LlmAnalysis $group.Category $events
}

Write-Host "`nNOTE: The suggested actions are recommendations only and not guaranteed solutions. Review each action carefully before applying any changes to your system, especially before running any commands in a CLI or modifying Windows system settings." -ForegroundColor Yellow
