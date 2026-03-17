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

function Get-LevelEvents($logs) {
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    1..3 | ForEach-Object {
        Get-WinEvent -FilterHashtable @{LogName=$logs; Level=$_} -ErrorAction SilentlyContinue |
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

# --- Main ---

Write-Host "Windows System Check" -ForegroundColor Cyan
Write-Host "====================" -ForegroundColor Cyan

foreach ($group in $SourceGroups) {
    Write-Host "`nAnalyzing $($group.Category)..." -ForegroundColor Cyan

    if ($group.Mode -eq "ids") {
        $events = Get-WinEvent -FilterHashtable @{LogName=$group.Logs; Id=$group.Ids} -MaxEvents 10 -ErrorAction SilentlyContinue |
            Where-Object { $_ -ne $null } |
            Sort-Object TimeCreated -Descending |
            Select-Object @{n='Severity';e={Get-SecuritySeverity $_.Id}},
                          @{n='When';e={Get-TimeAgo $_.TimeCreated}},
                          TimeCreated, LogName, ProviderName, Id,
                          @{n='Message';e={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(200,$_.Message.Length))}}
    } else {
        $events = Get-LevelEvents $group.Logs
    }

    if (-not $events) {
        Write-Host "  No issues found." -ForegroundColor Green
        continue
    }

    Write-Host "`n--- $($group.Category) ---`n" -ForegroundColor Green
    Invoke-LlmAnalysis $group.Category $events
}

Write-Host "`nNOTE: The suggested actions are recommendations only and not guaranteed solutions. Review each action carefully before applying any changes to your system, especially before running any commands in a CLI or modifying Windows system settings." -ForegroundColor Yellow
