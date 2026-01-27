# CrowdSec AppSec/WAF Setup Guide

This guide explains how to enable the CrowdSec AppSec/WAF component with Traefik in this hosting environment.

## Overview

[CrowdSec](https://www.crowdsec.net/) is an open-source security suite that provides:

- **IP Reputation:** Block known malicious IPs using community-shared threat intelligence
- **AppSec/WAF:** Application-layer protection with virtual patching, SQL injection, XSS, and path traversal detection
- **Behavior Detection:** Identify and block attack patterns in real-time

The integration uses the [CrowdSec Bouncer Traefik Plugin](https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin).

---

## Prerequisites

- Traefik v3.0+ (this environment uses v3.6.6)
- Docker Compose v2.0+
- CrowdSec plugin v1.2.0+ (for AppSec support)
- CrowdSec Security Engine v1.6.0+

---

## Setup Steps

### Step 1: Enable the CrowdSec Plugin in Traefik

Add the experimental plugins section to `traefik/traefik.yml`:

```yaml
# Add this section to traefik.yml (static configuration)
experimental:
  plugins:
    bouncer:
      moduleName: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
      version: v1.4.7  # Check for latest version
```

**Location:** Add after the `global:` section, before `log:`.

**Important:** Traefik must be restarted after modifying static configuration.

---

### Step 2: Add CrowdSec Service to Docker Compose

Add the following service to `docker-compose.yml`:

```yaml
services:
  # ... existing services ...

  # ===========================================================================
  # CrowdSec Security Engine
  # ===========================================================================
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: crowdsec
    restart: always
    environment:
      # Collections to install on startup
      - COLLECTIONS=crowdsecurity/traefik crowdsecurity/http-cve crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules
      # Bouncer API key (generate after first run, then set here)
      - BOUNCER_KEY_traefik=${CROWDSEC_BOUNCER_API_KEY:-}
      # Optional: Enroll in CrowdSec Console for dashboard
      # - ENROLL_KEY=your-enrollment-key
      # - ENROLL_INSTANCE_NAME=traefik-hosting
    volumes:
      # CrowdSec configuration
      - crowdsec-config:/etc/crowdsec
      # CrowdSec database
      - crowdsec-data:/var/lib/crowdsec/data
      # AppSec acquisition config
      - ./crowdsec/acquis.d:/etc/crowdsec/acquis.d:ro
      # Access to Traefik logs for parsing
      - ./traefik/logs:/var/log/traefik:ro
    networks:
      - docker-proxy
    healthcheck:
      test: ["CMD", "cscli", "version"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
        reservations:
          cpus: '0.1'
          memory: 128M
```

Add the volumes:

```yaml
volumes:
  # ... existing volumes ...
  crowdsec-config:
    driver: local
  crowdsec-data:
    driver: local
```

Update Traefik's `depends_on`:

```yaml
services:
  traefik:
    depends_on:
      docker-socket-proxy:
        condition: service_healthy
      crowdsec:
        condition: service_healthy
```

---

### Step 3: Create CrowdSec Acquisition Configuration

Create the directory and configuration file:

```bash
mkdir -p crowdsec/acquis.d
```

Create `crowdsec/acquis.d/appsec.yaml`:

```yaml
# AppSec Component Configuration
# Enables WAF functionality on port 7422
appsec_configs:
  - crowdsecurity/appsec-default
labels:
  type: appsec
listen_addr: 0.0.0.0:7422
source: appsec
```

Create `crowdsec/acquis.d/traefik.yaml`:

```yaml
# Traefik Access Log Parsing
# Analyzes logs for malicious patterns
filenames:
  - /var/log/traefik/access.log
labels:
  type: traefik
source: file
```

---

### Step 4: Add Environment Variables

Add to your `.env` file:

```bash
# CrowdSec Configuration
CROWDSEC_BOUNCER_API_KEY=your-api-key-here

# Optional: Captcha provider credentials (for captcha remediation)
# CROWDSEC_CAPTCHA_SITE_KEY=your-site-key
# CROWDSEC_CAPTCHA_SECRET_KEY=your-secret-key
```

---

### Step 5: Generate the Bouncer API Key

Start CrowdSec first (without the API key):

```bash
docker compose up -d crowdsec
```

Generate the bouncer API key:

```bash
docker exec crowdsec cscli bouncers add traefik-bouncer
```

**Output:**

```
API key for 'traefik-bouncer':

   aBcDeFgHiJkLmNoPqRsTuVwXyZ123456

Please keep this key since you will not be able to retrieve it!
```

Update `.env` with the generated key:

```bash
CROWDSEC_BOUNCER_API_KEY=aBcDeFgHiJkLmNoPqRsTuVwXyZ123456
```

Restart the stack:

```bash
docker compose down && docker compose up -d
```

---

### Step 6: Apply Middleware to Routes

Use the CrowdSec middlewares in your router configurations:

**Docker labels (per-service):**

```yaml
labels:
  - "traefik.http.routers.myapp.middlewares=chain-web-crowdsec@file"
```

**Dynamic configuration:**

```yaml
http:
  routers:
    my-router:
      rule: "Host(`app.example.com`)"
      middlewares:
        - chain-web-crowdsec@file
      service: my-service
```

---

## Available Middlewares

| Middleware | Description |
|------------|-------------|
| `crowdsec-appsec@file` | Full protection: IP reputation + WAF |
| `crowdsec-ip-only@file` | IP reputation only (lighter weight) |
| `crowdsec-captcha@file` | Challenge suspicious IPs with captcha |
| `chain-web-crowdsec@file` | Standard web chain + CrowdSec WAF |
| `chain-api-crowdsec@file` | API chain + CrowdSec WAF |
| `chain-admin-crowdsec@file` | Admin chain + CrowdSec IP reputation |

---

## Verification

### Check CrowdSec Status

```bash
# View CrowdSec metrics
docker exec crowdsec cscli metrics

# View AppSec-specific metrics
docker exec crowdsec cscli metrics show appsec

# List installed collections
docker exec crowdsec cscli collections list

# List active bouncers
docker exec crowdsec cscli bouncers list

# View recent decisions (blocks)
docker exec crowdsec cscli decisions list
```

### Test WAF Protection

```bash
# This should be blocked (path traversal attempt)
curl -I "https://your-domain.com/../../../etc/passwd"

# This should be blocked (SQL injection attempt)
curl -I "https://your-domain.com/?id=1'%20OR%20'1'='1"

# This should be blocked (common sensitive file)
curl -I "https://your-domain.com/.env"
```

Expected response: `HTTP/1.1 403 Forbidden`

### View Alerts

```bash
docker exec crowdsec cscli alerts list
```

---

## Configuration Options

### Middleware Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `enabled` | false | Enable the middleware |
| `logLevel` | INFO | Log verbosity (DEBUG/INFO/ERROR) |
| `crowdsecMode` | live | Mode: live, stream, alone, appsec |
| `crowdsecLapiKey` | - | Bouncer API key (required) |
| `crowdsecLapiHost` | crowdsec:8080 | LAPI endpoint |
| `crowdsecAppsecEnabled` | false | Enable AppSec/WAF |
| `crowdsecAppsecHost` | crowdsec:7422 | AppSec endpoint |
| `crowdsecAppsecFailureBlock` | false | Block on AppSec errors |
| `crowdsecAppsecUnreachableBlock` | false | Block if AppSec unavailable |
| `crowdsecAppsecBodyLimit` | 10485760 | Max request body (10MB) |
| `updateIntervalSeconds` | 60 | Decision cache refresh (stream mode) |

### CrowdSec Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| `stream` | Cache decisions, periodic sync | Production (recommended) |
| `live` | Query LAPI per request | Low traffic, real-time needs |
| `appsec` | AppSec only, no IP reputation | WAF-only protection |
| `alone` | No LAPI, local decisions only | Offline/isolated environments |

---

## Troubleshooting

### CrowdSec container not starting

Check logs:

```bash
docker logs crowdsec
```

Common issues:
- Missing collections (check COLLECTIONS environment variable)
- Permission issues on mounted volumes

### Bouncer connection failures

Verify the API key:

```bash
docker exec crowdsec cscli bouncers list
```

Check Traefik logs for connection errors:

```bash
docker logs traefik 2>&1 | grep -i crowdsec
```

### AppSec not blocking requests

1. Verify AppSec is running:

```bash
docker exec crowdsec cscli metrics show appsec
```

2. Check acquisition is configured:

```bash
docker exec crowdsec cat /etc/crowdsec/acquis.d/appsec.yaml
```

3. Verify collections are installed:

```bash
docker exec crowdsec cscli collections list | grep appsec
```

### High latency

- Switch to `stream` mode (caches decisions)
- Consider adding Redis for shared decision cache
- Reduce `crowdsecAppsecBodyLimit` if processing large uploads

---

## Security Considerations

### When to use each middleware

| Scenario | Recommended Middleware |
|----------|----------------------|
| Public websites | `chain-web-crowdsec@file` |
| Public APIs | `chain-api-crowdsec@file` |
| Admin panels | `chain-admin-crowdsec@file` |
| Internal services | `crowdsec-ip-only@file` or none |
| File upload endpoints | Increase `crowdsecAppsecBodyLimit` |

### When NOT to use CrowdSec AppSec

- **Health check endpoints:** Exclude from WAF to avoid blocking monitoring
- **Webhook receivers:** Trusted sources may trigger false positives
- **Large file uploads:** Set appropriate body limits or bypass
- **Internal service-to-service:** Unnecessary overhead

### Bypass for trusted sources

Add trusted IPs that should bypass CrowdSec:

```yaml
crowdsec-appsec:
  plugin:
    bouncer:
      enabled: true
      clientTrustedIPs:
        - "10.0.0.0/8"      # Internal network
        - "172.16.0.0/12"   # Docker networks
```

---

## Optional: CrowdSec Console Integration

Enroll your instance in the [CrowdSec Console](https://app.crowdsec.net/) for:

- Web-based dashboard
- Alert visualization
- Multi-instance management

```bash
# Get enrollment key from console, then:
docker exec crowdsec cscli console enroll YOUR_ENROLLMENT_KEY
```

---

## References

- [CrowdSec Documentation](https://docs.crowdsec.net/)
- [CrowdSec AppSec Quickstart for Traefik](https://docs.crowdsec.net/docs/next/appsec/quickstart/traefik/)
- [Traefik Bouncer Plugin](https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin)
- [Traefik Plugin Catalog](https://plugins.traefik.io/plugins/6335346ca4caa9ddeffda116/crowdsec-bouncer-traefik-plugin)
- [CrowdSec Hub (Collections & Parsers)](https://hub.crowdsec.net/)
