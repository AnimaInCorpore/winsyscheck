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
