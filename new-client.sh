#!/bin/bash
# =============================================================================
# New Client Setup Script
# =============================================================================
# Creates a new client deployment with:
# - Dedicated directory structure
# - Docker Compose configuration
# - Secrets files
# - Deployment script
#
# Usage: sudo ./new-client.sh
# =============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library functions
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/lib/validation.sh"

# =============================================================================
# Configuration
# =============================================================================
readonly CLIENTS_ROOT="${SCRIPT_DIR}/clients"
readonly DEFAULT_APP_PORT="8080"

# =============================================================================
# Functions
# =============================================================================

show_banner() {
    cat << 'EOF'
  _   _                  ____ _ _            _
 | \ | | _____      __  / ___| (_) ___ _ __ | |_
 |  \| |/ _ \ \ /\ / / | |   | | |/ _ \ '_ \| __|
 | |\  |  __/\ V  V /  | |___| | |  __/ | | | |_
 |_| \_|\___| \_/\_/    \____|_|_|\___|_| |_|\__|

  Client Deployment Setup
EOF
    echo ""
}

collect_client_info() {
    log_info "Collecting client information..."

    # Client name
    prompt_input "Enter unique client short name (e.g., my-app)" "" CLIENT_NAME
    CLIENT_NAME=$(sanitize_name "$CLIENT_NAME")

    if [[ -z "$CLIENT_NAME" ]]; then
        die "Client name cannot be empty"
    fi

    if ! validate_client_name "$CLIENT_NAME"; then
        die "Invalid client name"
    fi

    # Check if already exists
    CLIENT_DIR="${CLIENTS_ROOT}/${CLIENT_NAME}"
    if [[ -d "$CLIENT_DIR" ]]; then
        die "Client directory already exists: $CLIENT_DIR"
    fi

    # Domain
    prompt_input "Enter public domain for this client" "" CLIENT_DOMAIN
    if ! validate_domain "$CLIENT_DOMAIN"; then
        die "Invalid domain"
    fi

    # Application port
    prompt_input "Enter internal application port" "$DEFAULT_APP_PORT" APP_PORT
    if ! validate_port "$APP_PORT"; then
        die "Invalid port"
    fi

    # Application image
    prompt_input "Enter Docker image for web app" "node:22-alpine" APP_IMAGE
    if ! validate_docker_image "$APP_IMAGE"; then
        die "Invalid Docker image"
    fi

    # Generate database credentials
    POSTGRES_DB="${CLIENT_NAME//-/_}_db"
    POSTGRES_USER="${CLIENT_NAME//-/_}_user"
    POSTGRES_PASSWORD=$(generate_password 24)

    log_info "Client information collected"
}

create_client_structure() {
    log_info "Creating client directory structure..."

    mkdir -p "$CLIENT_DIR"
    mkdir -p "$CLIENT_DIR/app"
    mkdir -p "$CLIENT_DIR/secrets"
    mkdir -p "$CLIENT_DIR/init-db"
    mkdir -p "$CLIENT_DIR/volumes"

    log_info "Directory structure created: $CLIENT_DIR"
}

create_env_file() {
    log_info "Creating environment file..."

    cat > "$CLIENT_DIR/.env" << EOF
# =============================================================================
# Client Configuration: ${CLIENT_NAME}
# Generated on $(date)
# =============================================================================

# Client Identity
CLIENT_NAME=${CLIENT_NAME}
CLIENT_DOMAIN=${CLIENT_DOMAIN}

# Application Settings
APP_IMAGE=${APP_IMAGE}
APP_PORT=${APP_PORT}

# Database Configuration
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
EOF

    chmod 600 "$CLIENT_DIR/.env"
    log_info "Environment file created"
}

create_secrets_files() {
    log_info "Creating secrets files..."

    echo -n "$POSTGRES_USER" > "$CLIENT_DIR/secrets/postgres_user.txt"
    echo -n "$POSTGRES_PASSWORD" > "$CLIENT_DIR/secrets/postgres_password.txt"

    chmod 600 "$CLIENT_DIR/secrets/"*
    log_info "Secrets files created"
}

create_docker_compose() {
    log_info "Creating Docker Compose file..."

    cat > "$CLIENT_DIR/docker-compose.yml" << 'COMPOSE_EOF'
# =============================================================================
# Client Application Stack
# =============================================================================

services:
  # ===========================================================================
  # Web Application
  # ===========================================================================
  web:
    image: ${APP_IMAGE:-node:22-alpine}
    container_name: ${CLIENT_NAME}-web
    restart: always
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    expose:
      - "${APP_PORT:-8080}"
    environment:
      - NODE_ENV=production
      - APP_PORT=${APP_PORT:-8080}
      - DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${CLIENT_NAME}-db:5432/${POSTGRES_DB}
    volumes:
      - ./app:/app:ro
      - app-tmp:/tmp
    networks:
      - traefik-public
      - backend
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:${APP_PORT:-8080}/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    depends_on:
      db:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${CLIENT_NAME}.rule=Host(`${CLIENT_DOMAIN}`)"
      - "traefik.http.routers.${CLIENT_NAME}.entrypoints=websecure"
      - "traefik.http.routers.${CLIENT_NAME}.tls.certresolver=letsencrypt"
      - "traefik.http.routers.${CLIENT_NAME}.middlewares=chain-web-standard@file"
      - "traefik.http.services.${CLIENT_NAME}.loadbalancer.server.port=${APP_PORT:-8080}"
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 128M
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"

  # ===========================================================================
  # PostgreSQL Database
  # ===========================================================================
  db:
    image: postgres:17-alpine
    container_name: ${CLIENT_NAME}-db
    restart: always
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
      - DAC_OVERRIDE
      - FOWNER
    environment:
      - POSTGRES_USER_FILE=/run/secrets/postgres_user
      - POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password
      - POSTGRES_DB=${POSTGRES_DB}
    secrets:
      - postgres_user
      - postgres_password
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - ./init-db:/docker-entrypoint-initdb.d:ro
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$(cat /run/secrets/postgres_user) -d ${POSTGRES_DB}"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
        reservations:
          cpus: '0.25'
          memory: 256M
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"

# =============================================================================
# Secrets
# =============================================================================
secrets:
  postgres_user:
    file: ./secrets/postgres_user.txt
  postgres_password:
    file: ./secrets/postgres_password.txt

# =============================================================================
# Networks
# =============================================================================
networks:
  traefik-public:
    external: true
  backend:
    driver: bridge
    internal: true

# =============================================================================
# Volumes
# =============================================================================
volumes:
  postgres-data:
    driver: local
  app-tmp:
    driver: local
COMPOSE_EOF

    log_info "Docker Compose file created"
}

