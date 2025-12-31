#!/bin/bash
# =============================================================================
# Client Manager Script
# =============================================================================
# Manages all client deployments:
# - Deploy/stop individual or all clients
# - View deployment status
# - Interactive menu interface
#
# Usage: sudo ./client-manager.sh
# =============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library functions
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/docker.sh
source "${SCRIPT_DIR}/lib/docker.sh"

# =============================================================================
# Configuration
# =============================================================================
readonly CLIENTS_ROOT="${SCRIPT_DIR}/clients"
readonly STATUS_FILE="${CLIENTS_ROOT}/deployment_status.csv"

# Arrays to store discovered clients
declare -a CLIENT_PATHS=()
declare -a CLIENT_NAMES=()

# =============================================================================
# Functions
# =============================================================================

show_banner() {
    cat << 'EOF'
   ____ _ _            _     __  __
  / ___| (_) ___ _ __ | |_  |  \/  | __ _ _ __   __ _  __ _  ___ _ __
 | |   | | |/ _ \ '_ \| __| | |\/| |/ _` | '_ \ / _` |/ _` |/ _ \ '__|
 | |___| | |  __/ | | | |_  | |  | | (_| | | | | (_| | (_| |  __/ |
  \____|_|_|\___|_| |_|\__| |_|  |_|\__,_|_| |_|\__,_|\__, |\___|_|
                                                      |___/
EOF
    echo ""
}

# Check if directory is a valid client
is_valid_client() {
    local client_path="$1"
    local client_name
    client_name=$(basename "$client_path")

    [[ -f "$client_path/.env" ]] && \
    [[ -f "$client_path/docker-compose.yml" ]] && \
    [[ "$client_name" != ".template" ]]
}

# Discover all valid clients
discover_clients() {
    CLIENT_PATHS=()
    CLIENT_NAMES=()

    if [[ ! -d "$CLIENTS_ROOT" ]]; then
        log_warn "Clients directory not found: $CLIENTS_ROOT"
        return 1
    fi

    local count=0
    while IFS= read -r -d '' client_path; do
        if is_valid_client "$client_path"; then
            CLIENT_PATHS+=("$client_path")
            CLIENT_NAMES+=("$(basename "$client_path")")
            ((count++))
        fi
    done < <(find "$CLIENTS_ROOT" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)

    if [[ $count -eq 0 ]]; then
        log_info "No clients found in $CLIENTS_ROOT"
        return 1
    fi

    log_info "Discovered $count client(s)"
    return 0
}

# Initialize status CSV
init_status_file() {
    if [[ ! -f "$STATUS_FILE" ]]; then
        echo "ClientName,FriendlyName,Status,LastAction,ActionDate" > "$STATUS_FILE"
    fi
}

# Update client status in CSV
update_status() {
    local client_name="$1"
    local status="$2"
    local action="$3"
    local friendly_name
    local action_date

    friendly_name=$(to_friendly_name "$client_name")
    action_date=$(date '+%Y-%m-%d %H:%M:%S')

    init_status_file

    # Create new entry
    local new_entry="${client_name},\"${friendly_name}\",${status},\"${action}\",${action_date}"

    # Update or append
    local temp_file
    temp_file=$(mktemp)

    awk -v name="$client_name" -v new_data="$new_entry" '
    BEGIN { FS=","; OFS="," }
    NR==1 { print; next }
    $1 == name { print new_data; found=1; next }
    { print }
    END { if (!found) print new_data }
    ' "$STATUS_FILE" > "$temp_file"

    mv "$temp_file" "$STATUS_FILE"
}

# Deploy a single client
deploy_client() {
    local client_path="$1"
    local client_name
    client_name=$(basename "$client_path")
    local friendly_name
    friendly_name=$(to_friendly_name "$client_name")

    log_info "Deploying: $friendly_name"

    if [[ ! -f "$client_path/deploy.sh" ]]; then
        log_error "Deploy script not found: $client_path/deploy.sh"
        update_status "$client_name" "Error" "Deploy script missing"
        return 1
    fi

    # Run deploy script
    if (cd "$client_path" && ./deploy.sh); then
        update_status "$client_name" "Running" "Deployment successful"
        log_info "Successfully deployed: $friendly_name"
        return 0
    else
        update_status "$client_name" "Error" "Deployment failed"
        log_error "Failed to deploy: $friendly_name"
        return 1
    fi
}

# Stop a single client
stop_client() {
    local client_path="$1"
    local client_name
    client_name=$(basename "$client_path")
    local friendly_name
    friendly_name=$(to_friendly_name "$client_name")

    log_info "Stopping: $friendly_name"

    if [[ ! -f "$client_path/docker-compose.yml" ]]; then
        log_error "Docker Compose file not found: $client_path/docker-compose.yml"
        update_status "$client_name" "Error" "Compose file missing"
        return 1
    fi

    # Stop containers
    if (cd "$client_path" && docker compose down --remove-orphans); then
        update_status "$client_name" "Stopped" "Stopped by user"
        log_info "Successfully stopped: $friendly_name"
        return 0
    else
        update_status "$client_name" "Error" "Stop failed"
        log_error "Failed to stop: $friendly_name"
        return 1
    fi
}

# Deploy all clients
deploy_all() {
    log_info "Deploying all clients..."

    local success=0
    local failed=0

    for path in "${CLIENT_PATHS[@]}"; do
        if deploy_client "$path"; then
            ((success++))
        else
            ((failed++))
        fi
    done

    echo ""
    log_info "Deployment complete: $success succeeded, $failed failed"
}

# Stop all clients
stop_all() {
    log_info "Stopping all clients..."

    local success=0
    local failed=0

    for path in "${CLIENT_PATHS[@]}"; do
        if stop_client "$path"; then
            ((success++))
        else
            ((failed++))
        fi
    done

    echo ""
    log_info "Stop complete: $success succeeded, $failed failed"
}

# View deployment status
view_status() {
    echo ""
    echo "============================================"
    echo "  Client Deployment Status"
    echo "============================================"
    echo ""

    if [[ -f "$STATUS_FILE" ]]; then
        column -s, -t "$STATUS_FILE" | awk 'NR==1{print $0; print "--------------------------------------------"; next} {print}'
    else
        echo "No status information available."
        echo "Deploy a client to generate status data."
    fi

    echo ""

    # Show container status
    echo "============================================"
    echo "  Running Containers"
    echo "============================================"
    echo ""

    for name in "${CLIENT_NAMES[@]}"; do
        local web_container="${name}-web"
        local db_container="${name}-db"

        printf "%-20s " "$name:"

        if is_container_running "$web_container"; then
            if is_container_healthy "$web_container"; then
                printf "web=healthy "
            else
                printf "web=running "
            fi
        else
            printf "web=stopped "
        fi

        if is_container_running "$db_container"; then
            if is_container_healthy "$db_container"; then
                printf "db=healthy"
            else
                printf "db=running"
            fi
        else
            printf "db=stopped"
        fi

        echo ""
    done

    echo ""
}

# Show menu and handle selection
show_menu() {
    echo ""
    echo "============================================"
    echo "  Available Actions"
    echo "============================================"
    echo ""
    echo "  A) Deploy/Update ALL clients"
    echo "  S) Stop ALL clients"
    echo "  V) View deployment status"
    echo "  N) Create NEW client"
    echo "  Q) Quit"
    echo ""

    # List individual clients
    if [[ ${#CLIENT_NAMES[@]} -gt 0 ]]; then
        echo "  Individual Clients:"
        for i in "${!CLIENT_NAMES[@]}"; do
            local friendly
            friendly=$(to_friendly_name "${CLIENT_NAMES[$i]}")
            printf "  %d) %s\n" "$((i + 1))" "$friendly"
        done
        echo ""
    fi

    local choice
    read -r -p "Enter choice: " choice
    choice=$(echo "$choice" | tr '[:lower:]' '[:upper:]')

    case "$choice" in
        A)
            deploy_all
            ;;
        S)
            if confirm "Stop all clients?"; then
                stop_all
            fi
            ;;
        V)
            view_status
            ;;
        N)
            if [[ -f "${SCRIPT_DIR}/new-client.sh" ]]; then
                "${SCRIPT_DIR}/new-client.sh"
                discover_clients
            else
                log_error "new-client.sh not found"
            fi
            ;;
        Q)
            log_info "Goodbye!"
            exit 0
            ;;
        *)
            # Check if it's a number for individual client
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                local index=$((choice - 1))
                if [[ $index -ge 0 && $index -lt ${#CLIENT_NAMES[@]} ]]; then
                    manage_individual_client "${CLIENT_PATHS[$index]}"
                else
                    log_error "Invalid selection"
                fi
            else
                log_error "Invalid choice"
            fi
            ;;
    esac
}

# Manage individual client
manage_individual_client() {
    local client_path="$1"
    local client_name
    client_name=$(basename "$client_path")
    local friendly_name
    friendly_name=$(to_friendly_name "$client_name")

    echo ""
    echo "============================================"
    echo "  Managing: $friendly_name"
    echo "============================================"
    echo ""
    echo "  D) Deploy/Update"
    echo "  P) Stop"
    echo "  L) View logs"
    echo "  R) Restart"
    echo "  B) Back to main menu"
    echo ""

    local action
    read -r -p "Enter action: " action
    action=$(echo "$action" | tr '[:lower:]' '[:upper:]')

    case "$action" in
        D)
            deploy_client "$client_path"
            ;;
        P)
            stop_client "$client_path"
            ;;
        L)
            log_info "Showing logs for $friendly_name (Ctrl+C to exit)"
            (cd "$client_path" && docker compose logs -f --tail 100)
            ;;
        R)
            log_info "Restarting $friendly_name"
            (cd "$client_path" && docker compose restart)
            update_status "$client_name" "Running" "Restarted"
            ;;
        B)
            return 0
            ;;
        *)
            log_error "Invalid action"
            ;;
    esac
}

# =============================================================================
# Main
# =============================================================================

main() {
    require_root

    show_banner

    # Discover clients
    discover_clients || true

    # Main loop
    while true; do
        show_menu
        sleep 1
    done
}

# Run main function
main "$@"
