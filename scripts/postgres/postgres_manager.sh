#!/bin/bash

set -e

# =====================================================
# POSTGRES GLOBAL MANAGER
# =====================================================

DB_CONTAINER="postgres"
PG_USER="raselstr"

# BACKUP_ROOT="/home/serverbkad/srv/backups"
BACKUP_ROOT="/home/stafperbendaharaan/srv/backups"
GLOBAL_DIR="${BACKUP_ROOT}/globals"
DATABASE_DIR="${BACKUP_ROOT}/databases"
LATEST_DIR="${BACKUP_ROOT}/latest"
LOG_DIR="${BACKUP_ROOT}/logs"

RETENTION_DAYS=5

DATE=$(date +"%Y-%m-%d_%H-%M-%S")

mkdir -p "$GLOBAL_DIR"
mkdir -p "$DATABASE_DIR"
mkdir -p "$LATEST_DIR"
mkdir -p "$LOG_DIR"

# =====================================================
# CHECK CONTAINER
# =====================================================

check_container() {

    if ! docker ps --format '{{.Names}}' | grep -q "^${DB_CONTAINER}$"; then
        echo ""
        echo "ERROR: Container PostgreSQL tidak berjalan"
        exit 1
    fi
}

# =====================================================
# GET DATABASE LIST
# =====================================================

get_databases() {

docker exec "$DB_CONTAINER" \
psql -U "$PG_USER" -tAc "
SELECT datname
FROM pg_database
WHERE datistemplate = false
AND datname NOT IN ('postgres');
"
}

# =====================================================
# CLEANUP OLD BACKUP
# =====================================================

cleanup_old() {

    find "$BACKUP_ROOT" \
    -type f \
    -mtime +${RETENTION_DAYS} \
    -delete
}

# =====================================================
# BACKUP ROLES
# =====================================================

backup_roles() {

    echo "Backup Roles/User..."

    docker exec "$DB_CONTAINER" \
    pg_dumpall \
    -U "$PG_USER" \
    --globals-only \
    > "${GLOBAL_DIR}/globals_${DATE}.sql"

    cp -f \
    "${GLOBAL_DIR}/globals_${DATE}.sql" \
    "${LATEST_DIR}/globals_latest.sql"
}

# =====================================================
# BACKUP ONE DATABASE
# =====================================================

backup_database() {

    DB_NAME="$1"

    echo ""
    echo "Backup database: $DB_NAME"

    mkdir -p "${DATABASE_DIR}/${DB_NAME}"

    FILE="${DATABASE_DIR}/${DB_NAME}/${DB_NAME}_${DATE}.backup"

    docker exec "$DB_CONTAINER" \
    pg_dump \
    -U "$PG_USER" \
    -Fc \
    "$DB_NAME" \
    > "$FILE"

    gzip -f "$FILE"

    cp -f\
    "${FILE}.gz" \
    "${LATEST_DIR}/${DB_NAME}_latest.backup.gz"

    echo "OK"
}

# =====================================================
# BACKUP ALL
# =====================================================

backup_all() {

    check_container

    backup_roles

    DATABASES=$(get_databases)

    for DB in $DATABASES
    do
        backup_database "$DB"
    done

    cleanup_old

    echo ""
    echo "================================="
    echo "Backup semua database selesai"
    echo "================================="
}

# =====================================================
# BACKUP ONE
# =====================================================

backup_one() {

    read -p "Nama database: " DB

    backup_database "$DB"

    echo ""
    echo "Backup selesai"
}

# =====================================================
# RESTORE ONE DATABASE
# =====================================================

restore_one() {

    read -p "Nama database yang akan direstore: " DB

    FILE="${LATEST_DIR}/${DB}_latest.backup.gz"

    if [ ! -f "$FILE" ]; then

        echo ""
        echo "Backup tidak ditemukan:"
        echo "$FILE"
        exit 1

    fi

    echo ""
    echo "================================="
    echo "DATABASE : $DB"
    echo "FILE     : $FILE"
    echo "================================="
    echo ""

    read -p "Ketik YES untuk melanjutkan: " CONFIRM

    if [ "$CONFIRM" != "YES" ]; then
        echo "Dibatalkan"
        exit 0
    fi

    echo ""
    echo "Menutup koneksi database..."

    docker exec "$DB_CONTAINER" psql \
    -U "$PG_USER" \
    -d postgres \
    -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname='${DB}'
    AND pid <> pg_backend_pid();
    " >/dev/null

    echo "Drop database..."

    docker exec "$DB_CONTAINER" \
    dropdb \
    -U "$PG_USER" \
    --if-exists \
    "$DB"

    echo "Create database..."

    docker exec "$DB_CONTAINER" \
    createdb \
    -U "$PG_USER" \
    "$DB"

    echo "Restore..."

    gunzip -c "$FILE" \
    | docker exec -i "$DB_CONTAINER" \
    pg_restore \
    -U "$PG_USER" \
    -d "$DB" \
    --clean \
    --if-exists \
    --no-owner

    echo ""
    echo "Restore selesai"
}

