# winsyscheck

A PowerShell tool that reads Windows event logs, sends them to a local LLM, and produces a structured, prioritized report of system issues with suggested actions.

## Requirements

- Windows 10/11
- PowerShell 5.1 or later
- A local LLM server with an OpenAI-compatible API (e.g. [llama.cpp](https://github.com/ggml-org/llama.cpp), LM Studio, Ollama)

## Usage

**CLI mode** — prints a structured report to the terminal:

```powershell
.\winsyscheck.ps1
```

**Web UI mode** — serves a browser-based dashboard (default port: 8888):

```powershell
.\winsyscheck.ps1 -Web
```

The browser opens automatically. Select a time range, press **START CHECK**, and results appear category by category as each LLM response arrives.

**Optional parameters:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Web`    | off     | Launch the web UI instead of CLI output |
| `-Port`   | 8888    | Web UI port |
| `-Days`   | 7       | How many days back to look (CLI mode) |

```powershell
.\winsyscheck.ps1 -Web -Port 9000
.\winsyscheck.ps1 -Days 1
```

> Run as Administrator to ensure access to all event logs, including the Security log.

## Setup: LLM server

Start any OpenAI-compatible local server, for example llama.cpp:

```bash
llama-server -m your-model.gguf --port 8080
```

The script connects to `http://localhost:8080/v1/chat/completions` by default.
For best results use an instruction-tuned model (e.g. Mistral, Llama 3, Qwen).

## Configuration

Edit `config.ps1` to change the API endpoint or customize the event source groups:

```powershell
$ApiUrl = "http://localhost:8080/v1/chat/completions"
```

Common server ports:

| Server    | Default port |
|-----------|-------------|
| llama.cpp | 8080        |
| LM Studio | 1234        |
| Ollama    | 11434       |

## What it checks

| # | Category | What it covers |
|---|----------|---------------|
| 1 | Security | Logon failures, account lockouts, privilege escalation, account changes |
| 2 | Hardware & Power | Unexpected shutdowns, power loss, disk and filesystem errors |
| 3 | Core OS | System and application errors and warnings |
| 4 | Network | Network profile changes, DNS client errors |
| 5 | Performance | Slow boot/shutdown, WMI instability |
| 6 | Antivirus & Defense | Windows Defender alerts and failures |
| 7 | Updates & Tasks | Windows Update, BITS transfer, and scheduled task failures |

## Web UI

The web interface requires no additional tools — served directly by the script using .NET's built-in `HttpListener`.

### Header

Shows the machine name, OS, CPU, RAM, and the name of the currently loaded LLM model (or an offline indicator if the server is unreachable).

### Disclaimer

On first load a modal requires acknowledgment before the UI becomes interactive, reminding the user that all suggestions are AI-generated recommendations and should be verified before acting on them.

### Time range

The dropdown controls which events are included in the analysis:

| Option | Events included |
|--------|----------------|
| since wake | Since the last resume from sleep/hibernate (falls back to boot time) |
| since boot | Since the last full boot or restart |
| 24 hours | Rolling last 24 hours |
| one week | Rolling last 7 days |
| all | All events in the log, no time filter |

Each option shows how long ago the cutoff was (e.g. `since boot (3h ago)`).

### Category cards

- 8 collapsible cards, one per category, collapsed by default
- Each card has a **▶ Start Check** button on the right of its header to run that single category independently, without re-running the full check
- Cards expand automatically when their result arrives
- The title and left accent bar reflect the highest severity found:

  | Color | Severity |
  |-------|---------|
  | Red | CRITICAL |
  | Orange | HIGH |
  | Yellow | MEDIUM |
  | Blue | LOW |
  | Green | Clean — no issues found |

### Per-issue actions

Each issue card shows a severity badge, timestamp, source, description, and recommended action, plus five AI buttons:

| Button | What it does |
|--------|-------------|
| 💡 What is this? | Plain-language explanation, no technical jargon |
| 🔬 ELI the Techie | Technical deep-dive from a senior systems engineer persona: component, mechanism, event fields, Windows architecture context |
| ⚠ How worried should I be? | Honest severity assessment for a typical home user |
| → What's my next step? | Single most important action to take right now |
| ✎ Ask your own… | Free-form question about the issue |

The `{ }` icon on each issue opens a tooltip showing the raw Windows event log data for that entry.

Issues older than one week are visually dimmed to distinguish recent from historical events.

### Re-running

- **START CHECK** (header) — runs all 8 categories
- **▶ Start Check** (per card) — re-runs a single category at any time
- Both respect the currently selected time range

## Report format

Each issue uses a consistent structured format:

```
Event:       <short event name>
Severity:    <CRITICAL | HIGH | MEDIUM | LOW>
Date:        <date and time> (<time ago>)
Source:      <log name> / <provider name> (Event ID: <id>)
Description: <one sentence explaining what happened>
Action:      <one sentence describing the fix or next step>
```

Issues are sorted by severity (CRITICAL first) within each category.

## File structure

| File | Purpose |
|------|---------|
| `winsyscheck.ps1` | Entry point, CLI mode |
| `config.ps1` | API URL and event source group definitions |
| `events.ps1` | Event log querying logic |
| `helpers.ps1` | Shared utilities (time formatting, severity mapping, deduplication) |
| `llm.ps1` | LLM API calls (analysis and per-issue explanation) |
| `web.ps1` | HTTP server, SSE streaming, request routing |
| `web-ui.html` | Browser UI (served as a single file) |

## Disclaimer

Suggested actions are recommendations only and not guaranteed solutions. Review each suggestion carefully before applying any changes to your system — especially before running commands in a terminal or modifying Windows system settings. AI-generated analysis may be incorrect or incomplete.
