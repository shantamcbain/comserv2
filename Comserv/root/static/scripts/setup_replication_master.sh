#!/bin/bash
# CSC - Configure current production (192.168.1.198) as MySQL + PostgreSQL replication source
# Run this script ON the current production server (192.168.1.198)
# Then run setup_replication_replica.sh on new-prod (192.168.1.20) and dev (192.168.1.21)

REPL_USER="repl_csc"
REPL_HOST_RANGE="192.168.1.%"

echo "========================================"
echo "  CSC Replication Master Setup"
echo "  $(date)"
echo "========================================"
echo ""
echo "This server will become the replication SOURCE for:"
echo "  -> New production: 192.168.1.20"
echo "  -> Dev (via chain): 192.168.1.21"
echo ""

read -rsp "Enter a password for replication user '$REPL_USER': " REPL_PASS
echo ""
if [ -z "$REPL_PASS" ]; then
    echo "ERROR: Replication password cannot be empty."
    exit 1
fi

echo ""
echo "=== MySQL: Enabling Binary Logging ==="

MYSQL_CNF="/etc/mysql/mysql.conf.d/mysqld.cnf"
if [ ! -f "$MYSQL_CNF" ]; then
    MYSQL_CNF="/etc/mysql/my.cnf"
fi

if grep -q "^server-id" "$MYSQL_CNF" 2>/dev/null; then
    echo "server-id already set in $MYSQL_CNF"
else
    echo "" >> "$MYSQL_CNF"
    echo "server-id         = 1" >> "$MYSQL_CNF"
    echo "log_bin           = /var/log/mysql/mysql-bin.log" >> "$MYSQL_CNF"
    echo "binlog_format     = ROW" >> "$MYSQL_CNF"
    echo "expire_logs_days  = 7" >> "$MYSQL_CNF"
    echo "max_binlog_size   = 100M" >> "$MYSQL_CNF"
    echo "Added binary log settings to $MYSQL_CNF"
fi

systemctl restart mysql
sleep 3

echo ""
echo "=== MySQL: Creating Replication User ==="

mysql -u root <<SQL
CREATE USER IF NOT EXISTS '${REPL_USER}'@'${REPL_HOST_RANGE}' IDENTIFIED WITH mysql_native_password BY '${REPL_PASS}';
GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'${REPL_HOST_RANGE}';
FLUSH PRIVILEGES;
SQL

echo ""
echo "=== MySQL: Master Status ==="
echo "IMPORTANT: Note the File and Position values below — you will need them for the replica setup."
echo ""
mysql -u root -e "SHOW MASTER STATUS\G"

echo ""
echo "=== PostgreSQL: Enabling Streaming Replication ==="

PG_VERSION=$(ls /etc/postgresql/ | sort -V | tail -1)
PG_CONF="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
PG_HBA="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"

if [ -z "$PG_VERSION" ]; then
    echo "WARNING: PostgreSQL not found, skipping PG setup."
else
    sed -i "s/^#wal_level.*/wal_level = replica/" "$PG_CONF"
    sed -i "s/^wal_level.*/wal_level = replica/" "$PG_CONF"

    sed -i "s/^#max_wal_senders.*/max_wal_senders = 10/" "$PG_CONF"
    sed -i "s/^max_wal_senders.*/max_wal_senders = 10/" "$PG_CONF"

    sed -i "s/^#wal_keep_size.*/wal_keep_size = 512/" "$PG_CONF"
    sed -i "s/^#wal_keep_segments.*/wal_keep_segments = 64/" "$PG_CONF"

    if ! grep -q "^wal_level" "$PG_CONF"; then
        echo "wal_level = replica"      >> "$PG_CONF"
        echo "max_wal_senders = 10"    >> "$PG_CONF"
        echo "wal_keep_size = 512"     >> "$PG_CONF"
    fi

    if ! grep -q "replication.*192.168.1" "$PG_HBA"; then
        echo "host    replication     ${REPL_USER}    192.168.1.0/24    md5" >> "$PG_HBA"
    fi

    sudo -u postgres psql <<SQL
CREATE USER IF NOT EXISTS ${REPL_USER} REPLICATION LOGIN ENCRYPTED PASSWORD '${REPL_PASS}';
SQL

    systemctl restart postgresql
    sleep 3

    echo "PostgreSQL configured for streaming replication."
    echo "  Replication user: $REPL_USER"
fi

echo ""
echo "========================================"
echo "  Master Setup Complete"
echo "========================================"
echo ""
echo "NEXT STEPS — on new-prod (192.168.1.20) run:"
echo "  sudo bash /media/csc/scripts/setup_replication_replica.sh"
echo "  Role: new-prod | Master host: $(hostname -I | awk '{print $1}')"
echo "  Replication user: $REPL_USER"
echo "  Replication password: (the one you just set)"
echo ""
echo "After new-prod is running, on dev (192.168.1.21) run the same script:"
echo "  Role: dev | Master host: 192.168.1.20"
