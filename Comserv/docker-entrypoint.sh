#!/bin/bash
set -e

# Use environment variable with fallback for safety
CATALYST_HOME=${CATALYST_HOME:-/opt/comserv}

# ============================================================================
# Phase 0.5: K8s Secrets Migration - Import db_config.json to K8s Secret
# ============================================================================
# Enhanced K8s Secret migration with graceful fallback and diagnostics

CONFIG_SOURCE="unknown"
K8S_ENVIRONMENT=false

if [ -f "$CATALYST_HOME/db_config.json" ]; then
  echo "Legacy db_config.json detected at $CATALYST_HOME/db_config.json"
  CONFIG_SOURCE="db_config.json"
  
  if command -v kubectl &> /dev/null; then
    K8S_ENVIRONMENT=true
    echo "✓ kubectl available - K8s environment detected"
    
    # Attempt to create/update K8s Secret with better error handling
    if kubectl create secret generic dbi-secrets \
      --from-file=dbi="$CATALYST_HOME/db_config.json" \
      --dry-run=client -o yaml | kubectl apply -f - 2>&1 | tee /tmp/k8s_secret_output.log; then
      
      echo "✓ Successfully imported db_config.json to K8s Secret 'dbi-secrets'"
      
      # Verify Secret was created/updated
      if kubectl get secret dbi-secrets -o jsonpath='{.data.dbi}' &>/dev/null; then
        echo "✓ K8s Secret 'dbi-secrets' verified and accessible"
        
        # Only delete db_config.json if we're certain the secret exists and is readable
        if kubectl get secret dbi-secrets -o jsonpath='{.data.dbi}' &>/dev/null; then
          rm "$CATALYST_HOME/db_config.json"
          echo "✓ Deleted legacy db_config.json (replaced by K8s Secret)"
          CONFIG_SOURCE="K8s Secret"
        else
          echo "⚠ Warning: Could not verify K8s Secret readability. Keeping db_config.json for fallback."
        fi
      else
        echo "⚠ Warning: K8s Secret created but could not verify. Keeping db_config.json for fallback."
      fi
    else
      echo "⚠ Warning: Failed to create/update K8s Secret. Keeping db_config.json for fallback."
      echo "Error details saved to /tmp/k8s_secret_output.log"
    fi
  else
    echo "⚠ kubectl not available (not in K8s environment)"
    echo "  db_config.json will be used directly by the application"
    CONFIG_SOURCE="db_config.json (non-K8s fallback)"
  fi
else
  echo "No db_config.json found at $CATALYST_HOME/db_config.json"
  
  if command -v kubectl &> /dev/null; then
    K8S_ENVIRONMENT=true
    echo "✓ kubectl available - K8s environment detected"
    
    # Check if K8s Secret already exists
    if kubectl get secret dbi-secrets -o jsonpath='{.data.dbi}' &>/dev/null 2>&1; then
      echo "✓ Using existing K8s Secret 'dbi-secrets'"
      CONFIG_SOURCE="K8s Secret"
    else
      echo "⚠ No db_config.json and no K8s Secret found"
      echo "  Configuration must be provided via:"
      echo "    - Environment variables (COMSERV_DB_*)"
      echo "    - K8s ConfigMap/Secret mounted at /opt/secrets/ or /var/run/secrets/"
    fi
  else
    echo "⚠ No configuration file or K8s environment available"
    echo "  Configuration must be provided via environment variables (COMSERV_DB_*)"
  fi
fi

echo "Configuration source: $CONFIG_SOURCE"

# ============================================================================
# Validate DBI Configuration
# ============================================================================
if [ -n "$DB_HOST" ]; then
  echo "Database configuration detected: DB_HOST=$DB_HOST, DB_USER=$DB_USER"
else
  echo "⚠ Warning: DB_HOST not set. Using fallback from db_config.json or K8s Secret."
fi

# Clean up stale supervisor socket and pid files
rm -f /var/run/supervisor.sock /var/run/supervisord.pid

# Ensure log, session, and backup directories exist and are writable by comserv user
mkdir -p ${CATALYST_HOME}/root/log ${CATALYST_HOME}/root/session ${CATALYST_HOME}/backups /var/log/supervisor
chmod 755 ${CATALYST_HOME}/root/log ${CATALYST_HOME}/root/session ${CATALYST_HOME}/backups /var/log/supervisor
chown -R comserv:comserv ${CATALYST_HOME}/root/log ${CATALYST_HOME}/root/session ${CATALYST_HOME}/backups

# Symlink ${CATALYST_HOME}/logs to ${CATALYST_HOME}/root/log so logs write to persistent volume
if [ ! -L "${CATALYST_HOME}/logs" ]; then
    if [ -d "${CATALYST_HOME}/logs" ]; then
        echo "Moving existing logs to persistent volume directory..."
        cp -a ${CATALYST_HOME}/logs/. "${CATALYST_HOME}/root/log/" 2>/dev/null || true
        rm -rf "${CATALYST_HOME}/logs"
    fi
    ln -s "${CATALYST_HOME}/root/log" "${CATALYST_HOME}/logs"
    echo "✓ Symlinked ${CATALYST_HOME}/logs to ${CATALYST_HOME}/root/log"
fi

