#!/bin/sh
# core.sshCommand for the comserv2 repo. Fetch is unchanged.
# A push (git-receive-pack) must pass the human gate, including git push --no-verify.
set -u
recv=0
for a in "$@"; do
    case "$a" in
        *receive-pack*) recv=1 ;;
    esac
done
if [ "$recv" = 1 ]; then
    dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
    "$dir/human_gate.sh" receive || exit 1
fi
exec /usr/bin/ssh "$@"
