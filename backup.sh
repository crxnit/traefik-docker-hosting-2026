#!/bin/bash
# =============================================================================
# Backup Script
# =============================================================================
# Creates backups of:
# - Traefik ACME certificates
# - Client databases
# - Configuration files
#
# Usage: sudo ./backup.sh [--all|--traefik|--clients|--client CLIENT_NAME]
# =============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library functions
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# =============================================================================
# Configuration
# =============================================================================
readonly BACKUP_ROOT="${SCRIPT_DIR}/backups"
readonly CLIENTS_ROOT="${SCRIPT_DIR}/clients"
readonly TRAEFIK_ACME="${SCRIPT_DIR}/traefik/acme"
readonly RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# =============================================================================
# Functions
# =============================================================================

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --all             Backup everything (Traefik + all clients)
  --traefik         Backup Traefik ACME certificates
  --clients         Backup all client databases
  --client NAME     Backup specific client
  --list            List available backups
  --restore FILE    Restore from backup file
  --cleanup         Remove old backups (older than ${RETENTION_DAYS} days)
  --help            Show this help message

Examples:
  $(basename "$0") --all
  $(basename "$0") --client my-app
  $(basename "$0") --restore backups/traefik_acme_20250101_120000.tar.gz
EOF
}

ensure_backup_dir() {
    mkdir -p "$BACKUP_ROOT"
    chmod 750 "$BACKUP_ROOT"
}

get_timestamp() {
    date '+%Y%m%d_%H%M%S'
}

# Backup Traefik ACME certificates
backup_traefik() {
    log_info "Backing up Traefik ACME certificates..."

    ensure_backup_dir
    local timestamp
    timestamp=$(get_timestamp)
    local backup_file="${BACKUP_ROOT}/traefik_acme_${timestamp}.tar.gz"

    if [[ ! -d "$TRAEFIK_ACME" ]]; then
        log_warn "ACME directory not found: $TRAEFIK_ACME"
        return 1
    fi

    tar -czf "$backup_file" -C "$(dirname "$TRAEFIK_ACME")" "$(basename "$TRAEFIK_ACME")"

    chmod 600 "$backup_file"
    log_info "Traefik backup created: $backup_file"

    # Calculate size
    local size
    size=$(du -h "$backup_file" | cut -f1)
    log_info "Backup size: $size"
}

