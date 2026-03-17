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
            Where-Object { -not $startTime -or $_.TimeCreated -ge $startTime } |
            Where-Object { $key = "$($_.ProviderName)-$($_.Id)"; $isNew = $seen.Add($key); $isNew } |
            Select-Object -First 5
    } | Where-Object { $_ -ne $null } |
        Sort-Object TimeCreated -Descending |
        Select-Object @{n='Severity';e={Get-LevelSeverity $_.Level}},
                      @{n='When';e={Get-TimeAgo $_.TimeCreated}},
                      TimeCreated, LogName, ProviderName, Id,
                      @{n='Message';e={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(200,$_.Message.Length))}}
}
