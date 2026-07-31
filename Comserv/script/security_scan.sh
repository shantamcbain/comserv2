#!/bin/bash
# Comserv2 security scan — free, self-hosted.
#
# Covers the three high-value, cheap wins:
#   1. Secrets      -> gitleaks  (scans git-tracked source only)
#   2. Perl deps    -> cpan-audit (advisory DB for installed CPAN modules)
#   3. Container    -> trivy     (image vuln scan; optional, needs an image)
#
# Designed to slot into deploy.sh and CI. Does NOT fail the build by itself
# (set STRICT=1 to make findings exit non-zero). Always prints a summary.
#
# Binaries are expected under ~/.local/bin and the perlbrew bin dir. Override
# with env vars GITLEAKS_BIN / CPAN_AUDIT_BIN / TRIVY_BIN if installed elsewhere.

set -u

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
cd "$REPO_ROOT" || { echo "❌ cannot cd to repo root"; exit 1; }

export PATH="$HOME/.local/bin:$HOME/perl5/bin:$PATH"

GITLEAKS_BIN="${GITLEAKS_BIN:-$(command -v gitleaks || echo "$HOME/.local/bin/gitleaks")}"
CPAN_AUDIT_BIN="${CPAN_AUDIT_BIN:-$(command -v cpan-audit || echo "$HOME/perl5/bin/cpan-audit")}"
TRIVY_BIN="${TRIVY_BIN:-$(command -v trivy || echo "$HOME/.local/bin/trivy")}"

GITLEAKS_CFG="${GITLEAKS_CFG:-$REPO_ROOT/.gitleaks.toml}"

STRICT="${STRICT:-0}"
SCAN_IMAGE="${SCAN_IMAGE:-}"   # e.g. shantamcsbain/comserv-web-prod:latest

rc=0
echo "================================================================"
echo " Comserv2 security scan  ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
echo " repo: $REPO_ROOT"
echo "================================================================"

# ---------------------------------------------------------------- 1. SECRETS
echo ""
echo ">>> [1/3] Secrets — gitleaks"
if [ -x "$GITLEAKS_BIN" ]; then
    if git ls-files -z | "$GITLEAKS_BIN" detect --no-banner \
            --config "$GITLEAKS_CFG" --redact --pipe 2>/tmp/gitleaks_run.txt; then
        echo "    ✅ No secrets found in tracked files."
    else
        echo "    ⚠️  Possible secret(s) detected:"
        sed 's/^/      /' /tmp/gitleaks_run.txt | grep -v 'INF scan completed' | head -40
        [ "$STRICT" = "1" ] && rc=1
    fi
else
    echo "    ⚠️  gitleaks not installed at $GITLEAKS_BIN (skipped)."
fi

# ---------------------------------------------------------- 2. PERL DEPENDENCIES
echo ""
echo ">>> [2/3] Perl dependencies — cpan-audit"
if [ -x "$CPAN_AUDIT_BIN" ]; then
    # cpan-audit installed: scans the perl install's module tree for advisories.
    if "$CPAN_AUDIT_BIN" installed 2>/tmp/cpanaudit_run.txt; then
        echo "    ✅ No known CPAN advisories for installed modules."
    else
        echo "    ⚠️  CPAN advisories found:"
        sed 's/^/      /' /tmp/cpanaudit_run.txt | head -60
        [ "$STRICT" = "1" ] && rc=1
    fi
else
    echo "    ⚠️  cpan-audit not installed at $CPAN_AUDIT_BIN (skipped)."
fi

# ------------------------------------------------------------ 3. CONTAINER (opt)
echo ""
echo ">>> [3/3] Container image — trivy"
if [ -x "$TRIVY_BIN" ]; then
    if [ -n "$SCAN_IMAGE" ]; then
        echo "    Scanning image: $SCAN_IMAGE"
        # High/critical only by default; full list with TRIVY_SEVERITY=UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL
        if "$TRIVY_BIN" image --quiet --severity "${TRIVY_SEVERITY:-HIGH,CRITICAL}" "$SCAN_IMAGE" 2>/tmp/trivy_run.txt; then
            echo "    ✅ No HIGH/CRITICAL image vulns."
        else
            echo "    ⚠️  Image vulns (HIGH/CRITICAL):"
            sed 's/^/      /' /tmp/trivy_run.txt | head -60
            [ "$STRICT" = "1" ] && rc=1
        fi
    else
        echo "    ℹ️  Skipped — set SCAN_IMAGE=shantamcsbain/comserv-web-prod:latest to enable."
    fi
else
    echo "    ⚠️  trivy not installed at $TRIVY_BIN (skipped)."
fi

echo ""
echo "================================================================"
if [ "$rc" -eq 0 ]; then
    echo " ✅ Scan complete — no blocking findings."
else
    echo " ❌ Scan found items (STRICT=1). Review above."
fi
echo "================================================================"
exit "$rc"
