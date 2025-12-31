#!/bin/bash
# =============================================================================
# Traefik Docker Hosting Platform - Installation Script
# =============================================================================
# This script installs and configures the complete hosting platform:
# - Docker and Docker Compose
# - Traefik reverse proxy
# - Required directories and permissions
#
# Usage: sudo ./install.sh
# =============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source library functions
# shellcheck source=lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
# shellcheck source=lib/validation.sh
source "${PROJECT_ROOT}/lib/validation.sh"
# shellcheck source=lib/docker.sh
source "${PROJECT_ROOT}/lib/docker.sh"

# =============================================================================
# Configuration
# =============================================================================
readonly INSTALL_DIR="${INSTALL_DIR:-/opt/traefik-hosting}"
readonly LOG_FILE="/var/log/traefik-hosting-install_$(date +%Y%m%d_%H%M%S).log"

# =============================================================================
# Functions
# =============================================================================

show_banner() {
    cat << 'EOF'
  _____              __ _ _      _    _           _   _
 |_   _| __ __ _  ___|  (_) | _  | |  | | ___  ___| |_(_)_ __   __ _
   | || '__/ _` |/ _ \ | | |/ /  | |__| |/ _ \/ __| __| | '_ \ / _` |
   | || | | (_| |  __/ | |   <   |  __  | (_) \__ \ |_| | | | | (_| |
   |_||_|  \__,_|\___|_|_|_|\_\  |_|  |_|\___/|___/\__|_|_| |_|\__, |
                                                               |___/
  Modern Multi-Client Hosting Platform with Traefik v3.6
EOF
    echo ""
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Must be root
    require_root

    # Check OS
    local os
    os=$(get_os_info)
    if [[ "$os" != "debian" && "$os" != "ubuntu" ]]; then
        log_warn "This script is designed for Debian/Ubuntu. Detected: $os"
        if ! confirm "Continue anyway?"; then
            die "Installation cancelled"
        fi
    fi

    # Check required commands
    require_commands "curl" "grep" "awk" "sed"

    log_info "Prerequisites check passed"
}

collect_configuration() {
    log_info "Collecting configuration..."

    # ACME Email
    prompt_input "Enter email for Let's Encrypt notifications" "" ACME_EMAIL
    if ! validate_email "$ACME_EMAIL"; then
        die "Invalid email address"
    fi

    # Traefik Dashboard Domain
    prompt_input "Enter domain for Traefik dashboard (e.g., traefik.example.com)" "" TRAEFIK_DASHBOARD_DOMAIN
    if ! validate_domain "$TRAEFIK_DASHBOARD_DOMAIN"; then
        die "Invalid domain"
    fi

    # Dashboard password
    log_info "Set password for Traefik dashboard (username: admin)"
    prompt_secure "Enter dashboard password" DASHBOARD_PASSWORD
    if ! validate_password "$DASHBOARD_PASSWORD" 8; then
        log_warn "Password does not meet complexity requirements"
        if ! confirm "Use this password anyway?"; then
            die "Installation cancelled"
        fi
    fi

    # Generate password hash
    if command_exists htpasswd; then
        DASHBOARD_PASSWORD_HASH=$(htpasswd -nbB admin "$DASHBOARD_PASSWORD" | sed -e 's/\$/\$\$/g')
    else
        log_warn "htpasswd not found. Installing apache2-utils..."
        apt-get install -y apache2-utils
        DASHBOARD_PASSWORD_HASH=$(htpasswd -nbB admin "$DASHBOARD_PASSWORD" | sed -e 's/\$/\$\$/g')
    fi

    # Current user (for docker group)
    DEPLOY_USER="${SUDO_USER:-$(whoami)}"
    if [[ "$DEPLOY_USER" == "root" ]]; then
        prompt_input "Enter username to add to docker group" "" DEPLOY_USER
        if ! validate_username "$DEPLOY_USER"; then
            die "Invalid username"
        fi
    fi

    log_info "Configuration collected successfully"
}

install_docker() {
    log_info "Installing Docker..."

    if command_exists docker; then
        local docker_version
        docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        log_info "Docker already installed (version: $docker_version)"

        if ! confirm "Reinstall Docker?"; then
            log_info "Skipping Docker installation"
            return 0
        fi
    fi

    install_docker_debian

    # Add user to docker group
    add_user_to_docker "$DEPLOY_USER"

    log_info "Docker installed successfully"
}

create_directory_structure() {
    log_info "Creating directory structure..."

    # Main installation directory
    ensure_dir "$INSTALL_DIR" "755"
    ensure_dir "$INSTALL_DIR/traefik" "755"
    ensure_dir "$INSTALL_DIR/traefik/dynamic" "755"
    ensure_dir "$INSTALL_DIR/traefik/acme" "700"
    ensure_dir "$INSTALL_DIR/traefik/logs" "755"
    ensure_dir "$INSTALL_DIR/clients" "755"
    ensure_dir "$INSTALL_DIR/backups" "750"
    ensure_dir "$INSTALL_DIR/secrets" "700"
    ensure_dir "$INSTALL_DIR/lib" "755"

    log_info "Directory structure created"
}

copy_files() {
    log_info "Copying configuration files..."

    # Check if we're already running from the install directory
    local project_real install_real
    project_real=$(cd "$PROJECT_ROOT" && pwd -P)
    install_real=$(cd "$INSTALL_DIR" 2>/dev/null && pwd -P || echo "$INSTALL_DIR")

    if [[ "$project_real" == "$install_real" ]]; then
        log_info "Already running from install directory, skipping file copy"
        # Just ensure scripts are executable
        for script in new-client.sh client-manager.sh backup.sh; do
            if [[ -f "$INSTALL_DIR/${script}" ]]; then
                chmod +x "$INSTALL_DIR/${script}"
            fi
        done
        return 0
    fi

    # Copy library files
    cp -r "${PROJECT_ROOT}/lib/"* "$INSTALL_DIR/lib/"

    # Copy Traefik configuration
    cp "${PROJECT_ROOT}/traefik/traefik.yml" "$INSTALL_DIR/traefik/"
    cp -r "${PROJECT_ROOT}/traefik/dynamic/"* "$INSTALL_DIR/traefik/dynamic/"

    # Copy Docker Compose file
    cp "${PROJECT_ROOT}/docker-compose.yml" "$INSTALL_DIR/"

    # Copy client template
    cp -r "${PROJECT_ROOT}/clients/.template" "$INSTALL_DIR/clients/"

    # Copy setup scripts
    cp -r "${PROJECT_ROOT}/setup/"* "$INSTALL_DIR/setup/" 2>/dev/null || mkdir -p "$INSTALL_DIR/setup"

    # Copy management scripts
    for script in new-client.sh client-manager.sh backup.sh; do
        if [[ -f "${PROJECT_ROOT}/${script}" ]]; then
            cp "${PROJECT_ROOT}/${script}" "$INSTALL_DIR/"
            chmod +x "$INSTALL_DIR/${script}"
        fi
    done

    log_info "Files copied successfully"
}

create_env_file() {
    log_info "Creating environment file..."

    cat > "$INSTALL_DIR/.env" << EOF
# =============================================================================
# Traefik Docker Hosting Platform - Environment Configuration
# Generated on $(date)
# =============================================================================

# Let's Encrypt email
ACME_EMAIL=${ACME_EMAIL}

# Traefik dashboard domain
TRAEFIK_DASHBOARD_DOMAIN=${TRAEFIK_DASHBOARD_DOMAIN}

# Whoami test domain (optional)
WHOAMI_DOMAIN=whoami.${TRAEFIK_DASHBOARD_DOMAIN#*.}
EOF

    chmod 600 "$INSTALL_DIR/.env"

    log_info "Environment file created"
}

update_dashboard_auth() {
    log_info "Updating dashboard authentication..."

    local security_file="$INSTALL_DIR/traefik/dynamic/security.yml"

    # Update the password hash in security.yml
    if [[ -f "$security_file" ]]; then
        sed -i "s|admin:\$\$2y.*|${DASHBOARD_PASSWORD_HASH}\"|" "$security_file"
        log_info "Dashboard authentication updated"
    else
        log_warn "Security configuration file not found"
    fi
}

create_acme_file() {
    log_info "Creating ACME storage file..."

    local acme_file="$INSTALL_DIR/traefik/acme/acme.json"

    if [[ ! -f "$acme_file" ]]; then
        touch "$acme_file"
        chmod 600 "$acme_file"
        log_info "ACME storage file created"
    else
        log_info "ACME storage file already exists"
    fi
}

create_docker_networks() {
    log_info "Creating Docker networks..."

    ensure_docker_network "traefik-public" "bridge" "false"
    ensure_docker_network "docker-proxy" "bridge" "true"

    log_info "Docker networks created"
}

set_permissions() {
    log_info "Setting permissions..."

    # Create traefik user if it doesn't exist
    if ! id "traefik" &>/dev/null; then
        useradd -r -M -s /sbin/nologin traefik
        log_info "Created traefik system user"
    fi

    # Set ownership
    chown -R 1000:1000 "$INSTALL_DIR/traefik"
    chown 1000:1000 "$INSTALL_DIR/traefik/acme/acme.json"
    chmod 600 "$INSTALL_DIR/traefik/acme/acme.json"

    # Add deploy user to traefik group
    usermod -aG traefik "$DEPLOY_USER" 2>/dev/null || true

    log_info "Permissions set"
}

start_services() {
    log_info "Starting services..."

    cd "$INSTALL_DIR"

    # Pull images first
    docker compose pull

    # Start the stack
    docker compose up -d

    # Wait for Traefik to be healthy
    log_info "Waiting for Traefik to start..."
    sleep 5

    if is_container_running "traefik"; then
        log_info "Traefik is running"
    else
        log_error "Traefik failed to start. Check logs with: docker compose logs traefik"
        return 1
    fi

    log_info "Services started successfully"
}

show_completion_message() {
    local ip_address
    ip_address=$(get_primary_ip)

    cat << EOF

=============================================================================
  Installation Complete!
=============================================================================

Installation Directory: $INSTALL_DIR

IMPORTANT NEXT STEPS:

1. Configure DNS:
   Point ${TRAEFIK_DASHBOARD_DOMAIN} to ${ip_address}

2. Re-login to apply Docker group membership:
   Log out and log back in as ${DEPLOY_USER}

3. Verify Traefik is running:
   docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f traefik

4. Access Traefik Dashboard:
   https://${TRAEFIK_DASHBOARD_DOMAIN}/dashboard/
   Username: admin
   Password: (the password you set)

5. Add a new client:
   cd ${INSTALL_DIR}
   sudo ./new-client.sh

=============================================================================
  Useful Commands
=============================================================================

Start services:    docker compose -f ${INSTALL_DIR}/docker-compose.yml up -d
Stop services:     docker compose -f ${INSTALL_DIR}/docker-compose.yml down
View logs:         docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f
Restart Traefik:   docker compose -f ${INSTALL_DIR}/docker-compose.yml restart traefik

=============================================================================

EOF
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Initialize logging
    init_logging "$LOG_FILE"

    # Set up error trap
    setup_trap

    # Show banner
    show_banner

    log_info "Starting Traefik Docker Hosting Platform installation..."
    log_info "Log file: $LOG_FILE"

    # Run installation steps
    check_prerequisites
    collect_configuration
    install_docker
    create_directory_structure
    copy_files
    create_env_file
    update_dashboard_auth
    create_acme_file
    create_docker_networks
    set_permissions
    start_services

    # Show completion message
    show_completion_message

    log_info "Installation completed successfully"
}

# Run main function
main "$@"
