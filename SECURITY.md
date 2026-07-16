# Security Policy

## Supported Versions

Security fixes are applied to the latest SoloFan release line only.

| Version | Supported |
| ------- | --------- |
| 1.6.x   | Yes       |
| < 1.6   | No        |

Please upgrade to the latest release from [GitHub Releases](https://github.com/SoloTeamDev/solofan/releases) or [Gumroad](https://lounnas.gumroad.com/l/ffan).

## Reporting a Vulnerability

If you find a security issue in SoloFan (including the privileged SMC helper, install scripts, or release artifacts), please report it privately so we can fix it before public disclosure.

**Preferred:** use GitHub’s private vulnerability reporting on this repository:

1. Open the repo on GitHub → **Security** → **Advisories** (or **Report a vulnerability**)
2. Or go to: https://github.com/SoloTeamDev/solofan/security/advisories/new

**Alternatively**, email: **mohamadlounnas@gmail.com** with:

- A clear description of the issue
- Steps to reproduce
- Affected version / commit / platform (macOS version, Apple Silicon or Intel)
- Any proof-of-concept (non-destructive preferred)

Please **do not** open a public GitHub issue for security vulnerabilities.

## What to Expect

- We aim to acknowledge reports within **7 days**
- We will assess severity and work on a fix for the supported release line
- We may ask for more details; please keep the discussion private until a fix is released
- Once fixed, we will credit reporters if you want (optional)

## Scope Notes

SoloFan requires elevated privileges to talk to the SMC for fan control. Reports related to privilege escalation, helper tool abuse, install-script tampering, or notarization / distribution integrity are especially welcome.

For general bugs that are not security-sensitive, use [GitHub Issues](https://github.com/SoloTeamDev/solofan/issues).
