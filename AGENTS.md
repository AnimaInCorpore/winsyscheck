# AGENTS.md

## Project overview

`winsyscheck` is a single-file PowerShell script that reads Windows event logs, sends them to a local LLM, and prints a prioritized system health report.

## Core principle: keep it simple

All changes must follow this rule: **no external dependencies unless explicitly requested.**

- No additional modules, packages, or third-party tools
- No new files unless strictly necessary
- Prefer extending the existing script over splitting it
- Avoid abstractions and indirection — flat, readable PowerShell is preferred

## What the script does

1. Queries Windows event logs across several categories (Security, Hardware, OS, Network, Performance, Antivirus, Updates)
2. Sends log data to a local OpenAI-compatible LLM endpoint (`http://localhost:8080/v1/chat/completions`)
3. Prints a structured, severity-sorted report

## When making changes

- Touch only what is needed for the task
- Do not refactor surrounding code unless asked
- Do not add error handling for unlikely edge cases
- Do not add configuration files, wrappers, or helper scripts
- The script must remain runnable with a plain `.\winsyscheck.ps1` — no setup steps beyond what is in the README
