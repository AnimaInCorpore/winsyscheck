# winsyscheck

A PowerShell script that reads Windows event logs, sends them to a local LLM, and produces a structured, prioritized report of system issues with suggested actions.

## Requirements

- Windows 10/11
- PowerShell 5.1 or later
- A locally running LLM server compatible with the OpenAI chat completions API, e.g.:
  - [LM Studio](https://lmstudio.ai) (default port 1234)
  - [Ollama](https://ollama.com) (default port 11434)
  - Any OpenAI-compatible server (default port 8080)

## Usage

```powershell
.\winsyscheck.ps1
```

> Run as Administrator to ensure access to all event logs, including the Security log.

## Configuration

At the top of the script, update `$ApiUrl` to match your local LLM server:

```powershell
$ApiUrl = "http://localhost:8080/v1/chat/completions"
```

| Server     | Default port |
|------------|-------------|
| LM Studio  | 1234        |
| Ollama     | 11434       |
| Other      | 8080        |

## What it checks

The script queries the following event log categories in order of importance:

| # | Category | What it covers |
|---|----------|---------------|
| 1 | Security | Logon failures, account lockouts, privilege escalation, account changes |
| 2 | Hardware & Power | Unexpected shutdowns, power loss, disk and filesystem errors |
| 3 | Core OS | System and application errors and warnings |
| 4 | Drivers | Device and driver framework failures |
| 5 | Network | Network profile changes, DNS client errors |
| 6 | Performance | Slow boot/shutdown, WMI instability |
| 7 | Antivirus & Defense | Windows Defender alerts and failures |
| 8 | Updates & Tasks | Windows Update, BITS transfer, and scheduled task failures |

## Report format

Each issue is reported in a consistent format:

```
Event:       <short event name>
Severity:    <CRITICAL | HIGH | MEDIUM | LOW>
Date:        <date and time> (<time ago>)
Source:      <log name> / <provider name> (Event ID: <id>)
Description: <one sentence explaining what happened>
Action:      <one sentence describing the fix or next step>
```

Issues are sorted by severity (CRITICAL first) within each category.

## Disclaimer

The suggested actions are recommendations only and not guaranteed solutions. Review each action carefully before applying any changes to your system, especially before running commands in a CLI or modifying Windows system settings.
