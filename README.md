# Traefik Docker Hosting Platform

A secure, modular multi-client hosting platform using Traefik v3.6 as a reverse proxy with Docker Compose for isolated client deployments.

## Features

- **Traefik v3.6.6** - Latest stable release with all security patches
- **Automatic SSL** - Let's Encrypt certificates with HTTP/3 support
- **Multi-Layer Security**:
  - Docker Socket Proxy for secure Docker API access
  - TCP/HTTP catch-all protection against direct IP access
  - Strict TLS configuration with modern cipher suites
  - Security headers middleware (HSTS, CSP, XSS protection)
  - Rate limiting and circuit breaker
- **Multi-Tenant Isolation**:
  - Separate Docker Compose stacks per client
  - Network segmentation (public/backend)
  - Individual database instances with secrets management
- **Health Checks** - All containers include health check configurations
- **Resource Limits** - CPU and memory limits on all containers
- **Modular Scripts** - Reusable shell library functions
- **Backup Automation** - Scripts for backing up ACME certs and databases

## Quick Start

### One-Line Install

```bash
curl -fsSL https://raw.githubusercontent.com/crxnit/traefik-docker-hosting-2026/main/get.sh | sudo bash
```

### Manual Installation

```bash
git clone https://github.com/crxnit/traefik-docker-hosting-2026.git
cd traefik-docker-hosting-2026
sudo ./setup/install.sh
```

### Configure DNS

Point your domains to the server's IP address:
- `traefik.yourdomain.com` - Traefik dashboard
- `app.yourdomain.com` - Client applications

### Add a Client

```bash
sudo ./new-client.sh
```

### Manage Clients

```bash
sudo ./client-manager.sh
```

## Directory Structure

```
traefik-docker-hosting-2026/
├── docker-compose.yml          # Main Traefik stack
├── .env.example                # Environment template
├── new-client.sh               # Create new client
├── client-manager.sh           # Manage clients
├── backup.sh                   # Backup automation
├── lib/                        # Shared shell functions
│   ├── common.sh               # Logging, utilities
│   ├── validation.sh           # Input validation
│   ├── docker.sh               # Docker operations
│   └── security.sh             # Security hardening
├── traefik/                    # Traefik configuration
│   ├── traefik.yml             # Static config
│   ├── dynamic/                # Dynamic configs
│   │   ├── security.yml        # Security middlewares
│   │   ├── dashboard.yml       # Dashboard routing
│   │   └── middlewares.yml     # Reusable chains
│   ├── acme/                   # SSL certificates
│   └── logs/                   # Access/error logs
├── setup/                      # Setup scripts
│   ├── install.sh              # Platform installation
│   └── harden-server.sh        # Server hardening
├── clients/                    # Client deployments
│   └── .template/              # Client template
└── backups/                    # Backup storage
```

## Security Features

### Network Architecture

```
                    ┌─────────────────────┐
                    │    Internet         │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │  Traefik (ports     │
                    │  80, 443, 443/udp)  │
                    └──────────┬──────────┘
                               │
          ┌────────────────────┼────────────────────┐
          │                    │                    │
┌─────────▼─────────┐ ┌────────▼────────┐ ┌────────▼────────┐
│  Client A Stack   │ │  Client B Stack │ │  Client C Stack │
│  ┌─────┐ ┌─────┐  │ │  ┌─────┐ ┌────┐ │ │  ┌─────┐ ┌────┐ │
│  │ Web │ │ DB  │  │ │  │ Web │ │ DB │ │ │  │ Web │ │ DB │ │
│  └─────┘ └─────┘  │ │  └─────┘ └────┘ │ │  └─────┘ └────┘ │
└───────────────────┘ └─────────────────┘ └─────────────────┘
```

### Container Security

- `no-new-privileges` - Prevents privilege escalation
- `cap_drop: ALL` - Drops all Linux capabilities
- `read_only: true` - Read-only root filesystem
- Non-root user execution
- Resource limits (CPU, memory)

### TLS Configuration

- TLS 1.2/1.3 only
- Strong cipher suites
- Strict SNI validation
- HSTS enabled

## Commands Reference

### Installation

```bash
# Full platform installation
sudo ./setup/install.sh

# Server hardening only
sudo ./setup/harden-server.sh
```

### Client Management

```bash
# Create new client
sudo ./new-client.sh

# Interactive client manager
sudo ./client-manager.sh

# Deploy specific client
cd clients/my-client && sudo ./deploy.sh

# Stop client
cd clients/my-client && sudo ./stop.sh
```

### Backup Operations

```bash
# Backup everything
sudo ./backup.sh --all

# Backup Traefik certificates
sudo ./backup.sh --traefik

# Backup specific client database
sudo ./backup.sh --client my-client

# List backups
sudo ./backup.sh --list

# Restore from backup
sudo ./backup.sh --restore backups/traefik_acme_20250101_120000.tar.gz

# Cleanup old backups
sudo ./backup.sh --cleanup
```

### Docker Operations

```bash
# View Traefik logs
docker compose logs -f traefik

# Restart Traefik
docker compose restart traefik

# View all running containers
docker compose ps

# Stop everything
docker compose down
```

## Configuration

### Environment Variables

Copy `.env.example` to `.env` and configure:

```bash
# Let's Encrypt email
ACME_EMAIL=admin@example.com

# Traefik dashboard domain
TRAEFIK_DASHBOARD_DOMAIN=traefik.example.com

# Backup retention (days)
BACKUP_RETENTION_DAYS=30
```

### Adding Custom Middlewares

Create a file in `traefik/dynamic/`:

```yaml
# traefik/dynamic/custom.yml
http:
  middlewares:
    my-custom-middleware:
      headers:
        customResponseHeaders:
          X-Custom-Header: "value"
```

## Requirements

- Debian 11+ or Ubuntu 22.04+
- Docker 24.0+
- Docker Compose v2+
- Root access

## License

MIT License - See [LICENSE](LICENSE) file

## Contributing

1. Fork the repository
2. Create a feature branch
3. Run ShellCheck on all scripts
4. Submit a pull request

## Support

For issues and feature requests, please use the GitHub issue tracker.
