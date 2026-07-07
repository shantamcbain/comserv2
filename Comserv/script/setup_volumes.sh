#!/bin/bash
# setup_volumes.sh
# Runs inside the Docker container on startup.
# Populates empty named volumes with files from the image.
set -e

# If the static volume is mounted at /opt/comserv/root/static and is empty,
# copy the image's static files into it so CSS/JS are available.
if [ -d /opt/comserv/root/static ]; then
    contents=$(ls -A /opt/comserv/root/static 2>/dev/null)
    if [ -z "$contents" ]; then
        echo "[setup_volumes] Populating empty /opt/comserv/root/static from image..."
        # The image has static files at /opt/comserv/root/static from the Docker build
        # If they exist somewhere else, copy them into the volume
        src="/opt/comserv/root/static"
        if [ -d "$src" ]; then
            # Check if it's truly empty or just the volume hiding the files
            # Use tar to copy without changing ownership
            tar cf - -C "$src" . 2>/dev/null | tar xf - -C /opt/comserv/root/static 2>/dev/null || true
            chmod -R 755 /opt/comserv/root/static 2>/dev/null || true
            echo "[setup_volumes] Static files populated."
        fi
    fi
fi

# Same for cache, userprefs, sessions directories
for dir in cache userprefs sessions; do
    target="/opt/comserv/root/$dir"
    if [ -d "$target" ]; then
        contents=$(ls -A "$target" 2>/dev/null)
        if [ -z "$contents" ]; then
            echo "[setup_volumes] $target is empty — not populating (runtime data created by app)"
        fi
    fi
done

echo "[setup_volumes] Volume setup complete."