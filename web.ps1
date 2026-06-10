function Invoke-WebMode {
    param(
        [int]$Port,
        [int]$Days,
        [bool]$OpenBrowser = $true,
        [hashtable]$LlmStatus = $null
    )

    # HTML preparation
    $html    = Get-Content "$PSScriptRoot\web-ui.html" -Raw -Encoding UTF8
    $osInfo  = Get-CimInstance Win32_OperatingSystem
    $cpuInfo = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim() -replace '\s{2,}', ' '
    $ramGb   = [math]::Round($osInfo.TotalVisibleMemorySize / 1MB, 1)
    $sysInfo = "$env:COMPUTERNAME | $($osInfo.Caption) | $cpuInfo | $ramGb GB RAM"
    $html    = $html.Replace('{{SYSINFO}}', $sysInfo)
    $html    = $html.Replace('{{DAYS}}', $Days)

    $epoch       = New-Object DateTime -ArgumentList @(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $bootTime    = $osInfo.LastBootUpTime
    $resumeEvent = try { Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Power-Troubleshooter/Operational'; Id=1} -MaxEvents 1 -ErrorAction Stop } catch { $null }
    $wakeTime    = if ($resumeEvent -and $resumeEvent.TimeCreated -gt $bootTime) { $resumeEvent.TimeCreated } else { $bootTime }
    $bootMs      = [long]($bootTime.ToUniversalTime() - $epoch).TotalMilliseconds
    $wakeMs      = [long]($wakeTime.ToUniversalTime() - $epoch).TotalMilliseconds
    $html        = $html.Replace('{{BOOTTIME_MS}}', $bootMs)
    $html        = $html.Replace('{{WAKETIME_MS}}', $wakeMs)

    if (-not $LlmStatus) {
        $LlmStatus = Get-LlmStatus
    }
    if ($LlmStatus.Online) {
        $llmHtml = '<span class="status-dot online"></span>' + [System.Net.WebUtility]::HtmlEncode($LlmStatus.Model)
        $llmReady = 'true'
    } else {
        $llmHtml = '<span class="status-dot offline"></span>LLM offline (' + [System.Net.WebUtility]::HtmlEncode(($ApiUrl -replace '/v1/.*$', '')) + ')'
        $llmReady = 'false'
    }
    $html = $html.Replace('{{LLMINFO}}', $llmHtml)
    $html = $html.Replace('{{LLM_READY}}', $llmReady)

    # Source scripts loaded once, injected into every runspace
    $helpersSrc = Get-Content "$PSScriptRoot\helpers.ps1" -Raw -Encoding UTF8
    $eventsSrc  = Get-Content "$PSScriptRoot\events.ps1"  -Raw -Encoding UTF8
    $llmSrc     = Get-Content "$PSScriptRoot\llm.ps1"     -Raw -Encoding UTF8

    # HTTP listener
    $listener = New-Object System.Net.HttpListener
    try {
        $listener.Prefixes.Add("http://localhost:$Port/")
        $listener.Start()
    } catch {
        Write-Host "Could not start the web UI on http://localhost:$Port" -ForegroundColor Red
        Write-Host "The port may already be in use, or HttpListener may not have permission to bind it." -ForegroundColor Yellow
        Write-Host "Try another port, for example: .\winsyscheck.ps1 -Web -Port 9000" -ForegroundColor Yellow
        $listener.Close()
        return
    }

    Write-Host "Web UI running at http://localhost:$Port  --  press Ctrl+C to stop" -ForegroundColor Cyan
    if ($OpenBrowser) {
        Start-Process "http://localhost:$Port"
    }

    # Runspace pool (up to 8 concurrent requests)
    $rsPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 8)
    $rsPool.Open()

    $jobs = New-Object 'System.Collections.Generic.List[hashtable]'

    # Per-request handler (runs inside a runspace)
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

            $writer           = New-Object System.IO.StreamWriter -ArgumentList @($ctx.Response.OutputStream, [System.Text.Encoding]::UTF8)
            $writer.AutoFlush = $true
            $writer.NewLine   = "`n"

            try {
                $daysParam   = $ctx.Request.QueryString["days"]
                $streamDays  = if ($daysParam -match '^-?\d+$') { [int]$daysParam } else { $days }
                if ($streamDays -lt 0 -and @(-2, -1) -notcontains $streamDays) {
                    $streamDays = $days
                }
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

                    $events = @(Get-GroupEvents $group $streamSince)

                    if ($events.Count -eq 0) {
                        $resultEvt = [ordered]@{ type = "result"; category = $group.Category; clean = $true; final = $true } | ConvertTo-Json -Compress
                        $writer.Write("data: $resultEvt`n`n")
                    } else {
                        $results = New-Object 'System.Collections.Generic.List[string]'
                        $processed = New-Object 'System.Collections.Generic.List[object]'
                        $failed = $false

                        for ($i = 0; $i -lt $events.Count; $i++) {
                            $progressEvt = [ordered]@{
                                type     = "progress"
                                category = $group.Category
                                current  = $i + 1
                                total    = $events.Count
                            } | ConvertTo-Json -Compress
                            $writer.Write("data: $progressEvt`n`n")

                            [void]$processed.Add($events[$i])
                            $analysis = Invoke-LlmAnalysis $group.Category @($events[$i])
                            if ([string]::IsNullOrWhiteSpace($analysis)) {
                                $resultEvt = [ordered]@{
                                    type     = "result"
                                    category = $group.Category
                                    clean    = $false
                                    error    = $true
                                    final    = $true
                                    text     = "Could not reach LLM at $apiUrl"
                                    raw      = Format-EventsForLlm ($processed.ToArray())
                                } | ConvertTo-Json -Compress
                                $writer.Write("data: $resultEvt`n`n")
                                $failed = $true
                                break
                            }

                            if (-not (Test-LlmNoIssues $analysis)) {
                                [void]$results.Add($analysis.Trim())
                                if ($i -lt ($events.Count - 1)) {
                                    $resultEvt = [ordered]@{
                                        type     = "result"
                                        category = $group.Category
                                        clean    = $false
                                        error    = $false
                                        final    = $false
                                        text     = $results -join "`n`n"
                                        raw      = Format-EventsForLlm ($processed.ToArray())
                                    } | ConvertTo-Json -Compress
                                    $writer.Write("data: $resultEvt`n`n")
                                }
                            }
                        }

                        if (-not $failed) {
                            if ($results.Count -eq 0) {
                                $resultEvt = [ordered]@{ type = "result"; category = $group.Category; clean = $true; final = $true } | ConvertTo-Json -Compress
                            } else {
                                $resultEvt = [ordered]@{
                                    type     = "result"
                                    category = $group.Category
                                    clean    = $false
                                    error    = $false
                                    final    = $true
                                    text     = $results -join "`n`n"
                                    raw      = Format-EventsForLlm ($processed.ToArray())
                                } | ConvertTo-Json -Compress
                            }
                            $writer.Write("data: $resultEvt`n`n")
                        }
                    }
                }
                $writer.Write("data: {`"type`":`"done`"}`n`n")
            } catch {
                # Client disconnected mid-stream; ignore.
            }
            $ctx.Response.OutputStream.Close()

        } elseif ($path -eq "/ask" -and $ctx.Request.HttpMethod -eq "POST") {
            try {
                $reader = New-Object System.IO.StreamReader -ArgumentList @($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
                $body   = $reader.ReadToEnd()
                $data   = $body | ConvertFrom-Json
                $persona = if ($data.PSObject.Properties['persona']) { $data.persona } else { $null }
                $answer = Invoke-LlmExplain $data.issue $data.question $persona
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

    # Accept loop
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
        if ($listener.IsListening) {
            $listener.Stop()
        }
        $listener.Close()
    }
}
