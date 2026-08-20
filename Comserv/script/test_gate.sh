#!/bin/bash
# Comserv2 pre-merge test gate.
#
# PURPOSE
#   Catch "random errors" before a feature branch is merged to main. The
#   pre-commit hook only does perl -c (syntax) + gitleaks (secrets). This gate
#   runs the actual test suite so logic regressions and broken unit tests are
#   caught in the worktree before they reach production (main == prod here).
#
# USAGE (agent or human, before merging a branch to main)
#   cd Comserv
#   bash script/test_gate.sh                 # run the fast, boot-light subset
#   bash script/test_gate.sh --changed       # only tests mapped to changed .pm
#   bash script/test_gate.sh --all           # full suite (slow; boots Catalyst)
#   COMSERV_LOCAL_LIB=/abs/path bash script/test_gate.sh
#
# EXIT CODE
#   0 = all selected tests passed (safe to merge)
#   1 = one or more test failures (do NOT merge until green)
#   2 = harness problem (prove missing / suite could not run)
#
# WHAT IT RUNS
#   --fast (default) = boot-light subset: app smoke (t/01app.t) + AI controller
#       unit load (t/controller_AI_models.t) + bot-purging unit test. Fast, no
#       DB, safe to run on the live tree.
#   --all  = the entire t/ directory via `prove -lr` (boots Catalyst; slow).
#   --changed = prove on the test file mapped to each staged/changed .pm plus
#       the smoke test, so local boot breakage is always caught.
set -uo pipefail

# Resolve the Comserv checkout to test. Prefer an explicit COMSERV_DIR (the
# controller passes the *worktree* checkout here so the gate tests the branch
# being merged, not the repo the script file happens to live in). Fall back to
# deriving it from the script location only when nothing was provided.
if [ -n "${COMSERV_DIR:-}" ] && [ -d "$COMSERV_DIR" ]; then
    : # caller-supplied target checkout (e.g. a git worktree)
elif [ -d "$(dirname "$0")/.." ]; then
    COMSERV_DIR="$(cd "$(dirname "$0")/.." && pwd)"
else
    echo "❌ cannot resolve Comserv dir"; exit 2
fi
cd "$COMSERV_DIR" || { echo "❌ cannot cd to $COMSERV_DIR"; exit 2; }

export PATH="$HOME/.local/bin:$HOME/perl5/bin:$PATH"
PROVE_BIN="$(command -v prove || true)"
if [ -z "$PROVE_BIN" ]; then
    PROVE_BIN="$HOME/perl5/perlbrew/perls/perl-5.40.0/bin/prove"
fi
if [ ! -x "$PROVE_BIN" ]; then
    echo "❌ prove not found (install Test::Harness). Aborting gate."
    exit 2
fi

# Include the app's local::lib if present so prove resolves all deps.
LIB_ARGS=(-l -r)
if [ -n "${COMSERV_LOCAL_LIB:-}" ]; then
    LIB_ARGS=(-I "$COMSERV_LOCAL_LIB" -I "$COMSERV_DIR/lib")
elif [ -d "$COMSERV_DIR/local/lib/perl5" ]; then
    LIB_ARGS=(-I "$COMSERV_DIR/local/lib/perl5" -I "$COMSERV_DIR/lib")
else
    LIB_ARGS=(-I "$COMSERV_DIR/lib")
fi

MODE="${1:---fast}"

run_prove() {
    if [ "$#" -eq 0 ]; then
        echo "    No test files selected — gate cannot run."
        return 2
    fi
    echo ">>> Running: prove ${LIB_ARGS[*]} $*"
    "$PROVE_BIN" "${LIB_ARGS[@]}" "$@"
    return $?
}

case "$MODE" in
    --all)
        echo "=== FULL TEST GATE (entire t/) ==="
        run_prove t/
        rc=$?
        ;;
    --changed)
        echo "=== CHANGED-FILE TEST GATE ==="
        # Gather staged + unstaged .pm files.
        mapfile -t PMS < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | grep '\.pm$' || true)
        mapfile -t WORKTREE_PMS < <(git diff --name-only --diff-filter=ACMR 2>/dev/null | grep '\.pm$' || true)
        TESTS=()
        for f in "${PMS[@]:-}" "${WORKTREE_PMS[@]:-}"; do
            [ -n "$f" ] || continue
            base="$(basename "$f" .pm)"
            for cand in "t/controller_${base}.t" "t/${base}.t" "t/${base}_test.t"; do
                [ -f "$cand" ] && TESTS+=("$cand")
            done
        done
        # Always include the smoke test so local boot breakage is caught.
        TESTS+=("t/01app.t")
        if [ "${#TESTS[@]}" -eq 0 ]; then
            echo "    No mapped test files for changed .pm — running fast subset instead."
            run_prove t/01app.t t/controller_AI_models.t t/bot_prevention_and_purging.t
            rc=$?
        else
            printf '    Selected: %s\n' "${TESTS[*]}"
            run_prove "${TESTS[@]}"
            rc=$?
        fi
        ;;
    --fast|*)
        echo "=== FAST TEST GATE (boot-light subset) ==="
        # Only run the standard smoke tests that actually exist in THIS checkout.
        # Older/stale worktrees predate the test suite and have none of these
        # files — reporting a generic "FAILED" there is misleading (no test ran).
        # Detect that and say so clearly instead.
        FILES=()
        for f in t/01app.t t/controller_AI_models.t t/bot_prevention_and_purging.t; do
            [ -f "$COMSERV_DIR/$f" ] && FILES+=("$f")
        done
        if [ "${#FILES[@]}" -eq 0 ]; then
            echo "🛑 No fast-subset test files in this checkout ($COMSERV_DIR/t)."
            echo "   This worktree is stale and has no test suite. Update it from main"
            echo "   (merge main into this branch) so it gains the tests, then re-run the gate."
            exit 2
        fi
        run_prove "${FILES[@]}"
        rc=$?
        ;;
esac

if [ "$rc" -eq 0 ]; then
    echo "✅ TEST GATE PASSED — safe to merge."
else
    echo "🛑 TEST GATE FAILED (exit $rc) — do NOT merge until green."
fi
exit "$rc"
