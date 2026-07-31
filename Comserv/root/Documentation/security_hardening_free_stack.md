# Comserv2 — Free Security Hardening Stack

Self-hosted, zero-subscription security gates. Covers the three high-value,
low-cost wins for this app: **secrets**, **Perl dependency advisories**, and
**container image vulnerabilities**.

> This is a substitute for a paid SCA/SAST cloud (e.g. Aikido). No scanner does
> real data-flow SAST for Perl, so code-level detection here is intentionally
> shallow — the value is in secrets + deps + image, which are all free.

## Tools & install (done once, on the dev host)

All binaries live in `~/.local/bin`; the Perl tooling in the perlbrew bin dir.
These are machine-local (not committed) — reinstall them from the commands below
if the host is rebuilt.

| Tool         | Purpose                          | Install |
|--------------|----------------------------------|---------|
| gitleaks 8.18.4 | Secrets detection (tracked files) | download `gitleaks_*_linux_x64.tar.gz`, extract `gitleaks` -> `~/.local/bin/` |
| trivy 0.72.0    | Container image vuln scan         | download `trivy_*_Linux-64bit.tar.gz`, extract `trivy` -> `~/.local/bin/` |
| cpan-audit     | CPAN advisory scan                | `cpanm -n CPAN::Audit` (lands in perlbrew `bin/`) |

`~/.local/bin` is not on the default PATH — the scripts add it explicitly.

## What runs where

### Pre-commit hook (`.git/hooks/pre-commit`)
- Runs **gitleaks** over staged files only (~2s).
- Blocks the commit if a secret is found. Emergency bypass: `git commit --no-verify`.
- Skip rationale: it scans `git diff --cached` (not the whole tree), so it never
  blocks on vendored/ignored directories.

### Unified scan (`Comserv/script/security_scan.sh`)
Runs all three checks. Add to `deploy.sh` or CI:
```
bash Comserv/script/security_scan.sh                 # report only, exit 0
STRICT=1 bash Comserv/script/security_scan.sh         # non-zero on findings
SCAN_IMAGE=shantamcsbain/comserv-web-prod:latest \
  bash Comserv/script/security_scan.sh                # also scan the container image
```
The container scan is opt-in via `SCAN_IMAGE` (trivy must download its DB on
first run — slow once, then cached).

### Config (`/home/shanta/PycharmProjects/comserv2/.gitleaks.toml`)
Extends gitleaks' default rules; whitelists vendored/generated dirs
(`node_modules`, `local/`, `whisper_venv`, minified JS, Documentation export
JSONs) and a few documentation placeholder regexes to suppress false positives.

## Findings & remediation

`cpan-audit` found advisories across the Perl install — several on
security-critical modules (CryptX, Crypt-PBKDF2, Crypt-CBC, Catalyst
Session/Authentication, DBI, Starman, HTTP-Tiny, CGI-Simple). Remediation is a
`cpanm` upgrade of the named distributions; track via the app's existing
error-audit / todo workflow.

Trivy image results are kept in `/tmp/trivy_img.txt` after each run (or wire the
scan into `deploy.sh` to capture them in the deploy log).

## Limitations (read this)
- No Perl SAST: none of these tools reason about Catalyst request flow. Custom
  code review is still required for app-level issues (XSS in TT, SQLi, authz).
- `cpan-audit` scans the *installed* module tree, not `cpanfile` pins — keep the
  perl install reasonably current.
- gitleaks only catches known secret patterns; a novel/obfuscated secret can slip
  through. It is a backstop, not a guarantee.
