# Security Policy

## Supported Versions

Only the latest published release of **EU5 RPC** receives security updates and bug fixes.

| Version | Supported |
| ------- | --------- |
| Latest (`v0.3.x`) | Yes |
| Older releases | No |

## Reporting a Vulnerability

Please **do not** report security vulnerabilities through public GitHub issues.

Instead, report vulnerabilities privately using GitHub Security Advisories:

- **Private Vulnerability Report**: https://github.com/buntatoes/eu5-rpc/security/advisories/new

Please include:
- Affected version and operating system (Windows or Linux).
- Clear steps to reproduce the issue.
- Potential impact and any suggested remediation.

We will acknowledge reports as promptly as possible and publish a fix in a new release.

## Anti-Cheat & Privacy Guarantees

- **100% VAC-Safe & Ironman-Safe**: EU5 RPC is strictly external and read-only. It never reads game process memory, never injects DLLs, never hooks game code, never modifies save files or checksums, and never calls `SteamAPI_Init`.
- **Zero Telemetry or Tracking**: EU5 RPC communicates only with your local Steam client IPC, local EU5 log/save metadata, and local Discord desktop IPC. No personal data, Steam IDs, Discord tokens, or usage analytics are collected or transmitted.
