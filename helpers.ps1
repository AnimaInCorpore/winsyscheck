function Test-IsWindows {
    [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Test-IsAdministrator {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $false
    }
}

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

function Get-SystemStabilitySeverity($id) {
    switch ($id) {
        41 { "CRITICAL" }                                # Unexpected reboot / power loss
        1001 { "CRITICAL" }                              # BugCheck / crash dump
        { $_ -in 6008, 7000, 7001, 7009, 7011, 7031, 7034 } { "HIGH" } # Unexpected shutdowns and service failures
        default { "LOW" }
    }
}

function Get-SeverityRank($severity) {
    switch ($severity) {
        "CRITICAL" { 0 }
        "HIGH"     { 1 }
        "MEDIUM"   { 2 }
        default    { 3 }
    }
}

function Get-EventMessageText($eventRecord) {
    try {
        $message = $eventRecord.FormatDescription()
    } catch {
        try {
            $message = $eventRecord.Message
        } catch {
            $message = ""
        }
    }

    if ([string]::IsNullOrWhiteSpace($message)) {
        try {
            $values = @($eventRecord.Properties | ForEach-Object { $_.Value } | Where-Object { $_ -ne $null -and "$_".Trim() })
            if ($values.Count -gt 0) {
                $message = "Event data: " + ($values -join " | ")
            }
        } catch {
            $message = ""
        }
    }

    if ([string]::IsNullOrWhiteSpace($message)) {
        return "(no message)"
    }

    $message.Trim()
}

function Get-EventMessagePreview($eventRecord) {
    Get-EventMessageText $eventRecord
}

function Get-EventMessageSignature($message) {
    $signature = [string]$message
    $signature = $signature -replace '\r\n?', "`n"
    $signature = $signature -replace '\b\d{4}-\d{2}-\d{2}[tT ][0-9:.+-zZ]+\b', '<datetime>'
    $signature = $signature -replace '\b\d{1,2}/\d{1,2}/\d{2,4}\s+\d{1,2}:\d{2}(:\d{2})?(\s*[AP]M)?\b', '<datetime>'
    $signature = $signature -replace '\b\d{1,2}\.\d{1,2}\.\d{2,4}\s+\d{1,2}:\d{2}(:\d{2})?\b', '<datetime>'
    $signature = $signature -replace '\b\d{1,2}:\d{2}(:\d{2})?(\.\d+)?\b', '<time>'
    $signature = $signature -replace '\s+', ' '
    $signature.Trim().ToLowerInvariant()
}

function Convert-EventRecordsToSummaries {
    param(
        [object[]]$Records,
        [scriptblock]$SeverityScript,
        [int]$MaxGroups = 30,
        [bool]$CollapseSimilar = $true
    )

    $buckets = @{}

    foreach ($record in @($Records)) {
        if (-not $record) { continue }

        $severity = & $SeverityScript $record
        $message = Get-EventMessageText $record
        $signature = Get-EventMessageSignature $message
        $key = if ($CollapseSimilar) {
            "$($record.LogName)|$($record.ProviderName)|$($record.Id)|$severity"
        } else {
            "$($record.LogName)|$($record.ProviderName)|$($record.Id)|$severity|$signature"
        }

        if (-not $buckets.ContainsKey($key)) {
            $buckets[$key] = [pscustomobject][ordered]@{
                Severity     = $severity
                Count        = 0
                VariantCount = 0
                FirstSeen    = $record.TimeCreated
                LastSeen     = $record.TimeCreated
                LogName      = $record.LogName
                ProviderName = $record.ProviderName
                Id           = $record.Id
                Message      = $message
                Signatures   = New-Object 'System.Collections.Generic.HashSet[string]'
            }
        }

        $bucket = $buckets[$key]
        $bucket.Count++
        if ($bucket.Signatures.Add($signature)) {
            $bucket.VariantCount = $bucket.Signatures.Count
        }

        if ($record.TimeCreated -lt $bucket.FirstSeen) { $bucket.FirstSeen = $record.TimeCreated }
        if ($record.TimeCreated -gt $bucket.LastSeen) {
            $bucket.LastSeen = $record.TimeCreated
            $bucket.Message = $message
        }
    }

    $buckets.Values |
        Sort-Object @{Expression={Get-SeverityRank $_.Severity}; Ascending=$true}, @{Expression={$_.LastSeen}; Descending=$true} |
        Select-Object -First $MaxGroups |
        ForEach-Object {
            [pscustomobject][ordered]@{
                Severity     = $_.Severity
                Count        = $_.Count
                VariantCount = $_.VariantCount
                When         = Get-TimeAgo $_.LastSeen
                TimeCreated  = $_.LastSeen
                FirstSeen    = $_.FirstSeen
                LastSeen     = $_.LastSeen
                LogName      = $_.LogName
                ProviderName = $_.ProviderName
                Id           = $_.Id
                Message      = $_.Message
            }
        }
}

function Format-EventDate($dt) {
    if ($dt) { $dt.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
}

function Format-EventsForLlm($events) {
    $lines = New-Object 'System.Collections.Generic.List[string]'

    foreach ($event in @($events)) {
        [void]$lines.Add("Severity: $($event.Severity)")
        [void]$lines.Add("Count: $($event.Count)")
        [void]$lines.Add("CollapsedRepeatedEvents: $([bool]($event.Count -gt 1))")
        [void]$lines.Add("CollapsedMessageVariants: $($event.VariantCount)")
        [void]$lines.Add("FirstSeen: $(Format-EventDate $event.FirstSeen)")
        [void]$lines.Add("LastSeen: $(Format-EventDate $event.LastSeen) ($($event.When))")
        [void]$lines.Add("Source: $($event.LogName) / $($event.ProviderName) (Event ID: $($event.Id))")
        [void]$lines.Add("Message:")
        foreach ($line in ([string]$event.Message -split "`r?`n")) {
            [void]$lines.Add("  $line")
        }
        [void]$lines.Add("")
    }

    $lines -join "`n"
}

function Get-LevelEvents($logs, $startTime, $excludeIds) {
    $records = foreach ($level in 1..3) {
        $filter = @{LogName=$logs; Level=$level}
        if ($startTime) { $filter.StartTime = $startTime }

        Get-WinEvent -FilterHashtable $filter -MaxEvents 150 -ErrorAction SilentlyContinue |
            Where-Object { -not $startTime -or $_.TimeCreated -ge $startTime } |
            Where-Object { -not $excludeIds -or $_.Id -notin $excludeIds } |
            Where-Object { $_ -ne $null }
    }

    Convert-EventRecordsToSummaries -Records @($records) -SeverityScript { param($record) Get-LevelSeverity $record.Level } -CollapseSimilar $true
}
