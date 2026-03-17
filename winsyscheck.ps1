param(
    [switch]$Web,
    [int]$Port = 8888,
    [int]$Days = 7
)

. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\helpers.ps1"
. "$PSScriptRoot\events.ps1"
. "$PSScriptRoot\llm.ps1"
. "$PSScriptRoot\web.ps1"

if ($Web) { Invoke-WebMode -Port $Port -Days $Days; exit }

# --- Console mode ---

$Since = (Get-Date).AddDays(-$Days)

Write-Host "Windows System Check" -ForegroundColor Cyan
Write-Host "====================" -ForegroundColor Cyan

foreach ($group in $SourceGroups) {
    Write-Host "`nAnalyzing $($group.Category)..." -ForegroundColor Cyan

    $events = Get-GroupEvents $group $Since

    if (-not $events) {
        Write-Host "  No issues found." -ForegroundColor Green
        continue
    }

    Write-Host "`n--- $($group.Category) ---`n" -ForegroundColor Green
    Invoke-LlmAnalysis $group.Category $events
}

Write-Host "`nNOTE: The suggested actions are recommendations only and not guaranteed solutions. Review each action carefully before applying any changes to your system, especially before running any commands in a CLI or modifying Windows system settings." -ForegroundColor Yellow
