#!/bin/bash
# CSC - Configure this server as a MySQL + PostgreSQL replication REPLICA
#
# Replication chain:
#   current-prod (192.168.1.198)  <-- run setup_replication_master.sh there first
#       -> new-prod  (192.168.1.20)   [role: new-prod]  replicates everything
#           -> dev   (192.168.1.21)   [role: dev]        filtered schema changes
#
# Run this on each replica after running setup_replication_master.sh on the source.

DEPLOY_DIR="/opt/csc-db"

echo "========================================"
echo "  CSC Replication Replica Setup"
echo "  $(date)"
echo "========================================"
echo ""

echo "Which role is this server?"
echo "  1) new-prod  — full replica of 192.168.1.198 (current production)"
echo "  2) dev       — filtered replica of new-prod (192.168.1.20)"
echo ""
read -rp "Enter 1 or 2: " ROLE_CHOICE

case "$ROLE_CHOICE" in
    1)
        ROLE="new-prod"
        SERVER_ID=2
        MASTER_HOST="192.168.1.198"
        MASTER_MYSQL_PORT=3306
        MASTER_PG_PORT=5432
        FILTER_DBS=""
        ;;
    2)
        ROLE="dev"
        SERVER_ID=3
        MASTER_HOST="192.168.1.20"
        MASTER_MYSQL_PORT=3307
        MASTER_PG_PORT=5433
        read -rp "Filter specific databases only? (leave blank to replicate all): " FILTER_DBS
        ;;
    *)
        echo "ERROR: Invalid choice."
        exit 1
        ;;
esac

read -rp "Replication user name [repl_csc]: " REPL_USER
REPL_USER="${REPL_USER:-repl_csc}"
read -rsp "Replication user password: " REPL_PASS
echo ""

if [ -z "$REPL_PASS" ]; then
    echo "ERROR: Replication password cannot be empty."
    exit 1
fi

if [ ! -d "$DEPLOY_DIR" ]; then
    echo "ERROR: $DEPLOY_DIR not found. Run setup_docker_db.sh first."
    exit 1
fi

echo ""
echo "=== MySQL: Writing Replication Config ==="

REPL_CNF="$DEPLOY_DIR/conf/mysql/replication.cnf"
cat > "$REPL_CNF" <<EOF
[mysqld]
server-id              = ${SERVER_ID}
relay-log              = /var/log/mysql/relay-bin
log_bin                = /var/log/mysql/mysql-bin.log
binlog_format          = ROW
log_slave_updates      = 1
read_only              = 0
expire_logs_days       = 7
EOF

if [ -n "$FILTER_DBS" ]; then
    echo "" >> "$REPL_CNF"
    for db in $FILTER_DBS; do
        echo "replicate-do-db        = $db" >> "$REPL_CNF"
    done
    echo "# Dev: only schema-level DDL events replicate; DML data stays independent" >> "$REPL_CNF"
fi

echo "Written: $REPL_CNF"
cat "$REPL_CNF"

echo ""
echo "=== MySQL: Restarting Docker Container ==="
cd "$DEPLOY_DIR"
docker compose restart mysql
sleep 8

echo ""
echo "=== MySQL: Configuring Replica ==="

MYSQL_CMD="docker exec csc-mysql mysql -u root -p\${MYSQL_ROOT_PASSWORD}"

docker exec csc-mysql mysql -u root -p"$(grep MYSQL_ROOT_PASSWORD "$DEPLOY_DIR/.env" | cut -d= -f2)" <<SQL
STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO
    MASTER_HOST='${MASTER_HOST}',
    MASTER_PORT=${MASTER_MYSQL_PORT},
    MASTER_USER='${REPL_USER}',
    MASTER_PASSWORD='${REPL_PASS}',
    MASTER_AUTO_POSITION=1;
START SLAVE;
SQL

