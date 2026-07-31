# Security Scan Findings — 2026-07-31

Baseline run of the free hardening stack (gitleaks + cpan-audit + trivy).
See `security_hardening_free_stack.md` for setup and how to re-run.

## 1. Secrets — gitleaks
- **Result: PASS.** No secrets detected in tracked files.
- Note: gitleaks scans `git diff --cached` / tracked source only. The perl
  `local/` tree (gitignored) contains CryptX test fixtures that *look* like keys;
  these are vendored CPAN test data, not our secrets, and are never committed.

## 2. Perl dependencies — cpan-audit
- **Result: ADVISORIES FOUND** across the installed module tree. Many are on
  security-critical modules. Highest-priority (remediate by `cpanm` upgrade):
  - **CryptX** — fork PRNG reuse (CVE-2026-41564), AEAD tag timing oracle
    (CVE-2026-13758), buffer overflows (CVE-2026-41565), libtommath int overflow.
    Directly affects Starman prefork key generation.
  - **Crypt-PBKDF2** — predictable `rand()` salts + weak default iters + timing
    attack (CVE-2026-9638/9641/2017-20240).
  - **Crypt-CBC / Crypt-Random** — `rand()` entropy fallback; insecure module
    search paths.
  - **Catalyst-Plugin-Session** — predictable session-id entropy (CVE-2025-40924).
  - **Catalyst-Plugin-Authentication** — session fixation (CVE-2009-10007) +
    timing attack (CVE-2026-5091).
  - **DBI** — 9 advisories incl. Profile code-injection (CVE-2026-14380),
    SQL preparse overflows, symlink escape (CVE-2026-15392).
  - **Starman** — HTTP request smuggling via CL/TE precedence (CVE-2026-40560).
  - **HTTP-Tiny / LWP::UserAgent** — credential leakage on cross-origin redirect
    (CVE-2026-7017 / CVE-2026-8368).
  - **CGI-Simple** — HTTP response splitting / header injection (CVE-2025-40927).
  - **perl 5.40.0** — 5 advisories (regex/trie overflows, `tr` heap overflow,
    threads cwd race). Upgrade to 5.40.2+ / 5.41.13+.
- Remediation: upgrade the named distributions; track via the app's error-audit
  todo workflow. Several (CryptX, DBI, Starman, Catalyst plugins) are
  load-bearing for auth/crypto — stage upgrades and re-run cpan-audit to confirm.

## 3. Container image — trivy (image: shantamcsbain/comserv-web-prod:latest)
- **Result: 1984 OS-package findings (HIGH 1763, CRITICAL 221)** in the Debian
  12 base image + imagemagick / gnutls / glib / libxml2 / openssh / perl 5.36,
  etc. Most are fixed in later Debian point releases — i.e. the base image is
  stale, not necessarily exploitable in our usage.
- **Private-key hits** in `Crypt/PK/*.pm` are CryptX vendored test fixtures
  (gitignored `local/` tree), not real secrets. Trivy false-positive.
- **REAL FINDING — CA key baked into image:** Trivy (and the Aikido pre-commit
  hook) flagged a PEM private key at `/opt/comserv/config/dev_tls/comserv-dev-ca.key`
  inside the built image. Source is `Comserv/config/dev_tls/comserv-dev-ca.key`
  on disk (gitignored, so not in git, but **copied into the image during build**).
  This is a dev CA, not production, but it should not ship in the image.
  - Fix: stop copying `config/dev_tls/` into the image (or mount it at runtime /
    generate it in a volume). Re-scan to confirm it's gone.
  - The raw trivy report was intentionally NOT committed because it embeds the
    key block; the finding is recorded here instead.
- Highest-signal packages: `libglib2.0-*` (CVE-2025-14087 CRITICAL,
  CVE-2026-58010 HIGH), `libgnutls30` (CVE-2026-33845 CRITICAL), `imagemagick*`
  (multiple), `libxml2`, `openssh-client`, `perl`/`libperl5.36`.
- Remediation: rebuild the image from an updated Debian 12 base
  (`apt-get upgrade` / newer `debian:12` tag) and re-scan. Full per-CVE list:
  `security_scan_trivy_20260731.txt`.

## Priority
1. **cpan-audit upgrades** for crypto/session/DBI modules (cheap, high impact).
2. **Rebuild container image** on refreshed base (closes 1984 findings at once).
3. Keep **gitleaks pre-commit hook** active (already installed).
