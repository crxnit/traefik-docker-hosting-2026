# CLAUDE.md - Project Context for AI Assistants

## Project Overview

**Traefik Docker Hosting Platform** - A production-grade, multi-tenant Docker hosting platform built on Traefik v3.6 and Docker Compose. Enables secure, isolated hosting of multiple client applications with automatic SSL certificates, monitoring, and management.

- **Author:** crxnit
- **License:** MIT
- **Target OS:** Debian 11+, Ubuntu 22.04+

## Directory Structure

```
traefik-docker-hosting-2026/
├── docker-compose.yml          # Main Traefik stack (socket-proxy, traefik, whoami)
├── .env.example                # Environment template
├── get.sh                      # Quick one-line installer
├── new-client.sh               # Interactive client creation wizard
├── client-manager.sh           # Interactive client management menu
├── backup.sh                   # Backup/restore automation
├── lib/                        # Reusable shell library modules
│   ├── common.sh               # Logging, utilities, error handling
│   ├── validation.sh           # Input validation (domain, port, etc.)
│   ├── docker.sh               # Docker operations, installation
│   └── security.sh             # SSH/firewall hardening
├── traefik/                    # Traefik configuration
│   ├── traefik.yml             # Static config (entrypoints, providers)
│   └── dynamic/                # Hot-reloadable config
│       ├── security.yml        # Security headers, rate limits, TLS
│       ├── middlewares.yml     # Reusable middleware chains
│       └── dashboard.yml       # Traefik dashboard routing
├── setup/
│   ├── install.sh              # Full platform installation
│   └── harden-server.sh        # Server security hardening
├── clients/
│   └── .template/              # Client stack template
│       ├── docker-compose.yml  # Client app + postgres + redis
│       └── .env.example        # Client config template
└── backups/                    # Backup storage
```

## Key Scripts

| Script | Purpose |
|--------|---------|
| `get.sh` | One-line installer (`curl \| sudo bash`) |
| `setup/install.sh` | Full platform installation |
| `new-client.sh` | Create new client deployments |
| `client-manager.sh` | Deploy/stop/status management |
| `backup.sh` | Backup and restore operations |

## Technology Stack

- **Traefik:** v3.6.6 (reverse proxy, SSL/TLS termination)
- **Docker:** v24.0+ with Compose v2.0+
- **PostgreSQL:** 17-alpine (per-client database)
- **Redis:** 7-alpine (optional per-client cache)
- **Let's Encrypt:** ACME v2 with EC384 keys

## Architecture

### Networks
- `docker-proxy` - Internal, isolated (socket proxy only)
- `traefik-public` - Public-facing (external)
- `backend` - Client internal communication

### Services (Main Stack)
1. **docker-socket-proxy** - Read-only Docker API access for Traefik
2. **traefik** - Reverse proxy with auto-discovery via labels
3. **whoami** - Test service (profile: testing)

### Client Stacks (per-client)
Each client gets isolated stack with:
- **web** - Application container with Traefik labels
- **db** - PostgreSQL with secrets-based credentials
- **redis** - Optional cache (profile: with-cache)

## Security Patterns

- Containers run with `no-new-privileges: true`, `cap_drop: ALL`
- Read-only root filesystems with tmpfs for runtime
- Non-root user execution (UID 1000:1000)
- Docker socket proxy blocks dangerous operations
- Secrets stored in files, not environment variables
- TLS 1.2/1.3 only with modern cipher suites
- Rate limiting and IP allowlists available
- Catch-all routers deny unmatched requests

## Shell Script Conventions

- All scripts use `set -euo pipefail`
- ShellCheck compatible
- Libraries guard against multiple sourcing with `_LOADED` variables
- Consistent logging: `log_info`, `log_warn`, `log_error`, `log_debug`
- Input validation before use
- Color-coded terminal output

## Naming Conventions

- **Client names:** lowercase, alphanumeric, hyphens only
- **Database names:** `{client_name//-/_}_db`
- **Database users:** `{client_name//-/_}_user`
- **Container names:** `{client_name}-web`, `{client_name}-db`

## Common Tasks

### Add a new client
```bash
./new-client.sh
```

### Manage clients
```bash
./client-manager.sh
```

### Backup operations
```bash
./backup.sh backup acme      # Backup certificates
./backup.sh backup client    # Backup client database
./backup.sh list             # List backups
./backup.sh restore <file>   # Restore from backup
```

### Deploy Traefik stack
```bash
docker compose up -d
```

### Test with whoami service
```bash
docker compose --profile testing up -d
```

## Configuration Files

- `.env` - Main environment (ACME_EMAIL, TRAEFIK_DASHBOARD_DOMAIN, etc.)
- `traefik/traefik.yml` - Static Traefik config
- `traefik/dynamic/*.yml` - Dynamic config (hot-reload)
- `clients/{name}/.env` - Per-client config
- `clients/{name}/secrets/*.txt` - Per-client secrets

## Important Notes

1. **Never commit secrets** - All credential files are gitignored
2. **Client directories are gitignored** - Only `.template/` is tracked
3. **Logs are gitignored** - Check `traefik/logs/` for troubleshooting
4. **ACME certificates** - Stored in `traefik/acme/acme.json` (gitignored)
5. **Backups** - Stored in `backups/` directory (gitignored)

---

## Session Notes (2026-01-27)

### Commits Made This Session

1. **Remove HTTP/3 (QUIC) support** (`0f24e31`)
   - Removed `http3: {}` from websecure entrypoint in `traefik/traefik.yml`
   - Removed `experimental.http3: true` section
   - Removed UDP port 443 mapping from `docker-compose.yml`

2. **Use relative path for dynamic config** (`bc12f06`)
   - Changed file provider directory from `/etc/traefik/dynamic` to `./dynamic`
   - Added `working_dir: /etc/traefik` to traefik service in `docker-compose.yml`

3. **Add Traefik troubleshooting guide** (`1e69dbe`)
   - Created `traefik/traefik.md` with common issues and solutions
   - Covers Docker socket issues, SSL, routing, dashboard access

4. **Fix security.yml configuration issues** (`68d892a`)
   - Merged duplicate `http.middlewares` YAML sections (was causing middleware definitions to be overwritten)
   - Updated `HostRegexp` syntax from deprecated v2 format `{host:.+}` to v3 format `.+`

### Configuration Review Summary

All configuration files reviewed and aligned:

| File | Status |
|------|--------|
| `traefik/traefik.yml` | OK |
| `traefik/dynamic/dashboard.yml` | OK |
| `traefik/dynamic/middlewares.yml` | OK |
| `traefik/dynamic/security.yml` | Fixed |

### Middleware Cross-References (All Valid)

- `security-headers@file` -> security.yml
- `dashboard-auth@file` -> security.yml
- `rate-limit@file` -> security.yml
- `gzip-compress@file` -> security.yml
- `admin-ip-allowlist@file` -> security.yml
- `rate-limit-api@file` -> middlewares.yml
- `cache-headers@file` -> middlewares.yml
- `dashboard-redirect@file` -> dashboard.yml

### Current State

- **Unpushed commits:** 1 (`68d892a` - security.yml fixes)
- **Uncommitted changes:** `.gitignore` (adds CLAUDE.md to ignore list)

### Notes

- HTTP/3 has been disabled per user request
- Docker socket is accessed directly (`unix:///var/run/docker.sock`), not via socket proxy
- Socket proxy service exists but is not currently used (see traefik.yml comments)

### Potential TODOs

- Push latest commit to remote
- Consider enabling socket proxy for enhanced security
- Update `dashboard-auth` password hash in security.yml (currently placeholder)
