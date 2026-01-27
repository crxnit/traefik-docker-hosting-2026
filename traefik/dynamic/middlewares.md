# Traefik Middlewares Reference

This document describes all middlewares defined in `middlewares.yml` and their appropriate use cases.

---

## Middleware Chains

Chains combine multiple middlewares into a single reusable unit. Apply chains to routers via labels or dynamic configuration.

### chain-web-standard

**Purpose:** Standard protection for web applications.

**Includes:**
- `security-headers@file` - Security response headers (XSS, clickjacking, HSTS)
- `gzip-compress@file` - Response compression
- `rate-limit@file` - Rate limiting (100 req/s, burst 50)

**Use when:**
- Serving standard web applications
- Public-facing websites with mixed content types

**Avoid when:**
- Serving Server-Sent Events (SSE) or WebSocket connections (compression interferes)
- APIs that need different rate limits
- Static assets that benefit from aggressive caching

**Example:**
```yaml
labels:
  - "traefik.http.routers.myapp.middlewares=chain-web-standard@file"
```

---

### chain-api

**Purpose:** Protection for API endpoints with stricter rate limiting.

**Includes:**
- `security-headers@file` - Security response headers
- `rate-limit-api@file` - Stricter rate limiting (50 req/s, burst 25)

**Use when:**
- REST or GraphQL API endpoints
- Services where abuse could impact backend resources

**Avoid when:**
- Internal service-to-service communication (rate limiting adds latency)
- High-throughput APIs that legitimately exceed 50 req/s per client
- Webhooks or callbacks from trusted services

**Example:**
```yaml
labels:
  - "traefik.http.routers.api.middlewares=chain-api@file"
```

---

### chain-admin

**Purpose:** Secure access for administrative interfaces.

**Includes:**
- `admin-ip-allowlist@file` - IP-based access restriction
- `dashboard-auth@file` - Basic authentication
- `security-headers@file` - Security response headers

**Use when:**
- Admin dashboards and control panels
- Internal management interfaces
- Sensitive configuration endpoints

**Avoid when:**
- IP allowlist is not configured (will block all traffic except localhost)
- Users access admin from dynamic IPs (use VPN instead)
- SSO/OAuth is preferred over basic auth

**Important:** Configure `admin-ip-allowlist` in `security.yml` before use, or all requests will be blocked.

**Example:**
```yaml
labels:
  - "traefik.http.routers.admin.middlewares=chain-admin@file"
```

---

### chain-static

**Purpose:** Optimized delivery for static assets.

**Includes:**
- `gzip-compress@file` - Response compression
- `cache-headers@file` - Aggressive caching (1 year, immutable)

**Use when:**
- Static files with content-hash filenames (e.g., `app.a1b2c3.js`)
- CDN-backed asset delivery
- Images, fonts, and compiled assets

**Avoid when:**
- Files change without URL changes (users will see stale content)
- HTML files or other content that updates frequently
- Development environments where caching hinders testing

**Example:**
```yaml
labels:
  - "traefik.http.routers.static.middlewares=chain-static@file"
```

---

## Individual Middlewares

### rate-limit-api

**Purpose:** Stricter rate limiting for API traffic.

**Configuration:**
| Parameter | Value |
|-----------|-------|
| Average | 50 requests/second |
| Burst | 25 requests |
| Source | Client IP (depth 1) |

**Use when:**
- API endpoints susceptible to abuse
- Protecting expensive backend operations

**Avoid when:**
- Behind a CDN that aggregates client IPs (all traffic appears from CDN IPs)
- Service-to-service calls within trusted network
- Batch processing endpoints that legitimately send bursts

**Note:** The `depth: 1` setting uses the first `X-Forwarded-For` IP. Adjust if your proxy chain differs.

---

### cache-headers

**Purpose:** Add aggressive caching headers for immutable content.

**Configuration:**
```
Cache-Control: public, max-age=31536000, immutable
```

**Use when:**
- Assets with content-hash filenames
- Versioned static resources
- Content that never changes at a given URL

**Avoid when:**
- Dynamic content or APIs
- HTML pages
- Any content that may change without URL change
- Private or user-specific content (use `private` instead of `public`)

---

### cors-permissive

**Purpose:** Allow cross-origin requests from any origin.

