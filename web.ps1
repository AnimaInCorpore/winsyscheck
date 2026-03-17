function Invoke-WebMode {
    param([int]$Port, [int]$Days)

    # ── HTML preparation ────────────────────────────────────────────────────
    $html    = Get-Content "$PSScriptRoot\web-ui.html" -Raw -Encoding UTF8
    $osInfo  = Get-CimInstance Win32_OperatingSystem
    $cpuInfo = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim() -replace '\s{2,}', ' '
    $ramGb   = [math]::Round($osInfo.TotalVisibleMemorySize / 1MB, 1)
    $sysInfo = "$env:COMPUTERNAME  ·  $($osInfo.Caption)  ·  $cpuInfo  ·  $ramGb GB RAM"
    $html    = $html.Replace('{{SYSINFO}}', $sysInfo)
    $html    = $html.Replace('{{DAYS}}', $Days)

    $epoch       = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $bootTime    = $osInfo.LastBootUpTime
    $resumeEvent = try { Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Power-Troubleshooter/Operational'; Id=1} -MaxEvents 1 -ErrorAction Stop } catch { $null }
    $wakeTime    = if ($resumeEvent -and $resumeEvent.TimeCreated -gt $bootTime) { $resumeEvent.TimeCreated } else { $bootTime }
    $bootMs      = [long]($bootTime.ToUniversalTime() - $epoch).TotalMilliseconds
    $wakeMs      = [long]($wakeTime.ToUniversalTime() - $epoch).TotalMilliseconds
    $html        = $html.Replace('{{BOOTTIME_MS}}', $bootMs)
    $html        = $html.Replace('{{WAKETIME_MS}}', $wakeMs)

    $modelsUrl = $ApiUrl -replace '/chat/completions$', '/models'
    try {
        $models    = Invoke-RestMethod -Uri $modelsUrl -Method Get -TimeoutSec 5 -ErrorAction Stop
        $modelName = if ($models.data -and $models.data.Count -gt 0) { $models.data[0].id } else { "unknown model" }
        $llmHtml   = '<span class="dot-online">●</span> ' + [System.Net.WebUtility]::HtmlEncode($modelName)
    } catch {
        $llmHtml   = '<span class="dot-offline">●</span> LLM offline  (' + [System.Net.WebUtility]::HtmlEncode(($ApiUrl -replace '/v1/.*$', '')) + ')'
    }
    $html = $html.Replace('{{LLMINFO}}', $llmHtml)

    # ── Source scripts loaded once, injected into every runspace ───────────
    $helpersSrc = Get-Content "$PSScriptRoot\helpers.ps1" -Raw -Encoding UTF8
    $eventsSrc  = Get-Content "$PSScriptRoot\events.ps1"  -Raw -Encoding UTF8
    $llmSrc     = Get-Content "$PSScriptRoot\llm.ps1"     -Raw -Encoding UTF8

    # ── HTTP listener ───────────────────────────────────────────────────────
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
    Write-Host "Web UI running at http://localhost:$Port  --  press Ctrl+C to stop" -ForegroundColor Cyan
    Start-Process "http://localhost:$Port"

    # ── Runspace pool (up to 8 concurrent requests) ─────────────────────────
    $rsPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 8)
    $rsPool.Open()

    $jobs = [System.Collections.Generic.List[hashtable]]::new()

    # ── Per-request handler (runs inside a runspace) ────────────────────────
    $handlerScript = {
        param($ctx, $html, $apiUrl, $sourceGroups, $days, $helpersSrc, $eventsSrc, $llmSrc)

        # Populate module-level variable expected by LLM functions
        $ApiUrl = $apiUrl
        . ([scriptblock]::Create($helpersSrc))
        . ([scriptblock]::Create($eventsSrc))
        . ([scriptblock]::Create($llmSrc))

        $path = $ctx.Request.Url.LocalPath

        if ($path -eq "/") {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
            $ctx.Response.ContentType     = "text/html; charset=utf-8"
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.OutputStream.Close()

        } elseif ($path -eq "/stream") {
            $ctx.Response.ContentType = "text/event-stream"
            $ctx.Response.Headers.Add("Cache-Control", "no-cache")
            $ctx.Response.Headers.Add("X-Accel-Buffering", "no")
            $ctx.Response.SendChunked = $true

            $writer           = [System.IO.StreamWriter]::new($ctx.Response.OutputStream, [System.Text.Encoding]::UTF8)
            $writer.AutoFlush = $true
            $writer.NewLine   = "`n"

            try {
                $daysParam   = $ctx.Request.QueryString["days"]
                $streamDays  = if ($daysParam -match '^-?\d+$') { [int]$daysParam } else { $days }
                $streamSince = switch ($streamDays) {
                    -2 {
                        $bt = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
                        $re = try { Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Power-Troubleshooter/Operational'; Id=1} -MaxEvents 1 -ErrorAction Stop } catch { $null }
                        if ($re -and $re.TimeCreated -gt $bt) { $re.TimeCreated } else { $bt }
                    }
                    -1      { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
                     0      { $null }
                    default { (Get-Date).AddDays(-$streamDays) }
                }

                $catFilter = $ctx.Request.QueryString["category"]
                $groups    = if ($catFilter) { @($sourceGroups | Where-Object { $_.Category -eq $catFilter }) } else { $sourceGroups }

                foreach ($group in $groups) {
                    $startEvt = [ordered]@{ type = "start"; category = $group.Category } | ConvertTo-Json -Compress
                    $writer.Write("data: $startEvt`n`n")

                    $events = Get-GroupEvents $group $streamSince

                    if (-not $events) {
                        $resultEvt = [ordered]@{ type = "result"; category = $group.Category; clean = $true } | ConvertTo-Json -Compress
                    } else {
                        $analysis  = Invoke-LlmAnalysis $group.Category $events
                        $resultEvt = [ordered]@{
                            type     = "result"
                            category = $group.Category
                            clean    = $false
                            error    = [bool](-not $analysis)
                            text     = if ($analysis) { $analysis } else { "Could not reach LLM at $apiUrl" }
                        } | ConvertTo-Json -Compress
                    }
                    $writer.Write("data: $resultEvt`n`n")
                }
                $writer.Write("data: {`"type`":`"done`"}`n`n")
            } catch {
                # Client disconnected mid-stream — ignore
            }
            $ctx.Response.OutputStream.Close()

        } elseif ($path -eq "/ask" -and $ctx.Request.HttpMethod -eq "POST") {
            try {
                $body   = [System.IO.StreamReader]::new($ctx.Request.InputStream, [System.Text.Encoding]::UTF8).ReadToEnd()
                $data   = $body | ConvertFrom-Json
                $answer = Invoke-LlmExplain $data.issue $data.question
                $json   = @{ text = $answer } | ConvertTo-Json -Compress
            } catch {
                $json = '{"text":"Sorry, something went wrong while processing your question."}'
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $ctx.Response.ContentType     = "application/json; charset=utf-8"
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.OutputStream.Close()

        } else {
            $ctx.Response.StatusCode = 404
            $ctx.Response.OutputStream.Close()
        }
    }

    # ── Accept loop ─────────────────────────────────────────────────────────
    try {
        while ($true) {
            $async = $listener.BeginGetContext($null, $null)

            # While waiting for the next connection, reap any completed jobs
            while (-not $async.AsyncWaitHandle.WaitOne(500)) {
                $completed = @($jobs | Where-Object { $_.handle.IsCompleted })
                foreach ($j in $completed) {
                    try { [void]$j.ps.EndInvoke($j.handle) } catch {}
                    $j.ps.Dispose()
                    $jobs.Remove($j)
                }
            }
            $context = $listener.EndGetContext($async)

            # Reap again right before dispatching
            $completed = @($jobs | Where-Object { $_.handle.IsCompleted })
            foreach ($j in $completed) {
                try { [void]$j.ps.EndInvoke($j.handle) } catch {}
                $j.ps.Dispose()
                $jobs.Remove($j)
            }

            # Dispatch request to a runspace
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $rsPool
            [void]$ps.AddScript($handlerScript).AddParameters(@{
                ctx          = $context
                html         = $html
                apiUrl       = $ApiUrl
                sourceGroups = $SourceGroups
                days         = $Days
                helpersSrc   = $helpersSrc
                eventsSrc    = $eventsSrc
                llmSrc       = $llmSrc
            })
            $handle = $ps.BeginInvoke()
            $jobs.Add(@{ ps = $ps; handle = $handle })
        }
    } finally {
        foreach ($j in $jobs) {
            try { [void]$j.ps.EndInvoke($j.handle) } catch {}
            $j.ps.Dispose()
        }
        $rsPool.Close()
        $rsPool.Dispose()
        $listener.Stop()
    }
}