# Ensure Catalyst Session::Store::File directory exists and is writable by comserv user.
# COMSERV_SESSION_DIR is the session FILES directory (e.g. /tmp/comserv/session).
SESSION_DIR="${COMSERV_SESSION_DIR:-/tmp/comserv/session}"
mkdir -p "$SESSION_DIR"
chmod 700 "$SESSION_DIR"
chown comserv:comserv "$SESSION_DIR" 2>/dev/null || true

# Create base supervisord.conf if missing or empty
if [ ! -s /etc/supervisor/supervisord.conf ]; then
    mkdir -p /etc/supervisor/conf.d
    cat > /etc/supervisor/supervisord.conf << 'EOFBASE'
[unix_http_server]
file=/var/run/supervisor.sock

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisord]
logfile=/var/log/supervisor/supervisord.log
loglevel=debug
pidfile=/var/run/supervisord.pid
nodaemon=true
user=root
silent=false

[include]
files=/etc/supervisor/conf.d/*.conf
EOFBASE
fi

# Generate supervisor config with dynamic port
bash ${CATALYST_HOME}/create-supervisor-config.sh

# Start cron for logrotate (prevents disk space exhaustion)
if command -v cron &> /dev/null; then
  echo "Starting cron for log rotation..."
  service cron start || /usr/sbin/cron
  echo "✓ Cron started for logrotate"
else
  echo "⚠ Warning: cron not available - log rotation disabled"
fi

# Bootstrap whisper_venv on named volume if not yet installed — runs in background
# so it does not block app startup or health checks
if [ ! -f "/opt/comserv/whisper_venv/bin/python3" ]; then
  echo "Whisper venv not found — bootstrapping in background (first-run only)..."
  (
    if command -v python3 &>/dev/null; then
      python3 -m venv /opt/comserv/whisper_venv >> /tmp/whisper_install.log 2>&1 && \
      /opt/comserv/whisper_venv/bin/pip install --no-cache-dir \
        torch --index-url https://download.pytorch.org/whl/cpu \
        openai-whisper >> /tmp/whisper_install.log 2>&1 && \
      echo "✓ Whisper install complete" >> /tmp/whisper_install.log || \
      echo "⚠ Whisper install failed — check /tmp/whisper_install.log" >> /tmp/whisper_install.log
    fi
  ) &
  echo "  Whisper install started in background — see /tmp/whisper_install.log"
else
  echo "✓ Whisper venv ready at /opt/comserv/whisper_venv"
fi

# Create workshop files directory on shared volume
if [ "${SKIP_NFS_SETUP}" != "1" ]; then
  WORKSHOP_DIR="/data/nfs/workshop_files"
  if [ -d "/data/nfs" ]; then
    echo "✓ Using existing NFS mount at /data/nfs"
    if [ ! -d "$WORKSHOP_DIR" ]; then
        echo "Creating workshop files directory: $WORKSHOP_DIR"
        mkdir -p "$WORKSHOP_DIR"
        chmod 775 "$WORKSHOP_DIR" 2>/dev/null || true
        chown comserv:comserv "$WORKSHOP_DIR" 2>/dev/null || true
    fi
    NFS_LOG_DIR="/data/nfs/logs"
    if [ ! -d "$NFS_LOG_DIR" ]; then
        echo "Creating NFS log directory: $NFS_LOG_DIR"
        mkdir -p "$NFS_LOG_DIR"
        chmod 775 "$NFS_LOG_DIR" 2>/dev/null || true
        chown comserv:comserv "$NFS_LOG_DIR" 2>/dev/null || true
    fi
    echo "✓ NFS log directory ready: $NFS_LOG_DIR"
  else
    echo "⚠ Warning: Workshop volume /data/nfs not available - workshop file uploads will use fallback directory"
  fi
else
  echo "✓ Skipping NFS setup (SKIP_NFS_SETUP=1) - using existing NFS mount"
fi

# Configure log rotation to prevent disk space issues
echo "Configuring log rotation..."
cat > /etc/logrotate.d/catalyst <<'LOGROTATE_EOF'
/opt/comserv/root/log/*.log {
    su comserv comserv
    daily
    dateext
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    maxsize 100M
    create 0644 comserv comserv
    sharedscripts
    postrotate
        supervisorctl status > /dev/null 2>&1 || true
        NFS_ARCHIVE=/data/nfs/logs/archive
        [ -d "/data/nfs" ] || NFS_ARCHIVE=/home/shanta/nfs/logs/archive
        [ -d "$NFS_ARCHIVE" ] || mkdir -p "$NFS_ARCHIVE" 2>/dev/null || true
        find /opt/comserv/root/log -name "*.log-*.gz" -mmin -5 \
            -exec cp -p {} "$NFS_ARCHIVE/" \; 2>/dev/null || true
    endscript
}

/opt/comserv/root/Documentation/session_history/*.log {
    su comserv comserv
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
}
LOGROTATE_EOF
echo "✓ Log rotation configured"

# Log the port configuration
PORT=${WEB_PORT:-3000}
echo "Starting Comserv with WEB_PORT=$PORT, CATALYST_ENV=${CATALYST_ENV:-production}, DEBUG=${CATALYST_DEBUG:-0}"

# Start supervisord with both file and stderr logging
# The -n flag makes supervisord stay in foreground and log to stderr
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf -n
