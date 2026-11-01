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

Neodisk is a disk visualizer. Scanning never modifies files; the only change
it makes is moving items the user confirmed to the Trash, and it never deletes
permanently. It makes no network requests. Reports of particular interest:

- Anything that causes Neodisk to write to, modify, or delete files other
  than moving confirmed items to the Trash
- A way past the Trash safety checks (protected locations, the check that an
  item is unchanged since the scan)
- Unexpected network activity
- Privilege escalation or sandbox/entitlement issues
