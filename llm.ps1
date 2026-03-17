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
            @{ role = "system"; content = "You are a Windows system log analyst. Output ONLY structured issue blocks — no introduction, no summary, no extra text before or after.`n`nFor each issue use EXACTLY this format (all 6 fields, in this order, at column 0):`n`nEvent:       <short event name>`nSeverity:    <CRITICAL | HIGH | MEDIUM | LOW>`nDate:        <date and time> (<time ago>)`nSource:      <log name> / <provider name> (Event ID: <id>)`nDescription: <one sentence explaining what happened>`nAction:      <one sentence describing the fix or next step>`n`nSeparate issues with a single blank line. Sort by severity (CRITICAL first). Never skip a field. If there are no significant issues, output exactly: No issues found." },
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

function Invoke-LlmExplain($issueText, $question) {
    $userMessage = @"
Here is a Windows system issue that was detected on my computer:

$issueText

Question: $question
"@
    $payload = @{
        model    = "local-model"
        messages = @(
            @{ role = "system"; content = "You are a friendly assistant answering questions about Windows computer issues for a non-technical home user. Rules: use plain everyday language with no technical jargon; answer only the question asked, nothing more; keep your answer short (2-4 sentences or a bullet list of 3-5 items); do not use markdown headers or code blocks; be honest and reassuring where appropriate." },
            @{ role = "user";   content = $userMessage }
        )
        temperature = 0.4
    } | ConvertTo-Json -Depth 5

    try {
        $response = Invoke-RestMethod -Uri $ApiUrl -Method Post -Body $payload -ContentType "application/json" -TimeoutSec 300
        $response.choices[0].message.content
    } catch {
        Write-Host "  Failed to reach LLM for explain: $_" -ForegroundColor Red
        "Sorry, the AI assistant could not be reached right now. Please try again."
    }
}
