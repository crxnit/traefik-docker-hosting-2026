#!/bin/bash
# =============================================================================
# docker.sh - Docker and Docker Compose utility functions
# =============================================================================
# shellcheck shell=bash

# Source common functions if not already loaded
if [[ -z "${_COMMON_LOADED:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/common.sh
    source "${SCRIPT_DIR}/common.sh"
fi

# =============================================================================
# Docker Installation
# =============================================================================

# Install Docker on Debian/Ubuntu
install_docker_debian() {
    local version="${1:-}"

    log_info "Installing Docker on Debian/Ubuntu..."

    # Remove old versions
    local old_packages=(docker.io docker-doc docker-compose podman-docker containerd runc)
    for pkg in "${old_packages[@]}"; do
        if dpkg -l "$pkg" &>/dev/null; then
            apt-get remove -y "$pkg" || true
        fi
    done

    # Install prerequisites
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    # Add Docker's GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add repository
    local codename
    codename=$(get_os_codename)

    cat > /etc/apt/sources.list.d/docker.list << EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable
EOF

    # Install Docker
    apt-get update

    if [[ -n "$version" ]]; then
        apt-get install -y "docker-ce=$version" "docker-ce-cli=$version" containerd.io docker-buildx-plugin docker-compose-plugin
    else
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    log_info "Docker installed successfully"
}

# Add user to docker group
add_user_to_docker() {
    local username="$1"

    if ! getent group docker &>/dev/null; then
        groupadd docker
    fi

    usermod -aG docker "$username"
    log_info "Added $username to docker group (re-login required)"
}

# =============================================================================
# Docker Network Operations
# =============================================================================

# Create Docker network if it doesn't exist
# Usage: ensure_docker_network "web" "bridge"
ensure_docker_network() {
    local network_name="$1"
    local driver="${2:-bridge}"
    local internal="${3:-false}"

    if docker network inspect "$network_name" &>/dev/null; then
        log_debug "Network $network_name already exists"
        return 0
    fi

    local args=("--driver" "$driver")

    if [[ "$internal" == "true" ]]; then
        args+=("--internal")
    fi

    docker network create "${args[@]}" "$network_name"
    log_info "Created Docker network: $network_name"
}

# Remove Docker network
remove_docker_network() {
    local network_name="$1"

    if docker network inspect "$network_name" &>/dev/null; then
        docker network rm "$network_name"
        log_info "Removed Docker network: $network_name"
    else
        log_debug "Network $network_name does not exist"
    fi
}

# =============================================================================
# Docker Compose Operations
# =============================================================================

# Start Docker Compose stack
# Usage: compose_up "/opt/client/docker-compose.yml" "client-name"
compose_up() {
    local compose_file="$1"
    local project_name="${2:-}"
    local env_file="${3:-}"

    local args=("-f" "$compose_file")

    if [[ -n "$project_name" ]]; then
        args+=("-p" "$project_name")
    fi

    if [[ -n "$env_file" && -f "$env_file" ]]; then
        args+=("--env-file" "$env_file")
    fi

    log_info "Starting Docker Compose stack: $compose_file"
    docker compose "${args[@]}" up -d
}

# Stop Docker Compose stack
# Usage: compose_down "/opt/client/docker-compose.yml" true
compose_down() {
    local compose_file="$1"
    local remove_volumes="${2:-false}"
    local project_name="${3:-}"

    local args=("-f" "$compose_file")

    if [[ -n "$project_name" ]]; then
        args+=("-p" "$project_name")
    fi

    args+=("down" "--remove-orphans")

    if [[ "$remove_volumes" == "true" ]]; then
        args+=("-v")
    fi

    log_info "Stopping Docker Compose stack: $compose_file"
    docker compose "${args[@]}"
}

# Restart Docker Compose stack
compose_restart() {
    local compose_file="$1"
    local service="${2:-}"
    local project_name="${3:-}"

    local args=("-f" "$compose_file")

    if [[ -n "$project_name" ]]; then
        args+=("-p" "$project_name")
    fi

    if [[ -n "$service" ]]; then
        docker compose "${args[@]}" restart "$service"
    else
        docker compose "${args[@]}" restart
    fi

    log_info "Restarted Docker Compose stack: $compose_file"
}

# Get status of Docker Compose stack
compose_status() {
    local compose_file="$1"
    local project_name="${2:-}"

    local args=("-f" "$compose_file")

    if [[ -n "$project_name" ]]; then
        args+=("-p" "$project_name")
    fi

    docker compose "${args[@]}" ps
}

# =============================================================================
# Container Operations
# =============================================================================

# Check if container is running
# Usage: is_container_running "traefik" && echo "Running"
is_container_running() {
    local container_name="$1"

    [[ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null)" == "true" ]]
}

# Check if container is healthy
# Usage: is_container_healthy "traefik" && echo "Healthy"
is_container_healthy() {
    local container_name="$1"

    local health_status
    health_status=$(docker inspect -f '{{.State.Health.Status}}' "$container_name" 2>/dev/null)

    [[ "$health_status" == "healthy" ]]
}

# Wait for container to be healthy
# Usage: wait_for_container_healthy "traefik" 60
wait_for_container_healthy() {
    local container_name="$1"
    local timeout="${2:-60}"
    local interval="${3:-2}"
    local elapsed=0

    log_info "Waiting for container $container_name to be healthy..."

    while [[ $elapsed -lt $timeout ]]; do
        if is_container_healthy "$container_name"; then
            log_info "Container $container_name is healthy"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "Timeout waiting for container $container_name to be healthy"
    return 1
}

# Get container logs
# Usage: get_container_logs "traefik" 100
get_container_logs() {
    local container_name="$1"
    local lines="${2:-100}"

    docker logs --tail "$lines" "$container_name"
}

# Execute command in container
# Usage: exec_in_container "traefik" "traefik" "healthcheck"
exec_in_container() {
    local container_name="$1"
    shift

    docker exec "$container_name" "$@"
}

# =============================================================================
# Image Operations
# =============================================================================

# Pull Docker image
pull_image() {
    local image="$1"

    log_info "Pulling Docker image: $image"
    docker pull "$image"
}

# Check if image exists locally
image_exists() {
    local image="$1"

    docker image inspect "$image" &>/dev/null
}

# =============================================================================
# Docker System Operations
# =============================================================================

# Clean up Docker system (unused images, containers, networks)
docker_cleanup() {
    local all="${1:-false}"

    log_info "Cleaning up Docker system..."

    if [[ "$all" == "true" ]]; then
        docker system prune -af --volumes
    else
        docker system prune -f
    fi

    log_info "Docker cleanup complete"
}

# Get Docker disk usage
docker_disk_usage() {
    docker system df
}

# =============================================================================
# Docker Socket Proxy
# =============================================================================

# Deploy Docker Socket Proxy for enhanced security
deploy_socket_proxy() {
    local network="${1:-docker-proxy}"

    log_info "Deploying Docker Socket Proxy..."

    # Create network if it doesn't exist
    ensure_docker_network "$network" "bridge" "true"

    # Deploy socket proxy container
    docker run -d \
        --name docker-socket-proxy \
        --restart always \
        --privileged \
        -e CONTAINERS=1 \
        -e SERVICES=1 \
        -e TASKS=1 \
        -e NETWORKS=1 \
        -e NODES=0 \
        -e SECRETS=0 \
        -e CONFIGS=0 \
        -e VOLUMES=0 \
        -e IMAGES=0 \
        -e INFO=0 \
        -e POST=0 \
        -e BUILD=0 \
        -e COMMIT=0 \
        -e EXEC=0 \
        -e AUTH=0 \
        -v /var/run/docker.sock:/var/run/docker.sock:ro \
        --network "$network" \
        tecnativa/docker-socket-proxy:latest

    log_info "Docker Socket Proxy deployed on network: $network"
}

# Mark as loaded
_DOCKER_LOADED=true
