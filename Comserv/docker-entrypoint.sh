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

# Create workshop files directory if NFS mount exists
WORKSHOP_DIR="/data/apis/workshop_files"
if [ -d "/data/apis" ]; then
  echo "Creating workshop files directory: $WORKSHOP_DIR"
  mkdir -p "$WORKSHOP_DIR"
  chmod 755 "$WORKSHOP_DIR"
  echo "✓ Workshop files directory ready at $WORKSHOP_DIR"
else
  echo "⚠ Warning: NFS mount /data/apis not available - workshop file uploads will use fallback directory"
fi

# Log the port configuration
PORT=${WEB_PORT:-3000}
echo "Starting Comserv with WEB_PORT=$PORT, CATALYST_ENV=${CATALYST_ENV:-production}, DEBUG=${CATALYST_DEBUG:-0}"

# Start supervisord with both file and stderr logging
# The -n flag makes supervisord stay in foreground and log to stderr
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf -n
