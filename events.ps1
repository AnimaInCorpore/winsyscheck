function Get-GroupEvents($group, $since) {
    if ($group.Mode -eq "ids") {
        $filter = @{LogName=$group.Logs; Id=$group.Ids}
        if ($since) { $filter.StartTime = $since }
        Get-WinEvent -FilterHashtable $filter -MaxEvents 10 -ErrorAction SilentlyContinue |
            Where-Object { $_ -ne $null } |
            Sort-Object TimeCreated -Descending |
            Select-Object @{n='Severity';e={Get-SecuritySeverity $_.Id}},
                          @{n='When';e={Get-TimeAgo $_.TimeCreated}},
                          TimeCreated, LogName, ProviderName, Id,
                          @{n='Message';e={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(200,$_.Message.Length))}}
    } else {
        Get-LevelEvents $group.Logs $since
    }
}