# Backup client database
backup_client_db() {
    local client_name="$1"
    local client_path="${CLIENTS_ROOT}/${client_name}"

    if [[ ! -d "$client_path" ]]; then
        log_error "Client not found: $client_name"
        return 1
    fi

    # Load client environment
    if [[ -f "$client_path/.env" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "$client_path/.env"
        set +a
    else
        log_error "Client .env not found: $client_path/.env"
        return 1
    fi

    local db_container="${client_name}-db"

    # Check if database container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${db_container}$"; then
        log_warn "Database container not running: $db_container"
        return 1
    fi

    ensure_backup_dir
    local timestamp
    timestamp=$(get_timestamp)
    local backup_file="${BACKUP_ROOT}/${client_name}_db_${timestamp}.sql.gz"

    log_info "Backing up database for: $client_name"

    # Get credentials from secrets
    local pg_user
    if [[ -f "$client_path/secrets/postgres_user.txt" ]]; then
        pg_user=$(cat "$client_path/secrets/postgres_user.txt")
    else
        pg_user="${POSTGRES_USER:-postgres}"
    fi

    # Dump database
    docker exec "$db_container" pg_dump -U "$pg_user" "${POSTGRES_DB:-$client_name}" | gzip > "$backup_file"

    chmod 600 "$backup_file"
    log_info "Database backup created: $backup_file"

    local size
    size=$(du -h "$backup_file" | cut -f1)
    log_info "Backup size: $size"
}

# Backup all clients
backup_all_clients() {
    log_info "Backing up all client databases..."

    local success=0
    local failed=0

    while IFS= read -r -d '' client_path; do
        local client_name
        client_name=$(basename "$client_path")

        # Skip template
        if [[ "$client_name" == ".template" ]]; then
            continue
        fi

        if [[ -f "$client_path/.env" ]]; then
            if backup_client_db "$client_name"; then
                ((success++))
            else
                ((failed++))
            fi
        fi
    done < <(find "$CLIENTS_ROOT" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)

    log_info "Client backups complete: $success succeeded, $failed failed"
}

# Backup everything
backup_all() {
    log_info "Starting full backup..."

    backup_traefik
    backup_all_clients

    log_info "Full backup complete"
}

# List available backups
list_backups() {
    echo ""
    echo "============================================"
    echo "  Available Backups"
    echo "============================================"
    echo ""

    if [[ ! -d "$BACKUP_ROOT" ]] || [[ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; then
        echo "No backups found in $BACKUP_ROOT"
        return 0
    fi

    # List by type
    echo "Traefik ACME Backups:"
    find "$BACKUP_ROOT" -name "traefik_acme_*.tar.gz" -printf "  %f (%s bytes, %Tc)\n" 2>/dev/null | head -10 || echo "  None"

    echo ""
    echo "Client Database Backups:"
    find "$BACKUP_ROOT" -name "*_db_*.sql.gz" -printf "  %f (%s bytes, %Tc)\n" 2>/dev/null | head -20 || echo "  None"

    echo ""

    # Show total size
    local total_size
    total_size=$(du -sh "$BACKUP_ROOT" 2>/dev/null | cut -f1)
    echo "Total backup size: $total_size"
}

# Restore from backup
restore_backup() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    local filename
    filename=$(basename "$backup_file")

    if [[ "$filename" == traefik_acme_* ]]; then
        restore_traefik "$backup_file"
    elif [[ "$filename" == *_db_*.sql.gz ]]; then
        restore_client_db "$backup_file"
    else
        log_error "Unknown backup type: $filename"
        return 1
    fi
}

# Restore Traefik ACME
restore_traefik() {
    local backup_file="$1"

    log_info "Restoring Traefik ACME from: $backup_file"

    if ! confirm "This will overwrite current ACME certificates. Continue?"; then
        log_info "Restore cancelled"
        return 0
    fi

    # Stop Traefik
    log_info "Stopping Traefik..."
    docker stop traefik 2>/dev/null || true

    # Backup current ACME
    if [[ -d "$TRAEFIK_ACME" ]]; then
        mv "$TRAEFIK_ACME" "${TRAEFIK_ACME}.old"
    fi

    # Extract backup
    tar -xzf "$backup_file" -C "$(dirname "$TRAEFIK_ACME")"

    # Restore permissions
    chmod 600 "${TRAEFIK_ACME}/acme.json" 2>/dev/null || true

    # Start Traefik
    log_info "Starting Traefik..."
    docker start traefik

    log_info "Traefik ACME restored successfully"

    # Cleanup old backup
    rm -rf "${TRAEFIK_ACME}.old"
}

# Restore client database
restore_client_db() {
    local backup_file="$1"
    local filename
    filename=$(basename "$backup_file")

    # Extract client name from filename (format: clientname_db_timestamp.sql.gz)
    local client_name
    client_name="${filename%%_db_[0-9]*}"

    local client_path="${CLIENTS_ROOT}/${client_name}"

    if [[ ! -d "$client_path" ]]; then
        log_error "Client not found: $client_name"
        return 1
    fi

    log_info "Restoring database for: $client_name"

    if ! confirm "This will overwrite the current database for $client_name. Continue?"; then
        log_info "Restore cancelled"
        return 0
    fi

    # Load client environment
    set -a
    # shellcheck source=/dev/null
    source "$client_path/.env"
    set +a

    local db_container="${client_name}-db"

    # Check if container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${db_container}$"; then
        log_error "Database container not running: $db_container"
        return 1
    fi

    # Get credentials
    local pg_user
    if [[ -f "$client_path/secrets/postgres_user.txt" ]]; then
        pg_user=$(cat "$client_path/secrets/postgres_user.txt")
    else
        pg_user="${POSTGRES_USER:-postgres}"
    fi

    # Restore database
    log_info "Restoring database..."
    zcat "$backup_file" | docker exec -i "$db_container" psql -U "$pg_user" -d "${POSTGRES_DB:-$client_name}"

    log_info "Database restored successfully for: $client_name"
}

# Cleanup old backups
cleanup_backups() {
    log_info "Cleaning up backups older than ${RETENTION_DAYS} days..."

    if [[ ! -d "$BACKUP_ROOT" ]]; then
        log_info "No backups directory found"
        return 0
    fi

    local count
    count=$(find "$BACKUP_ROOT" -type f -mtime "+${RETENTION_DAYS}" | wc -l)

    if [[ $count -eq 0 ]]; then
        log_info "No old backups to remove"
        return 0
    fi

    log_info "Found $count backup(s) to remove"

    if confirm "Remove $count old backup(s)?"; then
        find "$BACKUP_ROOT" -type f -mtime "+${RETENTION_DAYS}" -delete
        log_info "Old backups removed"
    else
        log_info "Cleanup cancelled"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    require_root

    if [[ $# -eq 0 ]]; then
        show_usage
        exit 0
    fi

    case "$1" in
        --all)
            backup_all
            ;;
        --traefik)
            backup_traefik
            ;;
        --clients)
            backup_all_clients
            ;;
        --client)
            if [[ -z "${2:-}" ]]; then
                log_error "Client name required"
                exit 1
            fi
            backup_client_db "$2"
            ;;
        --list)
            list_backups
            ;;
        --restore)
            if [[ -z "${2:-}" ]]; then
                log_error "Backup file required"
                exit 1
            fi
            restore_backup "$2"
            ;;
        --cleanup)
            cleanup_backups
            ;;
        --help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
