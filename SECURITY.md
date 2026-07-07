# Security Policy

## Supported Versions

Only the [latest release](https://github.com/tkslucas/Neodisk/releases/latest)
is supported. Older versions do not receive security fixes.

## Reporting a Vulnerability

Please report vulnerabilities privately via
[GitHub Security Advisories](https://github.com/tkslucas/Neodisk/security/advisories/new)
— do not open a public issue.

Include, where possible:

- Neodisk and macOS versions
- Steps to reproduce
- Impact you believe the issue has

You should receive an acknowledgement within a few days. Please allow time
for a fix and release before disclosing publicly.

## Scope

Neodisk is a read-only disk visualizer: it never modifies or deletes user
files, and it makes no network requests. Reports of particular interest:

- Anything that causes Neodisk to write to, modify, or delete scanned files
- Unexpected network activity
- Privilege escalation or sandbox/entitlement issues
