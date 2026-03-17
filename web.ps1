function Invoke-WebMode {
    param([int]$Port, [int]$Days)

    $html = Get-Content "$PSScriptRoot\web-ui.html" -Raw -Encoding UTF8

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

                $writer           = [System.IO.StreamWriter]::new($context.Response.OutputStream, [System.Text.Encoding]::UTF8)
                $writer.AutoFlush = $true
                $writer.NewLine   = "`n"

                try {
                    $daysParam   = $context.Request.QueryString["days"]
                    $streamDays  = if ($daysParam -match '^-?\d+$') { [int]$daysParam } else { $Days }
                    $streamSince = switch ($streamDays) {
                        -2      {
                            $bootTime    = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
                            $resumeEvent = try { Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Power-Troubleshooter/Operational'; Id=1} -MaxEvents 1 -ErrorAction Stop } catch { $null }
                            if ($resumeEvent -and $resumeEvent.TimeCreated -gt $bootTime) { $resumeEvent.TimeCreated } else { $bootTime }
                        }
                        -1      { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
                         0      { $null }
                        default { (Get-Date).AddDays(-$streamDays) }
                    }

                    foreach ($group in $SourceGroups) {
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
}
