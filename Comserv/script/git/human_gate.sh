#!/bin/sh
# Comserv2 human gate. AI may edit files. AI may not commit or publish.
# Called as: human_gate.sh commit|push|receive
# No-op outside this repo. Exit 0 = allowed, 1 = refused.
set -u

mode=${1:-}
PRIMARY=/home/shanta/PycharmProjects/comserv2

is_comserv2() {
    url=$(git config --get remote.origin.url 2>/dev/null || true)
    top=$(git rev-parse --show-toplevel 2>/dev/null || true)
    case "$url" in
        *shantamcbain/comserv2*) return 0 ;;
    esac
    case "$top" in
        "$PRIMARY"|/home/shanta/.comserv/worktrees/*) return 0 ;;
    esac
    return 1
}

is_comserv2 || exit 0

ai_identity() {
    email=$(git config --get user.email 2>/dev/null || true)
    name=$(git config --get user.name 2>/dev/null || true)
    case "$email" in
        zencoder@*|git@workstation.local|hermes@*|cursor@*) return 0 ;;
    esac
    case "$name" in
        Zencoder|"Git tools"|"Hermes Agent"|Cursor) return 0 ;;
    esac
    return 1
}

# 0 if an ancestor command line is an agent. 1 otherwise.
agent_ancestor() {
    pid=$PPID
    i=0
    while [ "$i" -lt 12 ] && [ -n "${pid:-}" ] && [ "$pid" != 1 ]; do
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
        case "$cmd" in
            *hermes*|*zencoder*|*cursor-agent*|*aider*) return 0 ;;
        esac
        pid=$(awk '/^PPid:/ { print $2 }' "/proc/$pid/status" 2>/dev/null || true)
        i=$((i + 1))
    done
    return 1
}

server_ancestor() {
    pid=$PPID
    i=0
    while [ "$i" -lt 12 ] && [ -n "${pid:-}" ] && [ "$pid" != 1 ]; do
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
        case "$cmd" in
            *comserv_server.pl*) return 0 ;;
        esac
        pid=$(awk '/^PPid:/ { print $2 }' "/proc/$pid/status" 2>/dev/null || true)
        i=$((i + 1))
    done
    return 1
}

primary_checkout() {
    top=$(git rev-parse --show-toplevel 2>/dev/null || true)
    [ "$top" = "$PRIMARY" ]
}

has_tty() {
    ( : <>/dev/tty ) 2>/dev/null
}

refuse() {
    echo "comserv2: $*" >&2
    exit 1
}

case "$mode" in
    commit)
        if ai_identity; then
            refuse "commit refused. This checkout's git identity is an AI account ($(git config --get user.name 2>/dev/null) <$(git config --get user.email 2>/dev/null)>). A human admin reviews and commits."
        fi
        if agent_ancestor; then
            refuse "commit refused. An agent is in the process tree. Leave the files for a human admin to review and commit."
        fi
        if [ "${COMSERV_ADMIN_COMMIT:-}" = 1 ] && server_ancestor; then
            exit 0
        fi
        if has_tty; then
            exit 0
        fi
        refuse "commit refused. Not a human terminal and not the admin git page."
        ;;
    push|receive)
        if agent_ancestor; then
            refuse "push refused. An agent cannot publish to GitHub. Test, merge to main, then publish main from the primary checkout."
        fi
        if [ "${COMSERV_ADMIN_PUSH:-}" = 1 ] && server_ancestor && primary_checkout; then
            exit 0
        fi
        if has_tty; then
            printf 'Type PUSH to publish this comserv2 ref to GitHub: ' >/dev/tty
            read -r ans </dev/tty || refuse "push refused. No confirmation."
            [ "$ans" = "PUSH" ] || refuse "push refused. Confirmation was not PUSH."
            exit 0
        fi
        refuse "push refused. GitHub publish is admin-only, from the primary main checkout, after you test. Worktree branches stay local."
        ;;
    *)
        refuse "human_gate.sh: unknown mode '$mode'"
        ;;
esac
