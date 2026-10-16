#!/usr/bin/env bash
#
# auto_update_ollama.sh — Check GitHub for a newer Ollama release and upgrade if found.
#
# Safe to run weekly via cron. Idempotent: skips if already current.
# Logs to stdout (cron captures it). Requires: curl, tar (zstd), sudo systemctl.
#
# Cron (Sunday 03:00):
#   0 3 * * 0 /path/to/Comserv/script/auto_update_ollama.sh >> /var/log/ollama_update.log 2>&1

set -euo pipefail

BIN="/usr/local/bin/ollama"
LIB_DIR="/usr/local/lib/ollama"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# 1. Get running version
current=$("$BIN" --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
if [[ -z "$current" ]]; then
    log "ERROR: cannot determine current ollama version"
    exit 1
fi
log "Current version: $current"

# 2. Get latest release tag from GitHub
latest_tag=$(curl -sf --max-time 10 \
    https://api.github.com/repos/ollama/ollama/releases/latest 2>/dev/null \
    | grep -oP '"tag_name":\s*"v\K[\d.]+"' | tr -d '"' | head -1)

if [[ -z "$latest_tag" ]]; then
    log "ERROR: cannot fetch latest release from GitHub (rate-limited or offline)"
    exit 1
fi
log "Latest version:  $latest_tag"

# 3. Compare versions (simple semver — compare major.minor.patch)
if [[ "$current" == "$latest_tag" ]]; then
    log "Already current — nothing to do."
    exit 0
fi

# Check that latest is actually newer
IFS=. read -r c_maj c_min c_pat <<< "$current"
IFS=. read -r l_maj l_min l_pat <<< "$latest_tag"
newer=false
if (( l_maj > c_maj )) || \
   (( l_maj == c_maj && l_min > c_min )) || \
   (( l_maj == c_maj && l_min == c_min && l_pat > c_pat )); then
    newer=true
fi

if ! $newer; then
    log "Current ($current) appears newer than latest tag ($latest_tag) — skipping."
    exit 0
fi

log "Upgrading from $current → $latest_tag"

# 4. Download
url="https://github.com/ollama/ollama/releases/download/v${latest_tag}/ollama-linux-amd64.tar.zst"
archive="$TMP_DIR/ollama.tar.zst"
log "Downloading $url …"
if ! curl -fsSL --max-time 300 -o "$archive" "$url"; then
    log "ERROR: download failed"
    exit 1
fi

# 5. Extract
log "Extracting …"
tar --zstd -xf "$archive" -C "$TMP_DIR"

# 6. Verify binary
new_bin="$TMP_DIR/bin/ollama"
if [[ ! -x "$new_bin" ]]; then
    log "ERROR: extracted binary not found at $new_bin"
    exit 1
fi
new_ver=$("$new_bin" --version 2>/dev/null | grep -oP 'client version is \K[\d.]+' | head -1)
if [[ "$new_ver" != "$latest_tag" ]]; then
    log "ERROR: version mismatch — expected $latest_tag, got $new_ver"
    exit 1
fi
log "Extracted binary: v$new_ver"

# 7. Stop, replace, restart
log "Stopping ollama service …"
sudo systemctl stop ollama

sudo cp "$new_bin" "$BIN"
if [[ -d "$TMP_DIR/lib/ollama" ]]; then
    sudo mkdir -p "$LIB_DIR"
    sudo cp -r "$TMP_DIR/lib/ollama/"* "$LIB_DIR/"
fi

log "Starting ollama service …"
sudo systemctl start ollama
sleep 2

# 8. Verify
running_ver=$("$BIN" --version 2>/dev/null | grep -oP 'ollama version is \K[\d.]+' | head -1)
if [[ "$running_ver" == "$latest_tag" ]]; then
    log "SUCCESS: upgraded to $running_ver"
else
    log "WARNING: running version is $running_ver (expected $latest_tag)"
fi