#!/bin/bash
# =============================================================================
# Traefik Docker Hosting Platform - Configuration Generator
# =============================================================================
# This script generates a deployment package based on user preferences.
# The resulting .zip file contains all necessary configuration files
# with correct folder structure and permissions.
#
# Usage:
#   ./generate-config.sh
#   ./generate-config.sh --output my-config.zip
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="${1:-traefik-hosting-config.zip}"
TEMP_DIR=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

cleanup() {
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
}

trap cleanup EXIT

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local response

    if [[ "$default" == "y" ]]; then
        prompt="${prompt} [Y/n]: "
    else
        prompt="${prompt} [y/N]: "
    fi

    while true; do
        read -rp "$prompt" response
        response="${response:-$default}"
        case "${response,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Main Script
# -----------------------------------------------------------------------------
log_header "Traefik Docker Hosting Platform - Configuration Generator"

echo "This script will generate a deployment package based on your preferences."
echo "The resulting .zip file can be extracted on your server to deploy the platform."
echo ""

# Ask configuration questions
echo -e "${YELLOW}Configuration Options:${NC}"
echo ""

if ask_yes_no "Do you want to use the Docker Socket Proxy? (Recommended for security)" "y"; then
    USE_SOCKET_PROXY=true
    log_info "Docker Socket Proxy: ENABLED"
else
    USE_SOCKET_PROXY=false
    log_warn "Docker Socket Proxy: DISABLED (less secure)"
fi

echo ""

if ask_yes_no "Do you want to use CrowdSec AppSec/WAF?" "n"; then
    USE_CROWDSEC=true
    log_info "CrowdSec AppSec/WAF: ENABLED"
else
    USE_CROWDSEC=false
    log_info "CrowdSec AppSec/WAF: DISABLED"
fi

echo ""
log_header "Generating Configuration Package"

# Create temporary directory
TEMP_DIR="$(mktemp -d)"
BUILD_DIR="${TEMP_DIR}/traefik-hosting"
mkdir -p "${BUILD_DIR}"

# -----------------------------------------------------------------------------
# Create directory structure
# -----------------------------------------------------------------------------
log_info "Creating directory structure..."

mkdir -p "${BUILD_DIR}/traefik/dynamic"
mkdir -p "${BUILD_DIR}/traefik/acme"
mkdir -p "${BUILD_DIR}/traefik/logs"
mkdir -p "${BUILD_DIR}/clients/.template/secrets"
mkdir -p "${BUILD_DIR}/backups"

if [[ "$USE_CROWDSEC" == true ]]; then
    mkdir -p "${BUILD_DIR}/crowdsec/acquis.d"
fi

# -----------------------------------------------------------------------------
# Generate .env.example
# -----------------------------------------------------------------------------
log_info "Generating .env.example..."

cat > "${BUILD_DIR}/.env.example" << 'ENVFILE'
# =============================================================================
# Traefik Docker Hosting Platform - Environment Configuration
# =============================================================================
# Copy this file to .env and customize the values
# NEVER commit the actual .env file to version control
# =============================================================================

# -----------------------------------------------------------------------------
# Let's Encrypt Configuration
# -----------------------------------------------------------------------------
# Email for certificate notifications and account recovery
ACME_EMAIL=admin@example.com

# -----------------------------------------------------------------------------
# Traefik Dashboard
# -----------------------------------------------------------------------------
# Domain for the Traefik dashboard (must have DNS pointing to this server)
TRAEFIK_DASHBOARD_DOMAIN=traefik.example.com

# -----------------------------------------------------------------------------
# Test Services (Optional)
# -----------------------------------------------------------------------------
# Domain for the whoami test service
WHOAMI_DOMAIN=whoami.example.com

# -----------------------------------------------------------------------------
# Backup Configuration
# -----------------------------------------------------------------------------
# Number of days to keep backups
BACKUP_RETENTION_DAYS=30
ENVFILE

if [[ "$USE_CROWDSEC" == true ]]; then
    cat >> "${BUILD_DIR}/.env.example" << 'ENVFILE'

# -----------------------------------------------------------------------------
# CrowdSec Configuration
# -----------------------------------------------------------------------------
# Required: Generate API key with: docker exec crowdsec cscli bouncers add traefik-bouncer
CROWDSEC_BOUNCER_API_KEY=

