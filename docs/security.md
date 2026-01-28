# Traefik Security Configuration Reference

This document describes all security middlewares, routers, services, and TLS configuration defined in `security.yml`.

---

## Table of Contents

- [Middlewares](#middlewares)
  - [security-headers](#security-headers)
  - [rate-limit](#rate-limit)
  - [admin-ip-allowlist](#admin-ip-allowlist)
  - [dashboard-auth](#dashboard-auth)
  - [gzip-compress](#gzip-compress)
  - [error-pages](#error-pages)
  - [redirect-to-https](#redirect-to-https)
  - [strip-api-prefix](#strip-api-prefix)
  - [security-deny](#security-deny)
- [Catch-All Routers](#catch-all-routers)
- [Deny Service](#deny-service)
- [TCP Security](#tcp-security)
- [TLS Configuration](#tls-configuration)

---

## Middlewares

### security-headers

**Purpose:** Add security-related HTTP response headers to protect against common web vulnerabilities.

**Configuration:**

| Header | Value | Protection |
|--------|-------|------------|
| `X-Frame-Options` | DENY | Clickjacking |
| `X-Content-Type-Options` | nosniff | MIME sniffing |
| `X-XSS-Protection` | 1; mode=block | XSS (legacy browsers) |
| `Referrer-Policy` | strict-origin-when-cross-origin | Referrer leakage |
| `Permissions-Policy` | camera=(), microphone=(), geolocation=(), payment=() | Feature restrictions |
| `Content-Security-Policy` | default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline' | XSS, injection |
| `Strict-Transport-Security` | max-age=31536000; includeSubDomains; preload | Downgrade attacks |
| `X-Robots-Tag` | noindex, nofollow | Search engine indexing |
| `Server` | (empty) | Server fingerprinting |

**Use when:**
- All public-facing web applications
- Any service handling user data
- Default choice for most deployments

**Avoid when:**
- Application needs to be embedded in iframes (disable `frameDeny`)
- Application requires inline scripts from CDNs (adjust CSP)
- Search engines should index the site (remove `X-Robots-Tag`)
- Legacy clients require older TLS (disable HSTS temporarily during migration)

**Customization notes:**
- **CSP:** The default policy is restrictive. Applications using external scripts, fonts, or CDNs need a customized policy.
- **HSTS Preload:** Once submitted to browser preload lists, this cannot be easily reversed. Test thoroughly first.
- **X-Robots-Tag:** Remove this header for public sites that should appear in search results.

**Example - Allowing iframes from same origin:**
```yaml
security-headers-iframe:
  headers:
    customFrameOptionsValue: "SAMEORIGIN"
    # ... other headers
```

---

### rate-limit

**Purpose:** Protect against abuse by limiting request rates per client IP.

**Configuration:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| Average | 100 | Requests per second allowed |
| Burst | 50 | Extra requests allowed in bursts |
| Period | 1s | Time window |
| Source | IP (depth 1) | Uses first X-Forwarded-For IP |

**Use when:**
- Public-facing web applications
- APIs exposed to the internet
- Login and authentication endpoints

**Avoid when:**
- Behind a CDN or proxy that aggregates IPs (all traffic appears from few IPs)
- Internal service-to-service communication
- Webhooks from trusted services (GitHub, Stripe, etc.)
- Batch processing endpoints with legitimate high-volume clients

**Tuning guidance:**
- **depth: 1** assumes one proxy layer. Adjust for your infrastructure:
  - `depth: 0` - Use direct client IP (no proxy)
  - `depth: 2` - Skip two proxy IPs (e.g., CDN + load balancer)
- Monitor 429 responses to detect false positives
- Consider separate rate limits for authenticated vs anonymous users

**Example - Higher limits for specific route:**
```yaml
labels:
  - "traefik.http.routers.api.middlewares=rate-limit-high@file"
```

---

### admin-ip-allowlist

**Purpose:** Restrict access to administrative interfaces by source IP address.

**Configuration:**

| Parameter | Value |
|-----------|-------|
| Allowed IPs | 127.0.0.1/32 (localhost only by default) |

**Use when:**
- Admin dashboards and control panels
- Database management interfaces (pgAdmin, phpMyAdmin)
- Internal tooling not meant for public access
- CI/CD webhook endpoints

**Avoid when:**
- Admins access from dynamic IPs (use VPN instead)
- Cloud environments with ephemeral IPs
- IP allowlist is not configured (blocks all external traffic)
- Zero-trust environments (prefer identity-based access)

**Configuration required:** Add your admin IPs before using this middleware:

```yaml
admin-ip-allowlist:
  ipAllowList:
    sourceRange:
      - "127.0.0.1/32"
      - "YOUR_OFFICE_IP/32"
      - "YOUR_VPN_RANGE/24"
```

**Security note:** IP allowlisting is a defense-in-depth measure, not a primary authentication mechanism. Always combine with proper authentication.

---

### dashboard-auth

**Purpose:** Protect administrative interfaces with HTTP Basic Authentication.

**Configuration:**

| Parameter | Value |
|-----------|-------|
| Algorithm | bcrypt |
| Remove Header | true (credentials not forwarded to backend) |

**Current credentials:**
- Username: `admin`
- Password: See `session-notes.md` or generate new

**Use when:**
- Traefik dashboard access
- Simple admin interfaces
- Development environments
- Quick protection layer combined with IP allowlisting

**Avoid when:**
- Public-facing applications (basic auth UX is poor)
- SSO/OAuth is available
- Multiple users need different access levels
- Audit logging of user actions is required
- High-security environments (basic auth transmits credentials with every request)

**Generating new credentials:**

```bash
# Generate bcrypt hash with escaped $ for Docker/YAML
htpasswd -nBb username password | sed 's/\$/\$\$/g'
```

**Multiple users:**

```yaml
dashboard-auth:
  basicAuth:
    users:
      - "admin:$$2y$$..."
      - "readonly:$$2y$$..."
```

**Security note:** Basic auth credentials are Base64-encoded (not encrypted) in transit. Always use with HTTPS.

---

### gzip-compress

**Purpose:** Compress HTTP responses to reduce bandwidth and improve load times.

**Configuration:**

| Parameter | Value |
|-----------|-------|
| Excluded Types | text/event-stream |
| Minimum Size | 1024 bytes |

**Use when:**
- HTML, CSS, JavaScript, and JSON responses
- Text-based API responses
- Any compressible content over 1KB

**Avoid when:**
- Server-Sent Events (SSE) - already excluded by default
- WebSocket connections (not HTTP)
- Already-compressed content (images, videos, zip files)
- Real-time streaming where latency matters more than bandwidth
- Very small responses (compression overhead exceeds benefit)

**Content types automatically excluded:**
- Images (JPEG, PNG, GIF, WebP)
- Videos (MP4, WebM)
- Compressed files (gzip, zip, br)

**Performance note:** Compression uses CPU. For very high-traffic services, consider pre-compressing static assets or using a CDN.

---

### error-pages

**Purpose:** Display custom error pages for server errors.

**Configuration:**

| Parameter | Value |
|-----------|-------|
| Status Codes | 500-599 |
| Query | /{status}.html |
| Service | error-pages@docker |

**Use when:**
- Production deployments requiring branded error pages
- User-facing applications where default errors are unprofessional
- Compliance requirements for error disclosure

**Avoid when:**
- `error-pages@docker` service is not deployed (will cause additional errors)
- API endpoints (return JSON errors instead)
- Development environments (default errors aid debugging)
- Custom error handling exists in the application

**Setup required:** Deploy an error pages service:

```yaml
error-pages:
  image: tarampampam/error-pages:latest
  labels:
    - "traefik.enable=true"
    - "traefik.http.services.error-pages.loadbalancer.server.port=8080"
```

---

### redirect-to-https

**Purpose:** Redirect HTTP requests to HTTPS with a permanent redirect.

**Configuration:**

| Parameter | Value |
|-----------|-------|
| Scheme | https |
| Permanent | true (301 redirect) |

**Use when:**
- Manually configuring HTTP to HTTPS redirection
- Overriding entrypoint-level redirects for specific routes

**Avoid when:**
- Global redirect is already configured in `traefik.yml` entrypoints (current setup)
- Testing without SSL certificates
- Internal services that don't need encryption
- Health check endpoints that must respond on HTTP

**Note:** The current configuration already redirects HTTP to HTTPS at the entrypoint level (`traefik.yml`), so this middleware is typically unnecessary unless you need route-specific behavior.

---

### strip-api-prefix

**Purpose:** Remove `/api` prefix before forwarding requests to backend services.

**Configuration:**

| Parameter | Value |
|-----------|-------|
| Prefixes | /api |

**Use when:**
- Backend expects requests at root path but is exposed at `/api`
- Multiple services share a domain with path-based routing
- API gateway pattern where public path differs from internal path

**Avoid when:**
- Backend already handles the `/api` prefix
- Application routing depends on the full path
- Webhook callbacks that include path in signatures

**Example:**
```
Request:  GET https://example.com/api/users
Backend:  GET http://backend/users
```

**Important:** Ensure your backend doesn't also strip the prefix, or paths will be incorrect.

---

### security-deny

**Purpose:** Deny all requests except from localhost. Used by catch-all routers.

**Configuration:**

| Parameter | Value |
|-----------|-------|
| Allowed IPs | 127.0.0.1/32 only |

**Use when:**
- Catch-all routers to reject unmatched requests
- Temporarily disabling a route
- Internal-only endpoints

**Avoid when:**
- Applied to routes that should be publicly accessible
- Testing from external networks

**Note:** This middleware is intentionally restrictive. It's designed to be used with catch-all routers to reject traffic that doesn't match any configured route.

---

## Catch-All Routers

### security-catchall-http / security-catchall-https

**Purpose:** Capture and deny requests that don't match any configured route.

**Configuration:**

| Parameter | HTTP | HTTPS |
|-----------|------|-------|
| Rule | HostRegexp(`.+`) | HostRegexp(`.+`) |
| Priority | 1 (lowest) | 1 (lowest) |
| Middleware | security-deny | security-deny |
| TLS | No | Yes (default cert) |

**Security benefits:**
- Prevents enumeration of hosted domains
- Blocks requests to the server IP directly
- Rejects requests with forged Host headers
- Returns 403 instead of exposing backend errors

**Use when:**
- Multi-tenant hosting environments
- Servers with multiple domains
- Defense against host header attacks

**Avoid when:**
- Single-domain deployments (unnecessary complexity)
- Default behavior of returning 404 is acceptable
- Debugging routing issues (temporarily disable to see what's happening)

**Note:** These routers use priority 1 (lowest), so they only match if no other router handles the request.

---

## Deny Service

### deny-service

**Purpose:** Backend target for denied requests that returns connection refused.

**Configuration:**

```yaml
deny-service:
  loadBalancer:
    servers:
      - url: "http://127.0.0.1:1"
```

**Behavior:** Requests routed here fail because nothing listens on 127.0.0.1:1. Combined with the security-deny middleware, this effectively returns a 403 Forbidden.

**Note:** This is an internal implementation detail of the catch-all security pattern. Do not route legitimate traffic to this service.

---

## TCP Security

### tcp-catchall / tcp-blackhole

**Purpose:** Capture and drop TCP connections that don't match any configured SNI.

**Configuration:**

| Parameter | Value |
|-----------|-------|
| Rule | HostSNI(`*`) |
| Priority | 1 (lowest) |
| Target | 127.0.0.1:1 (blackhole) |

**Use when:**
- Hosting multiple TLS services on the same port
- Preventing TLS handshake with unknown SNI
- Defense against SNI-based enumeration

**Avoid when:**
- Single service deployment
- Clients don't send SNI (very old clients)
- Debugging TLS connection issues

**Behavior:** TCP connections with unrecognized SNI are forwarded to a non-listening port, causing connection reset.

---

## TLS Configuration

### default (TLS Options)

**Purpose:** Secure TLS configuration supporting TLS 1.2 and 1.3.

**Configuration:**

| Parameter | Value |
|-----------|-------|
| Min Version | TLS 1.2 |
| Max Version | TLS 1.3 |
| SNI Strict | true |
| Cipher Suites | ECDHE + AES-GCM or ChaCha20 only |
| Curves | X25519, P-384, P-256 |

**Cipher suites (TLS 1.2):**
- TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
- TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
- TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
- TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
- TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
- TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256

**Use when:**
- Default for all HTTPS traffic
- Compliance with modern security standards (PCI-DSS, HIPAA)
- General web hosting

**Avoid when:**
- Legacy clients require TLS 1.0/1.1 (not recommended)
- Specific compliance requires different cipher order

**Compatibility:** Supported by all modern browsers and clients. Excludes:
- Internet Explorer on Windows XP
- Android 4.3 and earlier
- Java 7 and earlier

---

### modern (TLS Options)

**Purpose:** Maximum security TLS 1.3-only configuration.

**Configuration:**

| Parameter | Value |
|-----------|-------|
| Min Version | TLS 1.3 |
| SNI Strict | true |

**Use when:**
- High-security environments
- Internal services with controlled clients
- New deployments without legacy requirements
- APIs consumed by modern clients only

**Avoid when:**
- Public websites needing broad compatibility
- Enterprise environments with older corporate clients
- IoT devices or embedded systems
- Mobile apps supporting older OS versions

**To apply:**
```yaml
labels:
  - "traefik.http.routers.secure.tls.options=modern@file"
```

**Compatibility:** Requires:
- Chrome 70+, Firefox 63+, Safari 12.1+, Edge 79+
- OpenSSL 1.1.1+
- Java 11+
- Python 3.7+ with updated ssl module

---

## Security Best Practices

### Recommended middleware chains

| Use Case | Middlewares |
|----------|-------------|
| Public web app | security-headers, gzip-compress, rate-limit |
| Public API | security-headers, rate-limit |
| Admin interface | admin-ip-allowlist, dashboard-auth, security-headers |
| Static assets | gzip-compress |

### Defense in depth

Layer multiple security controls:

1. **Network level:** Firewall, VPC, security groups
2. **TLS level:** Modern cipher suites, certificate validation
3. **Application level:** Rate limiting, authentication, input validation
4. **Response level:** Security headers, error handling

### Regular maintenance

- Rotate `dashboard-auth` credentials periodically
- Review `admin-ip-allowlist` when team changes
- Monitor rate limit 429 responses for tuning
- Check TLS configuration against current best practices
