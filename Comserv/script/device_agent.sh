#!/usr/bin/env bash
# device_agent.sh — Comserv Hardware Monitor remote agent
#
# Collects disk space, CPU load, memory, and temperatures from this device
# and POSTs them to the Comserv Hardware Monitor ingest endpoint.
#
# SETUP (run once on each server-room device):
#   1. Copy this script to the target machine (e.g. /usr/local/bin/device_agent.sh)
#   2. chmod +x /usr/local/bin/device_agent.sh
#   3. Set INGEST_URL and INGEST_TOKEN below (or export as environment variables)
#   4. Add a cron job:  */5 * * * * /usr/local/bin/device_agent.sh
#
# REQUIREMENTS: bash, curl (or wget), df, awk — standard on any Linux/FreeBSD

# ---------------------------------------------------------------------------
# Configuration — override via environment or edit here
# ---------------------------------------------------------------------------
INGEST_URL="${INGEST_URL:-http://192.168.1.199:3001/admin/hardware_monitor/ingest}"
INGEST_TOKEN="${INGEST_TOKEN:-changeme}"
HOSTNAME_OVERRIDE="${HOSTNAME_OVERRIDE:-}"    # leave blank to auto-detect

# ---------------------------------------------------------------------------
HOSTNAME="${HOSTNAME_OVERRIDE:-$(hostname -s 2>/dev/null || hostname)}"

metrics_json=""

# Helper: append a metric to the JSON array
add_metric() {
    local name="$1" value="$2" unit="$3" text="$4"
    local entry
    if [ -n "$text" ]; then
        entry="{\"name\":\"${name}\",\"value\":${value},\"unit\":\"${unit}\",\"text\":\"${text}\"}"
    else
        entry="{\"name\":\"${name}\",\"value\":${value},\"unit\":\"${unit}\"}"
    fi
    if [ -z "$metrics_json" ]; then
        metrics_json="$entry"
    else
        metrics_json="${metrics_json},${entry}"
    fi
}

# ---------------------------------------------------------------------------
# Disk space — all real mounted filesystems
# ---------------------------------------------------------------------------
while IFS= read -r line; do
    [[ "$line" =~ ^Filesystem ]] && continue
    read -r dev total_k used_k avail_k pct_str mount <<< "$line"
    [ -z "$mount" ] && continue
    [[ "$dev" =~ ^(tmpfs|devtmpfs|udev|overlay|shm|squashfs|none|loop) ]] && continue
    pct="${pct_str//%/}"
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    safe="${mount//\//_}"
    [ -z "$safe" ] && safe="root"
    total_mb=$(( total_k / 1024 ))
    free_mb=$(( avail_k / 1024 ))
    add_metric "disk_used_pct${safe}" "$pct"      "%" "$dev"
    add_metric "disk_total_mb${safe}" "$total_mb" "MB" "$dev"
    add_metric "disk_free_mb${safe}"  "$free_mb"  "MB" "$dev"
done < <(df -Pk 2>/dev/null || df -k 2>/dev/null)

# ---------------------------------------------------------------------------
# CPU load
# ---------------------------------------------------------------------------
if [ -f /proc/loadavg ]; then
    read -r l1 l5 l15 _ < /proc/loadavg
    cpus=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
    pct=$(awk "BEGIN{printf \"%.1f\", ($l1/$cpus)*100}")
    add_metric "cpu_load_1m"  "$l1"  "load" ""
    add_metric "cpu_load_5m"  "$l5"  "load" ""
    add_metric "cpu_load_15m" "$l15" "load" ""
    add_metric "cpu_load_pct" "$pct" "%"    ""
elif command -v sysctl >/dev/null 2>&1; then
    avg=$(sysctl -n vm.loadavg 2>/dev/null)
    l1=$(echo "$avg" | awk '{print $2}')
    cpus=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
    pct=$(awk "BEGIN{printf \"%.1f\", ($l1/$cpus)*100}")
    add_metric "cpu_load_pct" "$pct" "%" ""
fi

# ---------------------------------------------------------------------------
# Memory
# ---------------------------------------------------------------------------
if [ -f /proc/meminfo ]; then
    mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    [ -z "$mem_avail" ] && mem_avail=$(awk '/^MemFree:/{print $2}' /proc/meminfo)
    swap_total=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
    swap_free=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
    if [ -n "$mem_total" ] && [ "$mem_total" -gt 0 ]; then
        mem_pct=$(awk "BEGIN{printf \"%.1f\", (($mem_total-$mem_avail)/$mem_total)*100}")
        total_mb=$(( mem_total / 1024 ))
        add_metric "mem_total_mb"  "$total_mb" "MB" ""
        add_metric "mem_used_pct"  "$mem_pct"  "%"  ""
    fi
    if [ -n "$swap_total" ] && [ "$swap_total" -gt 0 ]; then
        swap_pct=$(awk "BEGIN{printf \"%.1f\", (($swap_total-$swap_free)/$swap_total)*100}")
        add_metric "swap_used_pct" "$swap_pct" "%" ""
    fi
fi

# ---------------------------------------------------------------------------
# Uptime
# ---------------------------------------------------------------------------
if [ -f /proc/uptime ]; then
    up_secs=$(awk '{printf "%d", $1}' /proc/uptime)
    add_metric "uptime_seconds" "$up_secs" "seconds" ""
fi

# ---------------------------------------------------------------------------
# CPU temperature (Linux hwmon / thermal_zone)
# ---------------------------------------------------------------------------
for zone_path in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$zone_path" ] || continue
    raw=$(cat "$zone_path" 2>/dev/null)
    [[ "$raw" =~ ^[0-9]+$ ]] || continue
    [ "$raw" -gt 0 ] || continue
    c=$(awk "BEGIN{printf \"%.1f\", $raw/1000}")
    type_path="${zone_path%temp}type"
    label="cpu_temp"
    [ -f "$type_path" ] && label="$(cat "$type_path" 2>/dev/null | tr '[:upper:]' '[:lower:]')_temp"
    add_metric "$label" "$c" "C" ""
done

# ---------------------------------------------------------------------------
# POST to ingest endpoint
# ---------------------------------------------------------------------------
payload="{\"hostname\":\"${HOSTNAME}\",\"metrics\":[${metrics_json}]}"

if command -v curl >/dev/null 2>&1; then
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "X-Ingest-Token: ${INGEST_TOKEN}" \
        --data-raw "$payload" \
        --connect-timeout 10 \
        "$INGEST_URL" 2>&1)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | head -n -1)
    if [ "$http_code" != "200" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [device_agent] WARN: ingest returned HTTP $http_code — $body" >&2
        exit 1
    fi
elif command -v wget >/dev/null 2>&1; then
    body=$(wget -q -O- \
        --header="Content-Type: application/json" \
        --header="X-Ingest-Token: ${INGEST_TOKEN}" \
        --post-data="$payload" \
        "$INGEST_URL" 2>&1)
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [device_agent] ERROR: curl or wget required" >&2
    exit 2
fi