# Optional: Enroll in CrowdSec Console for web dashboard
# Get key from https://app.crowdsec.net/
# CROWDSEC_ENROLL_KEY=

# Optional: Captcha provider for challenge-based remediation
# Supported: hcaptcha, recaptcha, turnstile
# CROWDSEC_CAPTCHA_SITE_KEY=
# CROWDSEC_CAPTCHA_SECRET_KEY=
ENVFILE
fi

# -----------------------------------------------------------------------------
# Generate docker-compose.yml
# -----------------------------------------------------------------------------
log_info "Generating docker-compose.yml..."

cat > "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
# =============================================================================
# Traefik Docker Hosting Platform - Main Stack
# =============================================================================
# Generated by generate-config.sh
# =============================================================================

services:
COMPOSEFILE

# Add socket proxy if enabled
if [[ "$USE_SOCKET_PROXY" == true ]]; then
    cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
  # ===========================================================================
  # Docker Socket Proxy (Security Layer)
  # ===========================================================================
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: docker-socket-proxy
    restart: always
    privileged: true
    environment:
      CONTAINERS: 1
      SERVICES: 1
      TASKS: 1
      NETWORKS: 1
      NODES: 0
      SECRETS: 0
      CONFIGS: 0
      VOLUMES: 0
      IMAGES: 0
      INFO: 0
      POST: 0
      BUILD: 0
      COMMIT: 0
      EXEC: 0
      AUTH: 0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - docker-proxy
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:2375/version"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 128M

COMPOSEFILE
fi

