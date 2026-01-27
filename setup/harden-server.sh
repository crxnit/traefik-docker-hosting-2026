#!/bin/bash
# =============================================================================
# Server Security Hardening Script
# =============================================================================
# Applies comprehensive security hardening to Debian/Ubuntu servers:
# - User management
# - SSH hardening
# - Kernel security parameters
# - Firewall configuration
# - Automatic updates
#
# Usage: sudo ./harden-server.sh
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
# shellcheck source=lib/security.sh
source "${PROJECT_ROOT}/lib/security.sh"

# =============================================================================
# Configuration
# =============================================================================
LOG_FILE="/var/log/server_hardening_$(date +%Y%m%d_%H%M%S).log"
readonly LOG_FILE

# =============================================================================
# Functions
# =============================================================================

show_banner() {
    cat << 'EOF'
  ____                           _   _               _            _
 / ___|  ___ _ ____   _____ _ __| | | | __ _ _ __ __| | ___ _ __ (_)_ __   __ _
 \___ \ / _ \ '__\ \ / / _ \ '__| |_| |/ _` | '__/ _` |/ _ \ '_ \| | '_ \ / _` |
  ___) |  __/ |   \ V /  __/ |  |  _  | (_| | | | (_| |  __/ | | | | | | | (_| |
 |____/ \___|_|    \_/ \___|_|  |_| |_|\__,_|_|  \__,_|\___|_| |_|_|_| |_|\__, |
                                                                          |___/
  Linux Server Security Hardening
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
        die "This script only supports Debian and Ubuntu. Detected: $os"
    fi

    log_info "Prerequisites check passed"
}

# shellcheck disable=SC2153  # SSH_PORT and TIMEZONE are set via prompt_input
collect_configuration() {
    log_info "Collecting configuration..."

    # Admin username
    prompt_input "Enter username for the admin account" "${SUDO_USER:-admin}" ADMIN_USER
    if ! validate_username "$ADMIN_USER"; then
        die "Invalid username"
    fi

    # SSH Port
    prompt_input "Enter new SSH port (> 1024 recommended)" "2222" SSH_PORT
    if ! validate_port "$SSH_PORT" "true"; then
        die "Invalid port number"
    fi

    # SSH Key deployment choice
    echo ""
    echo "SSH Public Key Deployment Options:"
    echo "  1) Paste the key now"
    echo "  2) Use ssh-copy-id after this script completes"
    prompt_input "Choose option" "1" KEY_CHOICE

    SSH_PUB_KEY=""
    if [[ "$KEY_CHOICE" == "1" ]]; then
        prompt_input "Paste your SSH public key" "" SSH_PUB_KEY
        if [[ -z "$SSH_PUB_KEY" ]]; then
            log_warn "No key provided. You must add your key manually or use ssh-copy-id"
        fi
    fi

    # Timezone
    echo ""
    echo "Common timezones: America/New_York, America/Los_Angeles, Europe/London, Asia/Tokyo"
    prompt_input "Enter timezone" "UTC" TIMEZONE

    log_info "Configuration collected"
}

create_admin_user_step() {
    log_info "Step 1: Creating/verifying admin user..."

    create_admin_user "$ADMIN_USER"

    # Set password if user is new
    if ! grep -q "^${ADMIN_USER}:" /etc/shadow 2>/dev/null; then
        log_info "Set password for $ADMIN_USER:"
        passwd "$ADMIN_USER"
    fi
}

change_root_password() {
    log_info "Step 2: Changing root password..."

    if confirm "Change root password?"; then
        passwd root
        log_info "Root password changed"
    else
        log_info "Skipping root password change"
    fi
}

configure_hostname_step() {
    log_info "Step 3: Configuring hostname..."

    local current_hostname
    current_hostname=$(hostname)

    # Generate suggested hostname based on system specs
    local cpu_cores ram_gb disk_size ip_addr suggested_hostname
    cpu_cores=$(nproc)
    ram_gb=$(free -g | awk '/Mem:/ {print $2}')
    disk_size=$(df -h / | awk 'NR==2 {print $2}')
    ip_addr=$(get_primary_ip)
    ip_segment=$(echo "$ip_addr" | tr '.' '-')
    suggested_hostname="srv-${ip_segment}-${cpu_cores}c${ram_gb}g"

    echo ""
    echo "Current hostname: $current_hostname"
    echo "Suggested hostname: $suggested_hostname"
    echo "  (Based on: IP=$ip_addr, CPU=${cpu_cores} cores, RAM=${ram_gb}GB, Disk=$disk_size)"

    prompt_input "Enter new hostname (or press Enter for suggested)" "$suggested_hostname" NEW_HOSTNAME

    if [[ -n "$NEW_HOSTNAME" && "$NEW_HOSTNAME" != "$current_hostname" ]]; then
        hostnamectl set-hostname "$NEW_HOSTNAME"

        # Update /etc/hosts
        backup_file "/etc/hosts"

        # Update localhost entries
        if ! grep -q "127.0.1.1.*${NEW_HOSTNAME}" /etc/hosts; then
            if grep -q "^127.0.1.1" /etc/hosts; then
                sed -i "/^127.0.1.1/c\\127.0.1.1\t${NEW_HOSTNAME}" /etc/hosts
            else
                echo -e "127.0.1.1\t${NEW_HOSTNAME}" >> /etc/hosts
            fi
        fi

        log_info "Hostname set to: $NEW_HOSTNAME"
    else
        log_info "Hostname unchanged"
    fi
}

update_system() {
    log_info "Step 4: Updating system packages..."

    apt-get update -y
    apt-get upgrade -y

    log_info "System updated"
}

harden_ssh_step() {
    log_info "Step 5: Hardening SSH configuration..."

    harden_ssh "$SSH_PORT" "$ADMIN_USER"

    # Deploy SSH key if provided
    if [[ -n "$SSH_PUB_KEY" ]]; then
        deploy_ssh_key "$ADMIN_USER" "$SSH_PUB_KEY"
    fi
}

configure_ntp_step() {
    log_info "Step 6: Configuring NTP and timezone..."

    # shellcheck disable=SC2153  # TIMEZONE is set via prompt_input in collect_configuration
    configure_ntp "$TIMEZONE"
}

apply_kernel_hardening_step() {
    log_info "Step 7: Applying kernel hardening..."

    apply_kernel_hardening
}

configure_firewall_step() {
    log_info "Step 8: Configuring firewall..."

    if confirm "Configure UFW firewall?"; then
        configure_ufw "$SSH_PORT" 80 443
    else
        log_info "Skipping firewall configuration"
    fi
}

configure_fail2ban_step() {
    log_info "Step 9: Configuring Fail2ban..."

    if confirm "Install and configure Fail2ban?"; then
        configure_fail2ban "$SSH_PORT"
    else
        log_info "Skipping Fail2ban configuration"
    fi
}

configure_auto_updates_step() {
    log_info "Step 10: Configuring automatic security updates..."

    if confirm "Enable automatic security updates?"; then
        configure_auto_updates
    else
        log_info "Skipping automatic updates configuration"
    fi
}

configure_auditd_step() {
    log_info "Step 11: Configuring audit logging..."

    if confirm "Install and configure auditd?"; then
        configure_auditd
    else
        log_info "Skipping auditd configuration"
    fi
}

finalize() {
    log_info "Step 12: Finalizing configuration..."

    # Restart SSH to apply changes
    systemctl restart sshd

    log_info "SSH service restarted"
}

verify_ssh_access() {
    echo ""
    echo "============================================================================="
    echo "  CRITICAL: Verify SSH Access Before Closing This Session!"
    echo "============================================================================="
    echo ""
    echo "1. Open a NEW terminal window"
    echo "2. Connect using: ssh -p ${SSH_PORT} ${ADMIN_USER}@$(get_primary_ip)"
    echo "3. Verify you can log in and use sudo"
    echo ""

    if [[ -z "$SSH_PUB_KEY" ]]; then
        echo "IMPORTANT: You did not paste an SSH key."
        echo "Run this from your LOCAL machine BEFORE closing this session:"
        echo "  ssh-copy-id -p ${SSH_PORT} ${ADMIN_USER}@$(get_primary_ip)"
        echo ""
    fi

    if ! confirm "Have you verified SSH access in a new terminal?"; then
        log_warn "Keeping password authentication enabled for safety"
        log_warn "Run 'sudo ./setup/disable-password-auth.sh' after verifying SSH key access"
        return
    fi

    if confirm "Disable password authentication now?"; then
        log_info "Disabling password authentication..."

        sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config

        systemctl restart sshd
        log_info "Password authentication disabled"
    else
        log_info "Password authentication remains enabled"
    fi
}

show_completion_message() {
    cat << EOF

=============================================================================
  Server Hardening Complete!
=============================================================================

Summary of Changes:
  - Admin user: ${ADMIN_USER}
  - SSH port: ${SSH_PORT}
  - Timezone: ${TIMEZONE}
  - Kernel hardening: Applied
  - Firewall: $(command_exists ufw && ufw status | head -1 || echo "Not configured")

Connect to this server:
  ssh -p ${SSH_PORT} ${ADMIN_USER}@$(get_primary_ip)

Log file: ${LOG_FILE}

REMEMBER:
  - Update any firewall rules on your cloud provider to allow port ${SSH_PORT}
  - Test SSH access before closing this session
  - Review /etc/ssh/sshd_config.d/99-hardening.conf for SSH settings

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

    log_info "Starting server hardening..."
    log_info "Log file: $LOG_FILE"

    # Run hardening steps
    check_prerequisites
    collect_configuration
    create_admin_user_step
    change_root_password
    configure_hostname_step
    update_system
    harden_ssh_step
    configure_ntp_step
    apply_kernel_hardening_step
    configure_firewall_step
    configure_fail2ban_step
    configure_auto_updates_step
    configure_auditd_step
    finalize

    # Verify SSH access and optionally disable password auth
    verify_ssh_access

    # Show completion message
    show_completion_message

    log_info "Server hardening completed successfully"
}

# Run main function
main "$@"
