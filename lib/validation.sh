#!/bin/bash
# =============================================================================
# validation.sh - Input validation functions
# =============================================================================
# shellcheck shell=bash

# Guard against multiple sourcing
if [[ -n "${_VALIDATION_LOADED:-}" ]]; then
    return 0
fi

# Source common functions if not already loaded
if [[ -z "${_COMMON_LOADED:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/common.sh
    source "${SCRIPT_DIR}/common.sh"
fi

_VALIDATION_LOADED=true

# =============================================================================
# Domain Validation
# =============================================================================

# Validate domain name format
# Usage: validate_domain "example.com" || die "Invalid domain"
validate_domain() {
    local domain="$1"

    # Check for empty input
    if [[ -z "$domain" ]]; then
        log_error "Domain cannot be empty"
        return 1
    fi

    # Domain regex: alphanumeric, hyphens allowed (not at start/end), proper TLD
    local domain_regex='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$'

    if [[ ! "$domain" =~ $domain_regex ]]; then
        log_error "Invalid domain format: $domain"
        return 1
    fi

    # Check total length (max 253 characters)
    if [[ ${#domain} -gt 253 ]]; then
        log_error "Domain too long (max 253 characters): $domain"
        return 1
    fi

    return 0
}

# Validate subdomain format
# Usage: validate_subdomain "api" || die "Invalid subdomain"
validate_subdomain() {
    local subdomain="$1"

    if [[ -z "$subdomain" ]]; then
        log_error "Subdomain cannot be empty"
        return 1
    fi

    # Subdomain: alphanumeric and hyphens, 1-63 chars, no leading/trailing hyphen
    local subdomain_regex='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'

    if [[ ! "$subdomain" =~ $subdomain_regex ]]; then
        log_error "Invalid subdomain format: $subdomain"
        return 1
    fi

    return 0
}

# =============================================================================
# Network Validation
# =============================================================================

# Validate port number
# Usage: validate_port "8080" || die "Invalid port"
validate_port() {
    local port="$1"
    local allow_privileged="${2:-false}"

    if [[ -z "$port" ]]; then
        log_error "Port cannot be empty"
        return 1
    fi

    # Must be numeric
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        log_error "Port must be a number: $port"
        return 1
    fi

    # Range check
    if [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        log_error "Port must be between 1 and 65535: $port"
        return 1
    fi

    # Privileged port check (unless allowed)
    if [[ "$allow_privileged" != "true" && "$port" -lt 1024 ]]; then
        log_error "Privileged ports (< 1024) require root. Use port >= 1024: $port"
        return 1
    fi

    return 0
}

# Validate IPv4 address
# Usage: validate_ipv4 "192.168.1.1" || die "Invalid IP"
validate_ipv4() {
    local ip="$1"

    if [[ -z "$ip" ]]; then
        log_error "IP address cannot be empty"
        return 1
    fi

    # IPv4 regex
    local ipv4_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

    if [[ ! "$ip" =~ $ipv4_regex ]]; then
        log_error "Invalid IPv4 format: $ip"
        return 1
    fi

    # Validate each octet
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if [[ "$octet" -gt 255 ]]; then
            log_error "Invalid IPv4 octet (> 255): $ip"
            return 1
        fi
    done

    return 0
}

# =============================================================================
# String Validation
# =============================================================================

# Validate username format
# Usage: validate_username "john" || die "Invalid username"
validate_username() {
    local username="$1"

    if [[ -z "$username" ]]; then
        log_error "Username cannot be empty"
        return 1
    fi

    # Linux username: start with letter, alphanumeric/underscore/hyphen, 1-32 chars
    local username_regex='^[a-z_][a-z0-9_-]{0,31}$'

    if [[ ! "$username" =~ $username_regex ]]; then
        log_error "Invalid username format (must start with letter, alphanumeric/underscore/hyphen, max 32 chars): $username"
        return 1
    fi

    return 0
}

# Validate client/project name
# Usage: validate_client_name "my-client" || die "Invalid name"
validate_client_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "Client name cannot be empty"
        return 1
    fi

    # Alphanumeric, hyphens, underscores; 2-64 chars; no leading/trailing special chars
    local name_regex='^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}[a-zA-Z0-9]$|^[a-zA-Z0-9]$'

    if [[ ! "$name" =~ $name_regex ]]; then
        log_error "Invalid client name (alphanumeric, hyphens, underscores; 1-64 chars): $name"
        return 1
    fi

    return 0
}

# Validate email address
# Usage: validate_email "user@example.com" || die "Invalid email"
validate_email() {
    local email="$1"

    if [[ -z "$email" ]]; then
        log_error "Email cannot be empty"
        return 1
    fi

    # Basic email regex
    local email_regex='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'

    if [[ ! "$email" =~ $email_regex ]]; then
        log_error "Invalid email format: $email"
        return 1
    fi

    return 0
}

# =============================================================================
# Password Validation
# =============================================================================

# Validate password strength
# Usage: validate_password "MyP@ssw0rd" || die "Weak password"
validate_password() {
    local password="$1"
    local min_length="${2:-12}"

    if [[ -z "$password" ]]; then
        log_error "Password cannot be empty"
        return 1
    fi

    # Length check
    if [[ ${#password} -lt $min_length ]]; then
        log_error "Password must be at least $min_length characters"
        return 1
    fi

    # Complexity checks
    local has_upper=false
    local has_lower=false
    local has_digit=false
    local has_special=false

    [[ "$password" =~ [A-Z] ]] && has_upper=true
    [[ "$password" =~ [a-z] ]] && has_lower=true
    [[ "$password" =~ [0-9] ]] && has_digit=true
    [[ "$password" =~ [^a-zA-Z0-9] ]] && has_special=true

    if [[ "$has_upper" != "true" || "$has_lower" != "true" || "$has_digit" != "true" || "$has_special" != "true" ]]; then
        log_error "Password must contain: uppercase, lowercase, digit, and special character"
        return 1
    fi

    return 0
}

# Generate a secure random password
# Usage: password=$(generate_password 24)
generate_password() {
    local length="${1:-24}"

    # Generate password with all character types
    local password
    password=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | head -c "$length")

    # Ensure at least one of each type (using explicit A-Z/a-z for ASCII-only passwords)
    local upper lower digit special
    # shellcheck disable=SC2018,SC2019
    upper=$(LC_ALL=C tr -dc 'A-Z' < /dev/urandom | head -c 1)
    # shellcheck disable=SC2018,SC2019
    lower=$(LC_ALL=C tr -dc 'a-z' < /dev/urandom | head -c 1)
    digit=$(LC_ALL=C tr -dc '0-9' < /dev/urandom | head -c 1)
    special=$(LC_ALL=C tr -dc '!@#$%^&*()_+-=' < /dev/urandom | head -c 1)

    # Insert required characters at random positions
    password="${upper}${lower}${digit}${special}${password:4}"

    # Shuffle the password
    echo "$password" | fold -w1 | shuf | tr -d '\n'
}

# =============================================================================
# File/Path Validation
# =============================================================================

# Validate file path (safe, no traversal)
# Usage: validate_path "/opt/traefik/config" || die "Invalid path"
validate_path() {
    local path="$1"

    if [[ -z "$path" ]]; then
        log_error "Path cannot be empty"
        return 1
    fi

    # Check for path traversal attempts
    if [[ "$path" =~ \.\. ]]; then
        log_error "Path traversal detected: $path"
        return 1
    fi

    # Must be absolute path
    if [[ "$path" != /* ]]; then
        log_error "Path must be absolute: $path"
        return 1
    fi

    return 0
}

# Validate file exists and is readable
# Usage: validate_file_exists "/etc/config.yml" || die "File not found"
validate_file_exists() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        log_error "File not readable: $file"
        return 1
    fi

    return 0
}

# Validate directory exists and is writable
# Usage: validate_dir_writable "/opt/traefik" || die "Directory not writable"
validate_dir_writable() {
    local dir="$1"

    if [[ ! -d "$dir" ]]; then
        log_error "Directory not found: $dir"
        return 1
    fi

    if [[ ! -w "$dir" ]]; then
        log_error "Directory not writable: $dir"
        return 1
    fi

    return 0
}

# =============================================================================
# Docker Validation
# =============================================================================

# Validate Docker image name
# Usage: validate_docker_image "nginx:1.25" || die "Invalid image"
validate_docker_image() {
    local image="$1"

    if [[ -z "$image" ]]; then
        log_error "Docker image cannot be empty"
        return 1
    fi

    # Basic image name validation (registry/repo:tag format)
    local image_regex='^[a-z0-9][a-z0-9._/-]*[a-z0-9](:[a-zA-Z0-9._-]+)?$'

    if [[ ! "$image" =~ $image_regex ]]; then
        log_error "Invalid Docker image format: $image"
        return 1
    fi

    return 0
}

# Validate Docker network name
# Usage: validate_docker_network "web" || die "Invalid network"
validate_docker_network() {
    local network="$1"

    if [[ -z "$network" ]]; then
        log_error "Network name cannot be empty"
        return 1
    fi

    # Docker network name: alphanumeric, underscore, hyphen; 2-64 chars
    local network_regex='^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}[a-zA-Z0-9]$|^[a-zA-Z0-9]$'

    if [[ ! "$network" =~ $network_regex ]]; then
        log_error "Invalid Docker network name: $network"
        return 1
    fi

    return 0
}

