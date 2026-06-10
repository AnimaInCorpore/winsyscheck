#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Web,
    [switch]$NoBrowser,
    [string]$ApiUrl = "",
    [ValidateRange(1, 65535)]
    [int]$Port = 8888,
    [ValidateRange(0, 3650)]
    [int]$Days = 7
)

$ApiUrlOverride = $ApiUrl

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\events.ps1"
. "$PSScriptRoot\llm.ps1"
. "$PSScriptRoot\web.ps1"

if ($ApiUrlOverride.Trim()) {
    $ApiUrl = $ApiUrlOverride.Trim()
}

if (-not (Test-IsWindows)) {
    Write-Host "winsyscheck requires Windows because it reads Windows Event Logs." -ForegroundColor Red
    exit 1
}

if (-not (Test-IsAdministrator)) {
    Write-Host "Warning: run as Administrator for complete access to all event logs, especially Security." -ForegroundColor Yellow
}

$llmStatus = Get-LlmStatus

if ($Web) {
    Invoke-WebMode -Port $Port -Days $Days -OpenBrowser:(-not $NoBrowser) -LlmStatus $llmStatus
    exit
}

if (-not $llmStatus.Online) {
    Write-Host "Could not reach the local LLM server." -ForegroundColor Red
    Write-Host "Endpoint: $ApiUrl" -ForegroundColor Yellow
    Write-Host "Start your OpenAI-compatible server, or pass -ApiUrl to use another endpoint." -ForegroundColor Yellow
    exit 1
}

# --- Console mode ---

$Since = if ($Days -eq 0) { $null } else { (Get-Date).AddDays(-$Days) }
$rangeLabel = if ($Days -eq 0) { "all events" } elseif ($Days -eq 1) { "last 24 hours" } else { "last $Days days" }
$categoriesChecked = 0
$eventGroupsFound = 0
$llmFailures = 0

Write-Host "Windows System Check" -ForegroundColor Cyan
Write-Host "====================" -ForegroundColor Cyan
Write-Host "Range: $rangeLabel"
Write-Host "LLM:   $($llmStatus.Model) ($ApiUrl)"

foreach ($group in $SourceGroups) {
    Write-Host "`nAnalyzing $($group.Category)..." -ForegroundColor Cyan

    $categoriesChecked++
    $events = @(Get-GroupEvents $group $Since)
    $eventGroupsFound += $events.Count

    if ($events.Count -eq 0) {
        Write-Host "  No issues found." -ForegroundColor Green
        continue
    }

    $results = New-Object 'System.Collections.Generic.List[string]'
    $groupFailures = 0
    for ($i = 0; $i -lt $events.Count; $i++) {
        Write-Host "  Analyzing event group $($i + 1)/$($events.Count)..."
        $analysis = Invoke-LlmAnalysis $group.Category @($events[$i])
        if ([string]::IsNullOrWhiteSpace($analysis)) {
            $llmFailures++
            $groupFailures++
        } elseif (-not (Test-LlmNoIssues $analysis)) {
            [void]$results.Add($analysis.Trim())
        }
    }

    if ($results.Count -eq 0 -and $groupFailures -gt 0) {
        Write-Host "  LLM failed while analyzing this category." -ForegroundColor Red
    } elseif ($results.Count -eq 0) {
        Write-Host "  No significant issues found." -ForegroundColor Green
    } else {
        Write-Host "`n--- $($group.Category) ---`n" -ForegroundColor Green
        $results -join "`n`n"
    }
}

Write-Host "`nSummary" -ForegroundColor Cyan
Write-Host "  Categories checked: $categoriesChecked"
Write-Host "  Event groups sent to LLM: $eventGroupsFound"
if ($llmFailures -gt 0) {
    Write-Host "  LLM failures: $llmFailures" -ForegroundColor Red
}

Write-Host "`nNOTE: The suggested actions are recommendations only and not guaranteed solutions. Review each action carefully before applying any changes to your system, especially before running any commands in a CLI or modifying Windows system settings." -ForegroundColor Yellow