**Configuration:**
| Parameter | Value |
|-----------|-------|
| Allowed Methods | GET, POST, PUT, DELETE, OPTIONS |
| Allowed Headers | * (all) |
| Allowed Origins | * (all) |
| Max Age | 24 hours |

**Use when:**
- Public APIs meant for any consumer
- Development and testing environments
- Embeddable widgets or public SDKs

**Avoid when:**
- Production APIs handling sensitive data
- Authenticated endpoints (credentials not allowed with `*` origin)
- APIs that modify server state (CSRF risk)

**Security Warning:** This configuration allows any website to make requests to your API. Do not use for authenticated or sensitive endpoints.

---

### cors-restrictive

**Purpose:** Allow cross-origin requests only from specific trusted origins.

**Configuration:**
| Parameter | Value |
|-----------|-------|
| Allowed Methods | GET, POST, OPTIONS |
| Allowed Headers | Authorization, Content-Type |
| Allowed Origins | https://example.com (customize) |
| Credentials | Allowed |
| Max Age | 24 hours |

**Use when:**
- APIs consumed by known frontend applications
- Authenticated cross-origin requests
- Production environments with defined consumers

**Avoid when:**
- Origins list is not customized (will only allow example.com)
- APIs need to be consumed from multiple unknown origins
- Mobile apps or non-browser clients (CORS is browser-only)

**Important:** Update `accessControlAllowOriginList` with your actual domains before use.

---

### retry-default

**Purpose:** Automatically retry failed requests to backends.

**Configuration:**
| Parameter | Value |
|-----------|-------|
| Attempts | 3 |
| Initial Interval | 100ms |

**Use when:**
- Multiple backend replicas with load balancing
- Transient failures are expected (network blips, rolling deployments)
- Idempotent requests (GET, or properly designed POST/PUT)

**Avoid when:**
- Non-idempotent operations (could cause duplicate orders, payments, etc.)
- Single backend instance (retries will hit the same failing server)
- Long-running requests (retries compound timeout issues)
- Requests with side effects that shouldn't repeat

**Warning:** Only use with idempotent endpoints. Retrying a payment or order creation could result in duplicates.

---

### circuit-breaker

**Purpose:** Stop sending requests to failing backends to allow recovery.

**Configuration:**
- Opens circuit when >30% of responses are 5xx errors
- Expression: `ResponseCodeRatio(500, 600, 0, 600) > 0.30`

**Use when:**
- Protecting against cascade failures
- Backends that need time to recover from overload
- Microservice architectures with dependent services

**Avoid when:**
- Single critical backend with no fallback
- Low-traffic services (small sample size causes false positives)
- Backends where 5xx errors are expected (e.g., validation errors returned as 500)

**Note:** When the circuit opens, Traefik returns 503 Service Unavailable. Ensure clients handle this gracefully.

---

## Middlewares from security.yml

The following middlewares are referenced by chains but defined in `security.yml`:

| Middleware | Purpose |
|------------|---------|
| `security-headers@file` | XSS protection, clickjacking prevention, HSTS, CSP |
| `gzip-compress@file` | Response compression (excludes SSE) |
| `rate-limit@file` | Standard rate limiting (100 req/s) |
| `admin-ip-allowlist@file` | IP-based access control |
| `dashboard-auth@file` | Basic authentication for admin access |

See `security.yml` for configuration details.

---

## Usage Examples

### Web Application with API
```yaml
labels:
  # Frontend
  - "traefik.http.routers.app.middlewares=chain-web-standard@file"
  # API routes
  - "traefik.http.routers.api.middlewares=chain-api@file"
```

### Static Assets with Separate Router
```yaml
labels:
  - "traefik.http.routers.static.rule=Host(`example.com`) && PathPrefix(`/static`)"
  - "traefik.http.routers.static.middlewares=chain-static@file"
```

### Admin Panel
```yaml
labels:
  - "traefik.http.routers.admin.middlewares=chain-admin@file"
```

### API with CORS
```yaml
labels:
  - "traefik.http.routers.api.middlewares=chain-api@file,cors-restrictive@file"
```

### Resilient Backend
```yaml
labels:
  - "traefik.http.routers.backend.middlewares=retry-default@file,circuit-breaker@file"
```
