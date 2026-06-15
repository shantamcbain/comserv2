#!/bin/bash
# One-time / repair NFS mount on production1 (and production2 with env overrides).
# Mounts 192.168.1.175:/mnt/data so deploy.sh passes NFS checks and Docker uses real NFS.
set -euo pipefail

NFS_SERVER="${NFS_SERVER:-192.168.1.175}"
NFS_EXPORT="${NFS_EXPORT:-/mnt/data}"
NFS_MOUNT="${NFS_MOUNT:-/home/ubuntu/nfs}"
WORKSHOP_DIR="${WORKSHOP_DIR:-${NFS_MOUNT}/comserv-workshop}"
FSTAB_LINE="${NFS_SERVER}:${NFS_EXPORT} ${NFS_MOUNT} nfs defaults,_netdev,nofail 0 0"

log() { echo "[$(date '+%F %T')] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

log "=== Comserv production NFS setup ==="
log "Server: ${NFS_SERVER}:${NFS_EXPORT} -> ${NFS_MOUNT}"

if ! command -v mount.nfs &>/dev/null; then
    log "Installing nfs-common..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-common
fi

if ! nc -z -w 3 "$NFS_SERVER" 2049 2>/dev/null; then
    echo "ERROR: NFS server ${NFS_SERVER}:2049 not reachable" >&2
    exit 1
fi

mkdir -p "$NFS_MOUNT" "$WORKSHOP_DIR"

if ! grep -qF "${NFS_SERVER}:${NFS_EXPORT}" /etc/fstab 2>/dev/null; then
    log "Adding fstab entry"
    echo "$FSTAB_LINE" >> /etc/fstab
else
    log "fstab entry already present"
fi

if mountpoint -q "$NFS_MOUNT"; then
    log "Already mounted at ${NFS_MOUNT}"
else
    log "Mounting NFS..."
    mount "$NFS_MOUNT"
fi

if ! mount | grep -Eq " on ${NFS_MOUNT} type nfs"; then
    echo "ERROR: mount succeeded but ${NFS_MOUNT} is not NFS" >&2
    mount | grep "$NFS_MOUNT" || true
    exit 1
fi

log "NFS mounted:"
df -h "$NFS_MOUNT" | tail -1

# Migrate old local-root workshop data into NFS (production was using /var/lib/comserv/data).
# Skip if NFS workshop already has content (re-runs / reboots).
if find "$WORKSHOP_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | grep -q .; then
    log "Workshop dir already populated on NFS — skipping legacy migration"
else
    for LEGACY in /var/lib/comserv/data /home/ubuntu/comserv-workshop; do
        if [ -d "$LEGACY" ] && [ "$LEGACY" != "$WORKSHOP_DIR" ]; then
            if find "$LEGACY" -mindepth 1 -maxdepth 1 2>/dev/null | grep -q .; then
                log "Migrating legacy workshop data: $LEGACY -> $WORKSHOP_DIR (may take several minutes)"
                mkdir -p "$WORKSHOP_DIR"
                rsync -a "$LEGACY/" "$WORKSHOP_DIR/" 2>/dev/null || cp -a "$LEGACY/." "$WORKSHOP_DIR/"
                log "Legacy copy complete (original left in place: $LEGACY)"
                break
            fi
        fi
    done
fi

mkdir -p "${NFS_MOUNT}/logs" "$WORKSHOP_DIR"

log "=== NFS setup complete ==="
log "Workshop path for deploy: $WORKSHOP_DIR"
log "Next: run deploy.sh (full) or DEPLOY_MODE=full /opt/comserv/Comserv/deploy.sh"