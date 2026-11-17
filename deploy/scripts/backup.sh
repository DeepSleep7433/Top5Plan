#!/usr/bin/env sh
set -eu
# Run from the deploy directory. Produces a consistent InnoDB logical backup,
# a SHA-256 checksum, and a manifest. Do not treat the backup as valid until
# restore verification has passed in an independent environment.
ENV_FILE=${ENV_FILE:-.env}
read_env() {
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
}
MYSQL_HOST=${MYSQL_HOST:-$(read_env MYSQL_HOST)}
MYSQL_PORT=${MYSQL_PORT:-$(read_env MYSQL_PORT)}
MYSQL_USER=${MYSQL_USER:-$(read_env MYSQL_USER)}
MYSQL_PASSWORD=${MYSQL_PASSWORD:-$(read_env MYSQL_PASSWORD)}
MYSQL_DATABASE=${MYSQL_DATABASE:-$(read_env MYSQL_DATABASE)}
: "${MYSQL_HOST:=mysql}"
: "${MYSQL_PORT:=3306}"
: "${MYSQL_USER:=t5}"
: "${MYSQL_DATABASE:=t5}"
: "${MYSQL_PASSWORD:?set MYSQL_PASSWORD}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT_DIR=${BACKUP_DIR:-backups}
mkdir -p "$OUT_DIR"
FILE="$OUT_DIR/t5-$STAMP.sql.gz"
MYSQL_PWD="$MYSQL_PASSWORD" mysqldump \
  --host="$MYSQL_HOST" --port="$MYSQL_PORT" --user="$MYSQL_USER" \
  --single-transaction --quick --routines --triggers --events \
  --set-gtid-purged=OFF --default-character-set=utf8mb4 \
  "$MYSQL_DATABASE" | gzip -9 > "$FILE"
sha256sum "$FILE" > "$FILE.sha256"
cat > "$FILE.manifest" <<MANIFEST
created_at_utc=$STAMP
database=$MYSQL_DATABASE
mysql_host=$MYSQL_HOST
format=mysqldump-gzip
restore_verification=REQUIRED
MANIFEST
echo "backup written: $FILE"
echo "verify independently with deploy/scripts/restore.sh in a separate MySQL instance"