create_deploy_script() {
    log_info "Creating deployment script..."

    cat > "$CLIENT_DIR/deploy.sh" << 'DEPLOY_EOF'
#!/bin/bash
# =============================================================================
# Client Deployment Script
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_NAME=$(basename "$SCRIPT_DIR")

echo "Deploying client: $CLIENT_NAME"

# Load environment
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env"
    set +a
else
    echo "Error: .env file not found"
    exit 1
fi

# Verify secrets exist
if [[ ! -f "$SCRIPT_DIR/secrets/postgres_user.txt" ]] || \
   [[ ! -f "$SCRIPT_DIR/secrets/postgres_password.txt" ]]; then
    echo "Error: Secrets files not found in $SCRIPT_DIR/secrets/"
    exit 1
fi

# Start the stack
cd "$SCRIPT_DIR"
docker compose up -d

echo ""
echo "Deployment complete!"
echo "  Client: $CLIENT_NAME"
echo "  Domain: $CLIENT_DOMAIN"
echo ""
echo "Check status: docker compose -f $SCRIPT_DIR/docker-compose.yml ps"
echo "View logs:    docker compose -f $SCRIPT_DIR/docker-compose.yml logs -f"
DEPLOY_EOF

    chmod +x "$CLIENT_DIR/deploy.sh"
    log_info "Deployment script created"
}

create_stop_script() {
    log_info "Creating stop script..."

    cat > "$CLIENT_DIR/stop.sh" << 'STOP_EOF'
#!/bin/bash
# =============================================================================
# Client Stop Script
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_NAME=$(basename "$SCRIPT_DIR")

echo "Stopping client: $CLIENT_NAME"

cd "$SCRIPT_DIR"
docker compose down --remove-orphans

echo "Client stopped: $CLIENT_NAME"
STOP_EOF

    chmod +x "$CLIENT_DIR/stop.sh"
    log_info "Stop script created"
}

create_sample_app() {
    log_info "Creating sample application..."

    # Create a simple health check endpoint
    cat > "$CLIENT_DIR/app/server.js" << 'APP_EOF'
const http = require('http');

const PORT = process.env.APP_PORT || 8080;

const server = http.createServer((req, res) => {
    if (req.url === '/health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'healthy', timestamp: new Date().toISOString() }));
    } else if (req.url === '/') {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(`
            <!DOCTYPE html>
            <html>
            <head><title>${process.env.CLIENT_NAME || 'App'}</title></head>
            <body>
                <h1>Welcome to ${process.env.CLIENT_NAME || 'App'}</h1>
                <p>Your application is running!</p>
                <p>Replace this with your actual application.</p>
            </body>
            </html>
        `);
    } else {
        res.writeHead(404);
        res.end('Not Found');
    }
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`Server running on port ${PORT}`);
});
APP_EOF

    log_info "Sample application created"
}

show_completion() {
    local friendly_name
    friendly_name=$(to_friendly_name "$CLIENT_NAME")

    cat << EOF

=============================================================================
  Client Setup Complete: ${friendly_name}
=============================================================================

Directory: ${CLIENT_DIR}
Domain:    ${CLIENT_DOMAIN}
Port:      ${APP_PORT}

Database Credentials:
  Database: ${POSTGRES_DB}
  User:     ${POSTGRES_USER}
  Password: (saved in ${CLIENT_DIR}/secrets/postgres_password.txt)

NEXT STEPS:

1. Configure DNS:
   Point ${CLIENT_DOMAIN} to your server's IP

2. Add your application code:
   Replace the sample app in: ${CLIENT_DIR}/app/

3. Deploy the client:
   cd ${CLIENT_DIR}
   sudo ./deploy.sh

4. Verify deployment:
   Visit https://${CLIENT_DOMAIN}

=============================================================================

EOF
}

# =============================================================================
# Main
# =============================================================================

main() {
    require_root

    show_banner

    log_info "Starting new client setup..."

    collect_client_info
    create_client_structure
    create_env_file
    create_secrets_files
    create_docker_compose
    create_deploy_script
    create_stop_script
    create_sample_app

    show_completion

    log_info "Client setup completed: $CLIENT_NAME"
}

# Run main function
main "$@"
