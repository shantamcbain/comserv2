#!/bin/bash
# Install + enable the :4006 / :5000 autostart user units (PREPARED Oct 10 2026, not run).
#   script/autostart/install_autostart.sh            # 4006 and 5000
#   script/autostart/install_autostart.sh 4006       # only one
# Add --linger to start at BOOT (before you log in): runs `loginctl enable-linger shanta`.
# Nothing is started now; units start at the next login/boot. To start immediately:
#   systemctl --user start comserv-aisystem-4006   (skips itself if :4006 already up)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.config/systemd/user"
ports=(); linger=0
for a in "$@"; do case "$a" in --linger) linger=1;; 4006|5000) ports+=("$a");; *) echo "unknown arg $a"; exit 2;; esac; done
[ ${#ports[@]} -eq 0 ] && ports=(4006 5000)
mkdir -p "$dest" "$HOME/.comserv/logs"
for p in "${ports[@]}"; do
  case $p in 4006) u=comserv-aisystem-4006.service;; 5000) u=comserv-web-prod-5000.service;; esac
  [ -e "$dest/$u" ] && cp -a "$dest/$u" "$dest/$u.bak.$(date +%Y%m%d%H%M%S)"
  install -m 0644 "$here/$u" "$dest/$u"
  echo "installed $dest/$u"
done
systemctl --user daemon-reload
for p in "${ports[@]}"; do
  case $p in 4006) u=comserv-aisystem-4006.service;; 5000) u=comserv-web-prod-5000.service;; esac
  systemctl --user enable "$u"
done
[ $linger = 1 ] && loginctl enable-linger "$USER" && echo "linger enabled (units start at boot)"
echo "done. undo: $here/uninstall_autostart.sh"