echo ""
echo "=== MySQL: Replica Status ==="
docker exec csc-mysql mysql -u root -p"$(grep MYSQL_ROOT_PASSWORD "$DEPLOY_DIR/.env" | cut -d= -f2)" \
    -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_Error|Master_Host"

echo ""
echo "=== PostgreSQL: Configuring Streaming Replica ==="

PG_DATA_DIR=$(docker inspect csc-postgres --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)

if [ -z "$PG_DATA_DIR" ]; then
    echo "WARNING: Could not find PostgreSQL data dir — using docker volume approach."
fi

docker exec csc-postgres bash -c "
    psql -U postgres -c \"SELECT pg_is_in_recovery();\" 2>/dev/null
" && PG_ALREADY_REPLICA=1 || PG_ALREADY_REPLICA=0

echo ""
echo "Setting up PostgreSQL streaming replication from $MASTER_HOST..."
echo "This will STOP the postgres container, wipe its data dir, and run pg_basebackup."
echo ""
read -rp "Continue? (y/N): " pg_confirm
if [[ ! "$pg_confirm" =~ ^[Yy] ]]; then
    echo "Skipping PostgreSQL replication setup."
else
    cd "$DEPLOY_DIR"
    docker compose stop postgres

    PGDATA_VOLUME=$(docker volume ls -q | grep postgres_data | head -1)
    if [ -n "$PGDATA_VOLUME" ]; then
        docker volume rm "$PGDATA_VOLUME" 2>/dev/null || true
    fi

    docker run --rm \
        -e PGPASSWORD="$REPL_PASS" \
        -v "${DEPLOY_DIR}/pgdata:/var/lib/postgresql/data" \
        postgres:16 \
        pg_basebackup \
            -h "$MASTER_HOST" \
            -p "$MASTER_PG_PORT" \
            -U "$REPL_USER" \
            -D /var/lib/postgresql/data \
            -Fp -Xs -P -R

    cat >> "${DEPLOY_DIR}/pgdata/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=${MASTER_HOST} port=${MASTER_PG_PORT} user=${REPL_USER} password=${REPL_PASS}'
promote_trigger_file = '/tmp/pg_promote'
EOF

    if [ "$ROLE" = "dev" ] && [ -n "$FILTER_DBS" ]; then
        echo "# Note: PostgreSQL streaming replication replicates all data." >> "${DEPLOY_DIR}/pgdata/postgresql.auto.conf"
        echo "# Use publication/subscription (logical replication) for per-DB filtering." >> "${DEPLOY_DIR}/pgdata/postgresql.auto.conf"
    fi

    COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yml"
    if ! grep -q "pgdata" "$COMPOSE_FILE"; then
        sed -i '/postgres_data:\/var\/lib\/postgresql\/data/a\      - ./pgdata:/var/lib/postgresql/data' "$COMPOSE_FILE" 2>/dev/null || true
    fi

    docker compose up -d postgres
    sleep 5

    echo ""
    echo "=== PostgreSQL: Replica Status ==="
    docker exec csc-postgres psql -U postgres -c "SELECT pg_is_in_recovery(), now();" 2>/dev/null || echo "Waiting for postgres to start..."
fi

echo ""
echo "========================================"
echo "  Replica Setup Complete ($ROLE)"
echo "========================================"
echo ""
echo "Replication chain:"
if [ "$ROLE" = "new-prod" ]; then
    echo "  192.168.1.198 (source) -> 192.168.1.20 (new-prod) [this server]"
    echo ""
    echo "NEXT: On dev (192.168.1.21) run this script again and choose role: dev"
else
    echo "  192.168.1.198 (source) -> 192.168.1.20 (new-prod) -> 192.168.1.21 (dev) [this server]"
fi
echo ""
echo "MySQL status check:  docker exec csc-mysql mysql -uroot -p -e 'SHOW SLAVE STATUS\\G'"
echo "PG replication check: docker exec csc-postgres psql -U postgres -c 'SELECT * FROM pg_stat_replication;'"