# =====================================================
# RESTORE ALL DATABASES
# =====================================================

restore_all() {

    echo ""
    echo "================================="
    echo "RESTORE SEMUA DATABASE"
    echo "================================="
    echo ""

    read -p "Ketik YES untuk melanjutkan: " CONFIRM

    if [ "$CONFIRM" != "YES" ]; then
        exit 0
    fi

    for FILE in "${LATEST_DIR}"/*_latest.backup.gz
    do

        DB=$(basename "$FILE" | sed 's/_latest.backup.gz//')

        echo ""
        echo "================================="
        echo "Restore : $DB"
        echo "================================="

        docker exec "$DB_CONTAINER" psql \
        -U "$PG_USER" \
        -d postgres \
        -c "
        SELECT pg_terminate_backend(pid)
        FROM pg_stat_activity
        WHERE datname='${DB}'
        AND pid <> pg_backend_pid();
        " >/dev/null

        docker exec "$DB_CONTAINER" \
        dropdb \
        -U "$PG_USER" \
        --if-exists \
        "$DB"

        docker exec "$DB_CONTAINER" \
        createdb \
        -U "$PG_USER" \
        "$DB"

        gunzip -c "$FILE" \
        | docker exec -i "$DB_CONTAINER" \
        pg_restore \
        -U "$PG_USER" \
        -d "$DB" \
        --clean \
        --if-exists \
        --no-owner

    done

    echo ""
    echo "Restore semua database selesai"
}

# =====================================================
# RESTORE ROLES
# =====================================================

restore_roles() {

    FILE="${LATEST_DIR}/globals_latest.sql"

    if [ ! -f "$FILE" ]; then
        echo "globals_latest.sql tidak ditemukan"
        exit 1
    fi

    echo ""
    echo "Restore roles/user"

    docker exec -i "$DB_CONTAINER" \
    psql \
    -U "$PG_USER" \
    < "$FILE"

    echo "Selesai"
}

# =====================================================
# LIST BACKUP
# =====================================================

list_backup() {

    echo ""
    echo "Daftar Backup:"
    echo ""

    find "$BACKUP_ROOT" -type f | sort
}

# =====================================================
# AUTO BACKUP SETUP
# =====================================================

setup_auto_backup() {

    read -p "Masukkan jam backup (0-23): " HOUR

    CRON_JOB="0 ${HOUR} * * * $(realpath "$0") --auto-backup >/dev/null 2>&1"

    (
        crontab -l 2>/dev/null | grep -v postgres_manager.sh
        echo "$CRON_JOB"
    ) | crontab -

    echo ""
    echo "Backup otomatis aktif"
    echo "Jam: ${HOUR}:00"
}

# =====================================================
# AUTO MODE
# =====================================================

if [ "$1" == "--auto-backup" ]; then
    backup_all
    exit 0
fi

# =====================================================
# MENU
# =====================================================

while true
do

clear

echo "===================================="
echo " POSTGRES GLOBAL MANAGER"
echo "===================================="
echo "1. Backup Semua Database"
echo "2. Backup Database Tertentu"
echo "3. Restore Semua Database Terakhir"
echo "4. Restore Database Tertentu Terakhir"
echo "5. Restore Role/User"
echo "6. Setup Backup Otomatis"
echo "7. List Backup"
echo "0. Exit"
echo "===================================="

read -p "Pilih menu: " MENU

case $MENU in

1)
backup_all
read -p "ENTER..."
;;

2)
backup_one
read -p "ENTER..."
;;

3)
restore_all
read -p "ENTER..."
;;

4)
restore_one
read -p "ENTER..."
;;

5)
restore_roles
read -p "ENTER..."
;;

6)
setup_auto_backup
read -p "ENTER..."
;;

7)
list_backup
read -p "ENTER..."
;;

0)
exit 0
;;

*)
echo "Menu tidak valid"
sleep 2
;;

esac

done