# Add CrowdSec if enabled
if [[ "$USE_CROWDSEC" == true ]]; then
    cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
  # ===========================================================================
  # CrowdSec Security Engine
  # ===========================================================================
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: crowdsec
    restart: always
    environment:
      COLLECTIONS: >-
        crowdsecurity/traefik
        crowdsecurity/http-cve
        crowdsecurity/appsec-virtual-patching
        crowdsecurity/appsec-generic-rules
      BOUNCER_KEY_traefik: ${CROWDSEC_BOUNCER_API_KEY:-}
    volumes:
      - crowdsec-config:/etc/crowdsec
      - crowdsec-data:/var/lib/crowdsec/data
      - ./crowdsec/acquis.d:/etc/crowdsec/acquis.d:ro
      - ./traefik/logs:/var/log/traefik:ro
    networks:
      - docker-proxy
    healthcheck:
      test: ["CMD", "cscli", "version"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M

COMPOSEFILE
fi

# Add Traefik service
cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
  # ===========================================================================
  # Traefik - Edge Router, Load Balancer, SSL Terminator
  # ===========================================================================
  traefik:
    image: traefik:v3.6.6
    container_name: traefik
    restart: always
COMPOSEFILE

# Add depends_on based on configuration
if [[ "$USE_SOCKET_PROXY" == true && "$USE_CROWDSEC" == true ]]; then
    cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
    depends_on:
      docker-socket-proxy:
        condition: service_healthy
      crowdsec:
        condition: service_healthy
COMPOSEFILE
elif [[ "$USE_SOCKET_PROXY" == true ]]; then
    cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
    depends_on:
      docker-socket-proxy:
        condition: service_healthy
COMPOSEFILE
elif [[ "$USE_CROWDSEC" == true ]]; then
    cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
    depends_on:
      crowdsec:
        condition: service_healthy
COMPOSEFILE
fi

cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    user: "1000:1000"
    working_dir: /etc/traefik
    ports:
      - "80:80"
      - "443:443"
    environment:
      - ACME_EMAIL=${ACME_EMAIL}
      - TRAEFIK_DASHBOARD_DOMAIN=${TRAEFIK_DASHBOARD_DOMAIN}
COMPOSEFILE

if [[ "$USE_CROWDSEC" == true ]]; then
    cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
      - CROWDSEC_BOUNCER_API_KEY=${CROWDSEC_BOUNCER_API_KEY}
COMPOSEFILE
fi

cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
    volumes:
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./traefik/dynamic:/etc/traefik/dynamic:ro
      - ./traefik/acme:/etc/traefik/acme
      - ./traefik/logs:/var/log/traefik
      - traefik-tmp:/tmp
COMPOSEFILE

if [[ "$USE_SOCKET_PROXY" == false ]]; then
    cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
      - /var/run/docker.sock:/var/run/docker.sock:ro
COMPOSEFILE
fi

cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
    networks:
COMPOSEFILE

if [[ "$USE_SOCKET_PROXY" == true ]]; then
    cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
      - docker-proxy
COMPOSEFILE
fi

cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
      - traefik-public
    healthcheck:
      test: ["CMD", "traefik", "healthcheck", "--ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    labels:
      - "traefik.enable=true"
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"

  # ===========================================================================
  # Whoami - Test Service (Optional)
  # ===========================================================================
  whoami:
    image: traefik/whoami:latest
    container_name: whoami
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    user: "65534:65534"
    networks:
      - traefik-public
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:80/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 5s
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.whoami.rule=Host(`${WHOAMI_DOMAIN}`)"
      - "traefik.http.routers.whoami.entrypoints=websecure"
      - "traefik.http.routers.whoami.tls.certresolver=letsencrypt"
COMPOSEFILE

if [[ "$USE_CROWDSEC" == true ]]; then
    cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
      - "traefik.http.routers.whoami.middlewares=chain-web-crowdsec@file"
COMPOSEFILE
else
    cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
      - "traefik.http.routers.whoami.middlewares=chain-web-standard@file"
COMPOSEFILE
fi

cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
      - "traefik.http.services.whoami.loadbalancer.server.port=80"
    deploy:
      resources:
        limits:
          cpus: '0.1'
          memory: 32M
    profiles:
      - testing

# =============================================================================
# Networks
# =============================================================================
networks:
COMPOSEFILE

if [[ "$USE_SOCKET_PROXY" == true ]]; then
    cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
  docker-proxy:
    driver: bridge
    internal: true

COMPOSEFILE
fi

cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
  traefik-public:
    driver: bridge

  backend:
    driver: bridge
    internal: true

# =============================================================================
# Volumes
# =============================================================================
volumes:
  traefik-tmp:
    driver: local
COMPOSEFILE

if [[ "$USE_CROWDSEC" == true ]]; then
    cat >> "${BUILD_DIR}/docker-compose.yml" << 'COMPOSEFILE'
  crowdsec-config:
    driver: local
  crowdsec-data:
    driver: local
COMPOSEFILE
fi

# -----------------------------------------------------------------------------
# Generate traefik.yml
# -----------------------------------------------------------------------------
log_info "Generating traefik/traefik.yml..."

cat > "${BUILD_DIR}/traefik/traefik.yml" << 'TRAEFIKFILE'
# =============================================================================
# Traefik v3.6 Static Configuration
# =============================================================================
# Generated by generate-config.sh
# =============================================================================

global:
  checkNewVersion: true
  sendAnonymousUsage: false

TRAEFIKFILE

if [[ "$USE_CROWDSEC" == true ]]; then
    cat >> "${BUILD_DIR}/traefik/traefik.yml" << 'TRAEFIKFILE'
# =============================================================================
# CrowdSec AppSec/WAF Plugin
# =============================================================================
experimental:
  plugins:
    bouncer:
      moduleName: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
      version: v1.4.7

TRAEFIKFILE
fi

cat >> "${BUILD_DIR}/traefik/traefik.yml" << 'TRAEFIKFILE'
# =============================================================================
# Logging Configuration
# =============================================================================
log:
  level: INFO
  filePath: "/var/log/traefik/traefik.log"
  format: json

accessLog:
  filePath: "/var/log/traefik/access.log"
  format: json
  bufferingSize: 100
  filters:
    statusCodes:
      - "200-299"
      - "400-599"
    retryAttempts: true
    minDuration: "10ms"
  fields:
    defaultMode: keep
    names:
      ClientUsername: drop
    headers:
      defaultMode: keep
      names:
        User-Agent: keep
        Authorization: drop
        Cookie: drop

# =============================================================================
# API and Dashboard
# =============================================================================
api:
  dashboard: true
  insecure: false
  debug: false

ping:
  entryPoint: traefik

# =============================================================================
# Entry Points
# =============================================================================
entryPoints:
  traefik:
    address: ":8082"

  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
    forwardedHeaders:
      insecure: false
      trustedIPs:
        - "127.0.0.1/32"
        - "10.0.0.0/8"
        - "172.16.0.0/12"
        - "192.168.0.0/16"

  websecure:
    address: ":443"
    http:
      tls:
        certResolver: letsencrypt
        domains: []
      middlewares:
        - security-headers@file
    transport:
      respondingTimeouts:
        readTimeout: 30s
        writeTimeout: 30s
        idleTimeout: 180s
      lifeCycle:
        requestAcceptGraceTimeout: 5s
        graceTimeOut: 10s
    forwardedHeaders:
      insecure: false
      trustedIPs:
        - "127.0.0.1/32"
        - "10.0.0.0/8"
        - "172.16.0.0/12"
        - "192.168.0.0/16"

# =============================================================================
# Providers
# =============================================================================
providers:
  docker:
TRAEFIKFILE

if [[ "$USE_SOCKET_PROXY" == true ]]; then
    cat >> "${BUILD_DIR}/traefik/traefik.yml" << 'TRAEFIKFILE'
    endpoint: "tcp://docker-socket-proxy:2375"
TRAEFIKFILE
else
    cat >> "${BUILD_DIR}/traefik/traefik.yml" << 'TRAEFIKFILE'
    endpoint: "unix:///var/run/docker.sock"
TRAEFIKFILE
fi

cat >> "${BUILD_DIR}/traefik/traefik.yml" << 'TRAEFIKFILE'
    exposedByDefault: false
    network: traefik-public
    watch: true

  file:
    directory: "./dynamic"
    watch: true

# =============================================================================
# Certificate Resolvers (Let's Encrypt)
# =============================================================================
certificatesResolvers:
  letsencrypt:
    acme:
      email: "${ACME_EMAIL}"
      storage: "/etc/traefik/acme/acme.json"
      caServer: "https://acme-v02.api.letsencrypt.org/directory"
      keyType: EC384
      httpChallenge:
        entryPoint: web

  letsencrypt-staging:
    acme:
      email: "${ACME_EMAIL}"
      storage: "/etc/traefik/acme/acme-staging.json"
      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"
      keyType: EC384
      httpChallenge:
        entryPoint: web
TRAEFIKFILE

# -----------------------------------------------------------------------------
# Generate dynamic configuration files
# -----------------------------------------------------------------------------
log_info "Generating traefik/dynamic/*.yml..."

# security.yml
cat > "${BUILD_DIR}/traefik/dynamic/security.yml" << 'SECURITYFILE'
# =============================================================================
# Security Middlewares and Configuration
# =============================================================================

http:
  middlewares:
    security-headers:
      headers:
        frameDeny: true
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: "strict-origin-when-cross-origin"
        permissionsPolicy: "camera=(), microphone=(), geolocation=(), payment=()"
        contentSecurityPolicy: "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true
        customResponseHeaders:
          X-Robots-Tag: "noindex, nofollow"
          Server: ""

    rate-limit:
      rateLimit:
        average: 100
        burst: 50
        period: 1s
        sourceCriterion:
          ipStrategy:
            depth: 1

    admin-ip-allowlist:
      ipAllowList:
        sourceRange:
          - "127.0.0.1/32"
          # Add your admin IPs here

    dashboard-auth:
      basicAuth:
        users:
          # Generate: htpasswd -nBb admin password | sed 's/\$/\$\$/g'
          # Default: admin / changeme (CHANGE IN PRODUCTION!)
          - "admin:$$2y$$05$$placeholder.hash.change.me"
        removeHeader: true

    gzip-compress:
      compress:
        excludedContentTypes:
          - "text/event-stream"
        minResponseBodyBytes: 1024

    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true

    security-deny:
      ipAllowList:
        sourceRange:
          - "127.0.0.1/32"

  routers:
    security-catchall-http:
      rule: "HostRegexp(`.+`)"
      entryPoints:
        - web
      priority: 1
      middlewares:
        - security-deny@file
      service: deny-service@file

    security-catchall-https:
      rule: "HostRegexp(`.+`)"
      entryPoints:
        - websecure
      priority: 1
      tls: {}
      middlewares:
        - security-deny@file
      service: deny-service@file

  services:
    deny-service:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:1"

tcp:
  routers:
    tcp-catchall:
      rule: "HostSNI(`*`)"
      entryPoints:
        - websecure
      priority: 1
      service: tcp-blackhole@file

  services:
    tcp-blackhole:
      loadBalancer:
        servers:
          - address: "127.0.0.1:1"

tls:
  options:
    default:
      minVersion: VersionTLS12
      maxVersion: VersionTLS13
      sniStrict: true
      cipherSuites:
        - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
        - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
        - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
      curvePreferences:
        - X25519
        - CurveP384
        - CurveP256

    modern:
      minVersion: VersionTLS13
      sniStrict: true
SECURITYFILE

# middlewares.yml
cat > "${BUILD_DIR}/traefik/dynamic/middlewares.yml" << 'MIDDLEWARESFILE'
# =============================================================================
# Reusable Middleware Chains
# =============================================================================

http:
  middlewares:
    chain-web-standard:
      chain:
        middlewares:
          - security-headers@file
          - gzip-compress@file
          - rate-limit@file

    chain-api:
      chain:
        middlewares:
          - security-headers@file
          - rate-limit-api@file

    chain-admin:
      chain:
        middlewares:
          - admin-ip-allowlist@file
          - dashboard-auth@file
          - security-headers@file

    chain-static:
      chain:
        middlewares:
          - gzip-compress@file
          - cache-headers@file

    rate-limit-api:
      rateLimit:
        average: 50
        burst: 25
        period: 1s
        sourceCriterion:
          ipStrategy:
            depth: 1

    cache-headers:
      headers:
        customResponseHeaders:
          Cache-Control: "public, max-age=31536000, immutable"

    cors-permissive:
      headers:
        accessControlAllowMethods:
          - GET
          - POST
          - PUT
          - DELETE
          - OPTIONS
        accessControlAllowHeaders:
          - "*"
        accessControlAllowOriginList:
          - "*"
        accessControlMaxAge: 86400
        addVaryHeader: true

    cors-restrictive:
      headers:
        accessControlAllowMethods:
          - GET
          - POST
          - OPTIONS
        accessControlAllowHeaders:
          - Authorization
          - Content-Type
        accessControlAllowOriginList:
          - "https://example.com"
        accessControlAllowCredentials: true
        accessControlMaxAge: 86400
        addVaryHeader: true

    retry-default:
      retry:
        attempts: 3
        initialInterval: 100ms

    circuit-breaker:
      circuitBreaker:
        expression: "ResponseCodeRatio(500, 600, 0, 600) > 0.30"
MIDDLEWARESFILE

# dashboard.yml
cat > "${BUILD_DIR}/traefik/dynamic/dashboard.yml" << 'DASHBOARDFILE'
# =============================================================================
# Traefik Dashboard Configuration
# =============================================================================

http:
  routers:
    dashboard:
      rule: "Host(`{{ env \"TRAEFIK_DASHBOARD_DOMAIN\" }}`)"
      entryPoints:
        - websecure
      service: api@internal
      middlewares:
        - chain-admin@file
      tls:
        certResolver: letsencrypt

    dashboard-redirect:
      rule: "Host(`{{ env \"TRAEFIK_DASHBOARD_DOMAIN\" }}`) && PathPrefix(`/`)"
      entryPoints:
        - websecure
      middlewares:
        - dashboard-redirect@file
      service: api@internal
      priority: 1
      tls:
        certResolver: letsencrypt

  middlewares:
    dashboard-redirect:
      redirectRegex:
        regex: "^https://([^/]+)/?$"
        replacement: "https://${1}/dashboard/"
        permanent: true
DASHBOARDFILE

# -----------------------------------------------------------------------------
# Generate CrowdSec configuration if enabled
# -----------------------------------------------------------------------------
if [[ "$USE_CROWDSEC" == true ]]; then
    log_info "Generating CrowdSec configuration..."

    # crowdsec.yml
    cat > "${BUILD_DIR}/traefik/dynamic/crowdsec.yml" << 'CROWDSECFILE'
# =============================================================================
# CrowdSec AppSec/WAF Configuration
# =============================================================================

http:
  middlewares:
    crowdsec-appsec:
      plugin:
        bouncer:
          enabled: true
          logLevel: INFO
          crowdsecMode: stream
          crowdsecLapiKey: "${CROWDSEC_BOUNCER_API_KEY}"
          crowdsecLapiHost: crowdsec:8080
          crowdsecLapiScheme: http
          crowdsecAppsecEnabled: true
          crowdsecAppsecHost: crowdsec:7422
          crowdsecAppsecFailureBlock: true
          crowdsecAppsecUnreachableBlock: true
          crowdsecAppsecBodyLimit: 10485760
          updateIntervalSeconds: 60
          defaultDecisionSeconds: 60

    crowdsec-ip-only:
      plugin:
        bouncer:
          enabled: true
          logLevel: INFO
          crowdsecMode: stream
          crowdsecLapiKey: "${CROWDSEC_BOUNCER_API_KEY}"
          crowdsecLapiHost: crowdsec:8080
          crowdsecLapiScheme: http
          crowdsecAppsecEnabled: false
          updateIntervalSeconds: 60
          defaultDecisionSeconds: 60

    chain-web-crowdsec:
      chain:
        middlewares:
          - crowdsec-appsec@file
          - security-headers@file
          - gzip-compress@file
          - rate-limit@file

    chain-api-crowdsec:
      chain:
        middlewares:
          - crowdsec-appsec@file
          - security-headers@file
          - rate-limit-api@file

    chain-admin-crowdsec:
      chain:
        middlewares:
          - crowdsec-ip-only@file
          - admin-ip-allowlist@file
          - dashboard-auth@file
          - security-headers@file
CROWDSECFILE

    # CrowdSec acquisition configs
    cat > "${BUILD_DIR}/crowdsec/acquis.d/appsec.yaml" << 'APPSECFILE'
# AppSec Component Configuration
appsec_configs:
  - crowdsecurity/appsec-default
labels:
  type: appsec
listen_addr: 0.0.0.0:7422
source: appsec
APPSECFILE

    cat > "${BUILD_DIR}/crowdsec/acquis.d/traefik.yaml" << 'TRAEFIKACQFILE'
# Traefik Access Log Parsing
filenames:
  - /var/log/traefik/access.log
labels:
  type: traefik
source: file
TRAEFIKACQFILE
fi

# -----------------------------------------------------------------------------
# Generate .gitignore
# -----------------------------------------------------------------------------
log_info "Generating .gitignore..."

cat > "${BUILD_DIR}/.gitignore" << 'GITIGNOREFILE'
# Environment and Secrets
.env
.env.local
*.env
.creds
secrets/
**/secrets/*.txt
**/secrets/*.key

# Certificates
traefik/acme/acme.json
traefik/acme/acme-staging.json
*.pem
*.key
*.crt

# Logs
*.log
traefik/logs/

# Backups
backups/
*.tar.gz
*.sql.gz

# Clients (except template)
clients/*/
!clients/.template/

# OS files
.DS_Store
Thumbs.db

# IDE
.idea/
.vscode/
*.swp
GITIGNOREFILE

# -----------------------------------------------------------------------------
# Create placeholder files
# -----------------------------------------------------------------------------
log_info "Creating placeholder files..."

touch "${BUILD_DIR}/traefik/acme/.gitkeep"
touch "${BUILD_DIR}/traefik/logs/.gitkeep"
touch "${BUILD_DIR}/backups/.gitkeep"

# Create empty acme.json with correct permissions
touch "${BUILD_DIR}/traefik/acme/acme.json"
chmod 600 "${BUILD_DIR}/traefik/acme/acme.json"

# -----------------------------------------------------------------------------
# Generate README
# -----------------------------------------------------------------------------
log_info "Generating README.md..."

cat > "${BUILD_DIR}/README.md" << READMEFILE
# Traefik Docker Hosting Platform

Generated configuration package.

## Configuration

- Docker Socket Proxy: $(if [[ "$USE_SOCKET_PROXY" == true ]]; then echo "ENABLED"; else echo "DISABLED"; fi)
- CrowdSec AppSec/WAF: $(if [[ "$USE_CROWDSEC" == true ]]; then echo "ENABLED"; else echo "DISABLED"; fi)

## Quick Start

1. Copy and configure environment:
   \`\`\`bash
   cp .env.example .env
   # Edit .env with your values
   \`\`\`

2. Generate dashboard password:
   \`\`\`bash
   htpasswd -nBb admin YOUR_PASSWORD | sed 's/\$/\$\$/g'
   # Update traefik/dynamic/security.yml with the hash
   \`\`\`
READMEFILE

if [[ "$USE_CROWDSEC" == true ]]; then
    cat >> "${BUILD_DIR}/README.md" << 'READMEFILE'

3. Start CrowdSec and generate API key:
   ```bash
   docker compose up -d crowdsec
   docker exec crowdsec cscli bouncers add traefik-bouncer
   # Add the key to .env as CROWDSEC_BOUNCER_API_KEY
   ```

4. Start all services:
   ```bash
   docker compose up -d
   ```
READMEFILE
else
    cat >> "${BUILD_DIR}/README.md" << 'READMEFILE'

3. Start services:
   ```bash
   docker compose up -d
   ```
READMEFILE
fi

cat >> "${BUILD_DIR}/README.md" << 'READMEFILE'

## Test Deployment

```bash
docker compose --profile testing up -d
curl -I https://whoami.example.com
```

## Documentation

See the docs/ folder for detailed documentation.
READMEFILE

# -----------------------------------------------------------------------------
# Set file permissions
# -----------------------------------------------------------------------------
log_info "Setting file permissions..."

# Secure files
chmod 600 "${BUILD_DIR}/.env.example"
chmod 600 "${BUILD_DIR}/traefik/acme/acme.json"

# Executable scripts (none in this package, but template)
find "${BUILD_DIR}" -name "*.sh" -exec chmod 755 {} \;

# Standard file permissions
find "${BUILD_DIR}" -type f -name "*.yml" -exec chmod 644 {} \;
find "${BUILD_DIR}" -type f -name "*.yaml" -exec chmod 644 {} \;
find "${BUILD_DIR}" -type f -name "*.md" -exec chmod 644 {} \;

# Directory permissions
find "${BUILD_DIR}" -type d -exec chmod 755 {} \;

# -----------------------------------------------------------------------------
# Create ZIP archive
# -----------------------------------------------------------------------------
log_info "Creating ZIP archive..."

# Remove existing output file if present
if [[ -f "${OUTPUT_FILE}" ]]; then
    rm "${OUTPUT_FILE}"
fi

# Create ZIP preserving directory structure and permissions
(cd "${TEMP_DIR}" && zip -r -q "${SCRIPT_DIR}/${OUTPUT_FILE}" "traefik-hosting")

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
log_header "Configuration Package Generated"

echo -e "Output file: ${GREEN}${OUTPUT_FILE}${NC}"
echo ""
echo "Configuration:"
echo -e "  - Docker Socket Proxy: $(if [[ "$USE_SOCKET_PROXY" == true ]]; then echo -e "${GREEN}ENABLED${NC}"; else echo -e "${YELLOW}DISABLED${NC}"; fi)"
echo -e "  - CrowdSec AppSec/WAF: $(if [[ "$USE_CROWDSEC" == true ]]; then echo -e "${GREEN}ENABLED${NC}"; else echo -e "${YELLOW}DISABLED${NC}"; fi)"
echo ""
echo "To deploy:"
echo "  1. Copy ${OUTPUT_FILE} to your server"
echo "  2. Extract: unzip ${OUTPUT_FILE}"
echo "  3. cd traefik-hosting"
echo "  4. cp .env.example .env && edit .env"
echo "  5. Update dashboard password in traefik/dynamic/security.yml"
if [[ "$USE_CROWDSEC" == true ]]; then
echo "  6. docker compose up -d crowdsec"
echo "  7. docker exec crowdsec cscli bouncers add traefik-bouncer"
echo "  8. Add API key to .env"
echo "  9. docker compose up -d"
else
echo "  6. docker compose up -d"
fi
echo ""
log_info "Done!"
