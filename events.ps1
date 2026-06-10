function Get-GroupEvents($group, $since) {
    if ($group.Mode -eq "ids") {
        $records = foreach ($id in $group.Ids) {
            $filter = @{LogName=$group.Logs; Id=$id}
            if ($since) { $filter.StartTime = $since }

            Get-WinEvent -FilterHashtable $filter -MaxEvents 50 -ErrorAction SilentlyContinue |
                Where-Object { -not $since -or $_.TimeCreated -ge $since } |
                Where-Object { $_ -ne $null }
        }

        $severityScript = { param($record) Get-LevelSeverity $record.Level }
        if ($group.Category -eq "Security") {
            $severityScript = { param($record) Get-SecuritySeverity $record.Id }
        } elseif ($group.Category -eq "Crashes & Services") {
            $severityScript = { param($record) Get-SystemStabilitySeverity $record.Id }
        }

        Convert-EventRecordsToSummaries -Records @($records) -SeverityScript $severityScript -CollapseSimilar $false
    } else {
        Get-LevelEvents $group.Logs $since $group.ExcludeIds
    }
}
