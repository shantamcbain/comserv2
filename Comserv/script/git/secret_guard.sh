#!/bin/bash
# secret_guard.sh — block secrets/key files from being committed.
# Usage: secret_guard.sh [repo_dir]   (defaults to current repo)
# Exit 0 = clean, 1 = blocked. Never prints file contents or secret values.
# Checks STAGED additions/modifications only; deletions (git rm --cached) always pass.
#   1. File-name patterns (*_encryption_key, *.key, *.pem, .env*, id_rsa*, ...)
#   2. New small (<4KB) binary or high-entropy single-token files (raw keys)
#   3. gitleaks protect --staged (if gitleaks installed)
# Allow-list: <repo>/.secret-guard-allow — one glob per line (matched on path), # comments.
# Shared copy: ~/.git-hooks/secret-guard.sh (called from global pre-commit) and
# called by the in-app commit paths (Admin/Git.pm, Util/Git.pm).
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

REPO="${1:-}"
if [ -n "$REPO" ]; then cd "$REPO" || { echo "secret-guard: cannot cd to $REPO"; exit 1; }; fi
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "secret-guard: not a git repo"; exit 1; }
cd "$ROOT" || exit 1

ALLOW_FILE="$ROOT/.secret-guard-allow"
ALLOW=()
if [ -f "$ALLOW_FILE" ]; then
    while IFS= read -r l; do
        l="${l%%#*}"; l="$(echo "$l" | xargs)"; [ -n "$l" ] && ALLOW+=("$l")
    done < "$ALLOW_FILE"
fi
allowed() {
    local p="$1" g
    for g in "${ALLOW[@]+"${ALLOW[@]}"}"; do
        # shellcheck disable=SC2053
        [[ "$p" == $g ]] && return 0
        [[ "$(basename "$p")" == $g ]] && return 0
    done
    return 1
}

FAIL=0
block() { echo "  BLOCKED: $1 — $2"; FAIL=1; }

# 1 + 2: walk staged added/copied/modified/renamed files (NUL-safe)
while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    case "$status" in R*|C*) IFS= read -r -d '' path ;; esac
    allowed "$path" && continue
    base="$(basename "$path")"
    case "$base" in
        *_encryption_key|.*_encryption_key|*.key|*.pem|*.p12|*.pfx|*.jks|*.kdbx|\
        id_rsa|id_rsa.*|id_rsa_*|id_ed25519|id_ed25519.*|id_ed25519_*|id_ecdsa*|id_dsa*|\
        .env|.env.*|db_config.json|credentials.json|auth.json)
            block "$path" "file name matches a secret/key pattern"; continue ;;
    esac
    # New files only for the content heuristics
    [ "${status:0:1}" = "A" ] || continue
    size=$(git cat-file -s ":$path" 2>/dev/null || echo 0)
    [ "$size" -gt 0 ] && [ "$size" -lt 4096 ] || continue
    verdict=$(git cat-file blob ":$path" 2>/dev/null | perl -0777 -ne '
        if (/\x00/) { print "binary"; exit }
        my $s = $_; $s =~ s/\s+\z//; $s =~ s/\A\s+//;
        # raw key: one long token (no inner whitespace), high Shannon entropy
        if (length($s) >= 16 && $s !~ /\s/) {
            my %f; $f{$_}++ for split //, $s; my $n = length $s; my $h = 0;
            for (values %f) { my $p = $_/$n; $h -= $p*log($p)/log(2) }
            print "entropy" if $h >= 3.5 && $s =~ /[0-9]/ || $h >= 4.5;
        }')
    case "$verdict" in
        binary)  block "$path" "new small binary file (<4KB) — looks like a key/keystore" ;;
        entropy) block "$path" "new small high-entropy single-token file — looks like a raw key" ;;
    esac
done < <(git diff --cached --name-status -z --diff-filter=ACMR)

# 3: gitleaks on staged content
if command -v gitleaks >/dev/null 2>&1; then
    CFG=(); [ -f "$ROOT/.gitleaks.toml" ] && CFG=(--config "$ROOT/.gitleaks.toml")
    if ! gitleaks protect --staged --no-banner --redact "${CFG[@]+"${CFG[@]}"}" >/tmp/secret_guard_gitleaks.$$ 2>&1; then
        echo "  BLOCKED: gitleaks found a possible secret in staged content (redacted):"
        grep -E 'File:|RuleID:|Line:' /tmp/secret_guard_gitleaks.$$ | sed 's/^/    /'
        FAIL=1
    fi
    rm -f /tmp/secret_guard_gitleaks.$$
fi

if [ "$FAIL" -ne 0 ]; then
    echo "secret-guard: commit refused. Unstage the file(s) (git restore --staged <file>),"
    echo "  keep keys in ~/.comserv/keys, or add a reviewed glob to .secret-guard-allow."
    exit 1
fi
exit 0
