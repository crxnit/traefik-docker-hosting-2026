#!/bin/bash
# =============================================================================
# common.sh - Shared utility functions for all scripts
# =============================================================================
# shellcheck shell=bash

# Guard against multiple sourcing
if [[ -n "${_COMMON_LOADED:-}" ]]; then
    return 0
fi
_COMMON_LOADED=true

# Strict mode - fail on errors, undefined variables, and pipe failures
set -euo pipefail

# =============================================================================
# Constants
# =============================================================================
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_NC='\033[0m' # No Color

readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3

# Default log level (can be overridden)
: "${LOG_LEVEL:=$LOG_LEVEL_INFO}"

# =============================================================================
# Logging Functions
# =============================================================================

# Initialize logging to file
# Usage: init_logging "/var/log/script.log"
init_logging() {
    local log_file="${1:-}"
    if [[ -n "$log_file" ]]; then
        LOG_FILE="$log_file"
        # Create log directory if it doesn't exist
        local log_dir
        log_dir=$(dirname "$log_file")
        if [[ ! -d "$log_dir" ]]; then
            mkdir -p "$log_dir" 2>/dev/null || sudo mkdir -p "$log_dir"
        fi
        # Redirect all output to log file while preserving terminal output
        exec > >(tee -a "$LOG_FILE") 2>&1
        log_info "Logging initialized to: $LOG_FILE"
    fi
}

# Internal logging function
_log() {
    local level="$1"
    local level_num="$2"
    local color="$3"
    local message="$4"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [[ $level_num -ge ${LOG_LEVEL:-1} ]]; then
        echo -e "${color}[${timestamp}] [${level}] ${message}${COLOR_NC}" >&2
    fi
}

log_debug() {
    _log "DEBUG" "$LOG_LEVEL_DEBUG" "$COLOR_BLUE" "$*"
}

log_info() {
    _log "INFO" "$LOG_LEVEL_INFO" "$COLOR_GREEN" "$*"
}

log_warn() {
    _log "WARN" "$LOG_LEVEL_WARN" "$COLOR_YELLOW" "$*"
}

log_error() {
    _log "ERROR" "$LOG_LEVEL_ERROR" "$COLOR_RED" "$*"
}

# =============================================================================
# Error Handling
# =============================================================================

# Check if last command succeeded
# Usage: check_status "Operation description"
check_status() {
    local status=$?
    local description="${1:-Last command}"

    if [[ $status -ne 0 ]]; then
        log_error "${description} failed with exit code: ${status}"
        return 1
    fi
    return 0
}

# Exit with error message
# Usage: die "Error message"
die() {
    log_error "$*"
    exit 1
}

# Cleanup function for trap
# Override this in your script for custom cleanup
cleanup() {
    log_debug "Cleanup called"
}

# Set up exit trap
setup_trap() {
    trap cleanup EXIT
    trap 'die "Script interrupted"' INT TERM
}

# =============================================================================
# User Interaction
# =============================================================================

# Prompt user for input with default value
# Usage: prompt_input "Enter value" "default_value" result_var
prompt_input() {
    local prompt="$1"
    local default="${2:-}"
    local -n result_ref="$3"

    if [[ -n "$default" ]]; then
        read -r -p "${prompt} [${default}]: " result_ref
        result_ref="${result_ref:-$default}"
    else
        read -r -p "${prompt}: " result_ref
    fi
}

# Prompt for yes/no confirmation
# Usage: confirm "Are you sure?" && echo "Yes" || echo "No"
confirm() {
    local prompt="${1:-Are you sure?}"
    local response

    read -r -p "${prompt} (y/N): " response
    [[ "$response" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Prompt for secure input (password)
# Usage: prompt_secure "Enter password" result_var
prompt_secure() {
    local prompt="$1"
    local -n result_ref="$2"

    read -r -s -p "${prompt}: " result_ref
    echo  # New line after hidden input
}

# =============================================================================
# System Checks
# =============================================================================

# Check if running as root
require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root or with sudo"
    fi
}

# Check if command exists
# Usage: command_exists "docker" || die "Docker not found"
command_exists() {
    command -v "$1" &>/dev/null
}

# Check if required commands exist
# Usage: require_commands "docker" "curl" "jq"
require_commands() {
    local missing=()
    for cmd in "$@"; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi
}

# Get OS information
get_os_info() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

# Get OS version codename
get_os_codename() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "${VERSION_CODENAME:-unknown}"
    else
        echo "unknown"
    fi
}

# =============================================================================
# File Operations
# =============================================================================

# Backup a file with timestamp
# Usage: backup_file "/etc/ssh/sshd_config"
backup_file() {
    local file="$1"
    local backup_dir="${2:-$(dirname "$file")}"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="${backup_dir}/$(basename "$file").bak.${timestamp}"

    if [[ -f "$file" ]]; then
        cp "$file" "$backup_file"
        log_info "Backed up $file to $backup_file"
        echo "$backup_file"
    else
        log_warn "File not found for backup: $file"
        return 1
    fi
}

# Create directory with proper permissions
# Usage: ensure_dir "/opt/traefik" "755" "traefik:traefik"
ensure_dir() {
    local dir="$1"
    local perms="${2:-755}"
    local owner="${3:-}"

    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        log_info "Created directory: $dir"
    fi

    chmod "$perms" "$dir"

    if [[ -n "$owner" ]]; then
        chown "$owner" "$dir"
    fi
}

# =============================================================================
# String Operations
# =============================================================================

# Convert string to lowercase
to_lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Convert string to uppercase
to_upper() {
    echo "$1" | tr '[:lower:]' '[:upper:]'
}

# Sanitize string for use in filenames/identifiers
# Usage: sanitize_name "My App Name" -> "my_app_name"
sanitize_name() {
    local input="$1"
    echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/_/g' | sed 's/__*/_/g' | sed 's/^_\|_$//g'
}

# Convert snake_case to Title Case
# Usage: to_friendly_name "my_app" -> "My App"
to_friendly_name() {
    local input="$1"
    echo "$input" | tr '_' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
}

# =============================================================================
# Network Utilities
# =============================================================================

# Get primary IP address
get_primary_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || ip route get 1 2>/dev/null | awk '{print $7; exit}'
}

# Check if port is available
# Usage: is_port_available 8080
is_port_available() {
    local port="$1"
    ! ss -tuln 2>/dev/null | grep -q ":${port} " && ! netstat -tuln 2>/dev/null | grep -q ":${port} "
}

# Wait for service to be ready
# Usage: wait_for_service "localhost" "8080" 30
wait_for_service() {
    local host="$1"
    local port="$2"
    local timeout="${3:-30}"
    local elapsed=0

    log_info "Waiting for ${host}:${port} to be ready..."

    while [[ $elapsed -lt $timeout ]]; do
        if nc -z "$host" "$port" 2>/dev/null; then
            log_info "Service ${host}:${port} is ready"
            return 0
        fi
        sleep 1
        ((elapsed++))
    done

    log_error "Timeout waiting for ${host}:${port}"
    return 1
}
