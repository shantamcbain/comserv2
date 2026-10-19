#!/bin/bash
# secret_guard.sh — block secrets/key files from entering git history.
# Never prints file contents or secret values (file names / rule ids only).
#
# Modes:
#   secret_guard.sh [repo]                    staged index vs HEAD (pre-commit,
#                                             pre-merge-commit: index = merge result)
#   secret_guard.sh --range BASE TIP [repo]   files added/changed in BASE..TIP (pre-push)
#   secret_guard.sh --merge REF [repo]        what merging REF into HEAD would bring in
#                                             (merge-base(HEAD,REF)..REF) — in-app merges
# Exit 0 = clean, 1 = blocked. Deletions (git rm --cached) always pass.
# Checks: 1. key/secret file-name patterns  2. new small (<4KB) binary or high-entropy
#         single-token files (raw keys)      3. gitleaks (if installed)
# Allow-list: <repo>/.secret-guard-allow — one glob per line, # comments. Allow-listed
# hits are reported as ALLOWED but do not block.
# Copies: ~/.git-hooks/secret-guard.sh (global hooks) — keep in sync with this file.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

MODE=staged; BASE=""; TIP=""
case "${1:-}" in
    --range) MODE=range; BASE="${2:-}"; TIP="${3:-}"; shift 3 || true ;;
    --merge) MODE=merge; TIP="${2:-}"; shift 2 || true ;;
esac
REPO="${1:-}"
if [ -n "$REPO" ]; then cd "$REPO" || { echo "secret-guard: cannot cd to $REPO"; exit 1; }; fi
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "secret-guard: not a git repo"; exit 1; }
cd "$ROOT" || exit 1
EMPTY_TREE=$(git hash-object -t tree /dev/null)

if [ "$MODE" = merge ]; then
    git rev-parse -q --verify "$TIP^{commit}" >/dev/null || { echo "secret-guard: unknown ref $TIP"; exit 1; }
    BASE=$(git merge-base HEAD "$TIP" 2>/dev/null || echo "$EMPTY_TREE")
    MODE=range
fi
if [ "$MODE" = range ]; then
    [ -n "$TIP" ] || { echo "secret-guard: --range needs BASE TIP"; exit 1; }
    [ -n "$BASE" ] || BASE="$EMPTY_TREE"
fi

ALLOW=()
if [ -f "$ROOT/.secret-guard-allow" ]; then
    while IFS= read -r l; do
        l="${l%%#*}"; l="$(echo "$l" | xargs)"; [ -n "$l" ] && ALLOW+=("$l")
    done < "$ROOT/.secret-guard-allow"
fi
allowed() {
    local p="$1" g
    for g in "${ALLOW[@]+"${ALLOW[@]}"}"; do
        # shellcheck disable=SC2053
        [[ "$p" == $g ]] && return 0
    done
    return 1
}

FAIL=0
hit() { # path reason
    if allowed "$1"; then echo "  ALLOWED (allow-listed, see .secret-guard-allow): $1 — $2"
    else echo "  BLOCKED: $1 — $2"; FAIL=1; fi
}

if [ "$MODE" = staged ]; then
    LIST=(git diff --cached --name-status -z --diff-filter=ACMR)
    blob() { echo ":$1"; }
else
    LIST=(git diff --name-status -z --diff-filter=ACMR "$BASE" "$TIP")
    blob() { echo "$TIP:$1"; }
fi

while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    case "$status" in R*|C*) IFS= read -r -d '' path ;; esac
    base="$(basename "$path")"
    case "$base" in
        *_encryption_key|.*_encryption_key|*.key|*.pem|*.p12|*.pfx|*.jks|*.kdbx|\
        id_rsa|id_rsa.*|id_rsa_*|id_ed25519|id_ed25519.*|id_ed25519_*|id_ecdsa*|id_dsa*|\
        .env|.env.*|db_config.json|credentials.json|auth.json)
            hit "$path" "file name matches a secret/key pattern"; continue ;;
    esac
    [ "${status:0:1}" = "A" ] || continue
    ref=$(blob "$path")
    size=$(git cat-file -s "$ref" 2>/dev/null || echo 0)
    [ "$size" -gt 0 ] && [ "$size" -lt 4096 ] || continue
    verdict=$(git cat-file blob "$ref" 2>/dev/null | perl -0777 -ne '
        if (/\x00/) { print "binary"; exit }
        my $s = $_; $s =~ s/\s+\z//; $s =~ s/\A\s+//;
        if (length($s) >= 16 && $s !~ /\s/) {
            my %f; $f{$_}++ for split //, $s; my $n = length $s; my $h = 0;
            for (values %f) { my $p = $_/$n; $h -= $p*log($p)/log(2) }
            print "entropy" if ($h >= 3.5 && $s =~ /[0-9]/) || $h >= 4.5;
        }')
    case "$verdict" in
        binary)  hit "$path" "new small binary file (<4KB) — looks like a key/keystore" ;;
        entropy) hit "$path" "new small high-entropy single-token file — looks like a raw key" ;;
    esac
done < <("${LIST[@]}")

# gitleaks — findings on allow-listed paths do not block
if command -v gitleaks >/dev/null 2>&1; then
    CFG=(); [ -f "$ROOT/.gitleaks.toml" ] && CFG=(--config "$ROOT/.gitleaks.toml")
    REP=$(mktemp); trap 'rm -f "$REP"' EXIT
    if [ "$MODE" = staged ]; then
        gitleaks protect --staged --no-banner --redact "${CFG[@]+"${CFG[@]}"}" \
            --report-format json --report-path "$REP" >/dev/null 2>&1
    elif [ "$BASE" = "$EMPTY_TREE" ]; then
        gitleaks detect --no-banner --redact "${CFG[@]+"${CFG[@]}"}" --log-opts="$TIP" \
            --report-format json --report-path "$REP" >/dev/null 2>&1
    else
        gitleaks detect --no-banner --redact "${CFG[@]+"${CFG[@]}"}" --log-opts="$BASE..$TIP" \
            --report-format json --report-path "$REP" >/dev/null 2>&1
    fi
    if [ -s "$REP" ]; then
        while IFS=$'\t' read -r f rule; do
            [ -n "$f" ] || continue
            hit "$f" "gitleaks rule $rule"
        done < <(perl -MJSON::PP -0777 -ne 'my %s; for (@{ decode_json($_ || "[]") }) {
                    my $k = "$_->{File}\t$_->{RuleID}"; print "$k\n" unless $s{$k}++ }' "$REP" 2>/dev/null)
    fi
fi

if [ "$FAIL" -ne 0 ]; then
    echo "secret-guard: refused. Remove the flagged file(s) from the commit/merge/push,"
    echo "  keep keys in ~/.comserv/keys, or add a reviewed glob to .secret-guard-allow."
    exit 1
fi
exit 0
