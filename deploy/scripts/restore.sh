#!/usr/bin/env sh
set -eu
# Restores into an independently created database/MySQL instance only.
# Usage: MYSQL_HOST=... MYSQL_USER=... MYSQL_PASSWORD=... MYSQL_DATABASE=t5_restore ./restore.sh backup.sql.gz
FILE=${1:?usage: restore.sh backup.sql.gz}
: "${MYSQL_HOST:?set MYSQL_HOST}"
: "${MYSQL_PORT:=3306}"
: "${MYSQL_USER:?set MYSQL_USER}"
: "${MYSQL_PASSWORD:?set MYSQL_PASSWORD}"
: "${MYSQL_DATABASE:?set MYSQL_DATABASE}"
[ -f "$FILE.sha256" ] && sha256sum -c "$FILE.sha256"
MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" --user="$MYSQL_USER" \
  -e "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"
gunzip -c "$FILE" | MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" --user="$MYSQL_USER" "$MYSQL_DATABASE"
MYSQL_PWD="$MYSQL_PASSWORD" mysql --host="$MYSQL_HOST" --port="$MYSQL_PORT" --user="$MYSQL_USER" "$MYSQL_DATABASE" \
  -e "SELECT COUNT(*) AS entities FROM sync_entities; SELECT sync_generation FROM accounts WHERE id=1;"
echo "Restore completed. Rotate generation and run client bootstrap verification."
