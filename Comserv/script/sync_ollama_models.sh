#!/usr/bin/env bash
#
# sync_ollama_models.sh — Pull recommended Ollama models and remove deprecated ones.
#
# Usage:
#   bash script/sync_ollama_models.sh
#   bash script/sync_ollama_models.sh 192.168.1.199   # target a remote Ollama host
#
# Cron example (run every Sunday at 03:00, log to file):
#   0 3 * * 0 /path/to/Comserv/script/sync_ollama_models.sh >> /var/log/ollama_sync.log 2>&1
#
# Remote Ollama servers:
#   The script uses the Ollama HTTP API, so it can target any host running Ollama.
#   Set OLLAMA_HOST / OLLAMA_PORT env vars or pass host as $1.
#
# To add/remove models: edit the RECOMMENDED and DEPRECATED arrays below, or keep
# in sync with list_available_models() / deprecated_models() in Ollama.pm.

set -euo pipefail

OLLAMA_HOST="${1:-${OLLAMA_HOST:-localhost}}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
BASE_URL="http://${OLLAMA_HOST}:${OLLAMA_PORT}"

RECOMMENDED=(
    "gemma4:31b-cloud"
    "gemma4:12b"
    "gemma4:4b"
    "llama3.1:latest"
    "phi4:14b"
    "phi4-mini:3.8b"
    "mistral:latest"
    "qwen2.5:7b"
)

DEPRECATED=(
    "llama2"
    "llama2:7b"
    "llama2:13b"
    "llama3:8b"
    "llama3"
    "phi:2.7b"
    "phi3:3.8b"
    "gemma:7b"
    "gemma:2b"
    "gemma2:2b"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

check_connection() {
    if ! curl -sf --max-time 5 "${BASE_URL}/api/tags" > /dev/null 2>&1; then
        log "ERROR: Cannot reach Ollama at ${BASE_URL}. Is it running?"
        exit 1
    fi
}

get_installed() {
    curl -sf "${BASE_URL}/api/tags" 2>/dev/null \
        | grep -o '"name":"[^"]*"' \
        | sed 's/"name":"//;s/"//'
}

pull_model() {
    local model="$1"
    log "Pulling ${model}…"
    local payload="{\"name\":\"${model}\",\"stream\":false}"
    local http_code
    http_code=$(curl -sf --max-time 600 -w "%{http_code}" -o /tmp/ollama_pull_$$.json \
        -X POST "${BASE_URL}/api/pull" \
        -H "Content-Type: application/json" \
        -d "${payload}" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
        log "  ✓ Pulled ${model}"
    else
        log "  ✗ Pull failed for ${model} (HTTP ${http_code})"
    fi
    rm -f /tmp/ollama_pull_$$.json
}

remove_model() {
    local model="$1"
    log "Removing deprecated model: ${model}…"
    local payload="{\"name\":\"${model}\"}"
    local http_code
    http_code=$(curl -sf --max-time 30 -w "%{http_code}" -o /dev/null \
        -X DELETE "${BASE_URL}/api/delete" \
        -H "Content-Type: application/json" \
        -d "${payload}" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
        log "  🗑 Removed ${model}"
    else
        log "  ✗ Remove failed for ${model} (HTTP ${http_code})"
    fi
}

main() {
    log "=== Ollama Model Sync — ${BASE_URL} ==="

    check_connection

    mapfile -t INSTALLED < <(get_installed)
    log "Currently installed: ${#INSTALLED[@]} models"

    local pulled=0 skipped=0 removed=0

    for model in "${RECOMMENDED[@]}"; do
        local base="${model%%:*}"
        local already=false
        for inst in "${INSTALLED[@]}"; do
            if [[ "$inst" == "$model" ]] || [[ "${inst%%:*}" == "$base" ]]; then
                already=true
                break
            fi
        done
        if $already; then
            log "  · Skipping ${model} (already installed)"
            ((skipped++)) || true
        else
            pull_model "$model"
            ((pulled++)) || true
        fi
    done

    for dep in "${DEPRECATED[@]}"; do
        local found=false
        for inst in "${INSTALLED[@]}"; do
            if [[ "$inst" == "$dep" ]] || [[ "${inst%%:*}" == "${dep%%:*}" ]]; then
                found=true
                break
            fi
        done
        if $found; then
            remove_model "$dep"
            ((removed++)) || true
        fi
    done

    log "=== Sync complete: pulled=${pulled} skipped=${skipped} removed=${removed} ==="
}

main "$@"
