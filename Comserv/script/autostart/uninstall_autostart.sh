#!/bin/bash
# Undo install_autostart.sh: disable + remove the user units. Does NOT stop a running
# server/container (add --stop for that) and does not touch Docker's own restart policy.
#   script/autostart/uninstall_autostart.sh [--stop] [--no-linger]
set -uo pipefail
dest="$HOME/.config/systemd/user"; stop=0; nolinger=0
for a in "$@"; do case "$a" in --stop) stop=1;; --no-linger) nolinger=1;; esac; done
for u in comserv-aisystem-4006.service comserv-web-prod-5000.service; do
  [ $stop = 1 ] && systemctl --user stop "$u" 2>/dev/null
  systemctl --user disable "$u" 2>/dev/null
  rm -f "$dest/$u" && echo "removed $u"
done
systemctl --user daemon-reload
[ $nolinger = 1 ] && loginctl disable-linger "$USER"
echo done
