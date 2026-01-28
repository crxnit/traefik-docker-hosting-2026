# Docker Socket Proxy: Security Layer Explained

This document explains what the Docker Socket Proxy does, why it's used in this platform, and the trade-offs involved.

---

## What is the Docker Socket?

The Docker socket (`/var/run/docker.sock`) is a Unix socket that provides access to the Docker daemon API. Any process with access to this socket can:

- Create, start, stop, and delete containers
- Pull and push images
- Access container logs and execute commands inside containers
- Manage networks, volumes, and secrets
- Inspect system information

**The Docker socket is essentially root access to the host system.**

A container with socket access can:
- Mount the host filesystem
- Create privileged containers
- Access other containers' data
- Install rootkits on the host
- Mine cryptocurrency using host resources

---

## Why Does Traefik Need Socket Access?

Traefik uses the Docker provider to automatically discover services. It watches for container events and reads labels to configure routing. This requires:

| Permission | Purpose |
|------------|---------|
| List containers | Discover running services |
| Inspect containers | Read labels for routing rules |
| Watch events | Detect container start/stop |
| List networks | Determine container IP addresses |

Traefik does **not** need to:
- Create or delete containers
- Execute commands in containers
- Pull or push images
- Manage volumes or secrets
- Access sensitive system information

---

## What is the Docker Socket Proxy?

The Docker Socket Proxy (this platform uses [tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)) is a security-hardened proxy that sits between Traefik and the Docker socket.

```
┌─────────────────────────────────────────────────────────────┐
│                      Without Proxy                          │
│                                                             │
│   Traefik ────────────────────────> Docker Socket           │
│              (Full API access)        (Root equivalent)     │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                       With Proxy                            │
│                                                             │
│   Traefik ──────> Socket Proxy ──────> Docker Socket        │
│           (Filtered)      (Allowlist)    (Root equivalent)  │
│                                                             │
│   Only allowed:                                             │
│   - GET /containers                                         │
│   - GET /networks                                           │
│   - GET /services                                           │
│   - GET /events                                             │
└─────────────────────────────────────────────────────────────┘
```

### How It Works

1. The proxy container mounts the real Docker socket
2. It exposes a filtered API on port 2375
3. Environment variables control which endpoints are accessible
4. Traefik connects to the proxy instead of the real socket
5. Dangerous operations are blocked at the proxy level

---

## Configuration in This Platform

From `docker-compose.yml`:

```yaml
docker-socket-proxy:
  image: tecnativa/docker-socket-proxy:latest
  container_name: docker-socket-proxy
  restart: always
  privileged: true
  environment:
    # Read-only access to containers, services, networks
    CONTAINERS: 1
    SERVICES: 1
    TASKS: 1
    NETWORKS: 1
    # Deny access to sensitive endpoints
    NODES: 0
    SECRETS: 0
    CONFIGS: 0
    VOLUMES: 0
    IMAGES: 0
    INFO: 0
    POST: 0      # Blocks all write operations
    BUILD: 0
    COMMIT: 0
    EXEC: 0
    AUTH: 0
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:ro
  networks:
    - docker-proxy  # Internal network only
```

From `traefik.yml`:

```yaml
providers:
  docker:
    endpoint: "tcp://docker-socket-proxy:2375"
```

---

## Pros of Using Docker Socket Proxy

### 1. Principle of Least Privilege

Traefik only gets the permissions it needs. If Traefik is compromised, the attacker cannot:
- Create malicious containers
- Access secrets or configs
- Execute commands in other containers
- Pull malicious images

### 2. Defense in Depth

Even if an attacker bypasses Traefik's security, the proxy provides another barrier. Multiple layers must be compromised for full access.

### 3. Audit Trail Clarity

With a proxy, it's clear exactly what Docker operations are allowed. The configuration serves as documentation of the security policy.

### 4. Network Isolation

The proxy runs on an internal network (`docker-proxy`). The Docker socket is never exposed to the public-facing network.

```yaml
networks:
  docker-proxy:
    internal: true  # No external access
```

### 5. Read-Only Socket Mount

The proxy mounts the socket read-only (`:ro`), adding another layer of protection:

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock:ro
```

### 6. Blocks POST Requests

With `POST: 0`, all write operations are blocked. Traefik can only read container information, never modify anything.

### 7. Container Security Features

The Traefik container itself runs with enhanced security:
- `no-new-privileges: true`
- `cap_drop: ALL`
- `read_only: true`
- Non-root user

The socket proxy means even if these are bypassed, Docker access is limited.

### 8. Compliance Requirements

Many security frameworks (SOC 2, PCI-DSS, HIPAA) require principle of least privilege. A socket proxy provides documented, auditable access control.

---

## Cons of Using Docker Socket Proxy

### 1. Additional Complexity

Another service to manage, monitor, and troubleshoot. Adds cognitive load and potential points of failure.

### 2. Additional Attack Surface

The proxy itself is software that could have vulnerabilities. However, tecnativa/docker-socket-proxy is:
- Based on HAProxy (well-audited)
- Simple codebase
- Actively maintained

### 3. Single Point of Failure

If the proxy crashes, Traefik loses Docker connectivity:
- New containers won't be discovered
- Existing routes continue working (cached)
- Must restart proxy to restore functionality

Mitigation: Health checks and automatic restarts:

```yaml
healthcheck:
  test: ["CMD", "wget", "--spider", "-q", "http://localhost:2375/version"]
  interval: 30s
  timeout: 10s
  retries: 3
```

### 4. Slight Performance Overhead

Requests go through an additional hop. In practice, this is negligible:
- Proxy uses efficient HAProxy
- Docker API calls are infrequent
- Network is local (same host)
- Typical overhead: <1ms per request

### 5. Debugging Complexity

When things go wrong, you must check:
1. Traefik logs
2. Proxy logs
3. Docker daemon logs

Instead of just Traefik and Docker.

### 6. Privileged Container Required

The proxy itself requires `privileged: true` to access the Docker socket properly. This is a security trade-off:

```yaml
docker-socket-proxy:
  privileged: true  # Required for socket access
```

However, this container:
- Has no network exposure (internal only)
- Has no volume mounts besides the socket
- Runs a minimal, audited image

### 7. Resource Consumption

Additional container consuming resources:
- Memory: ~32-128MB
- CPU: Minimal (idle most of the time)
- Disk: ~50MB image

### 8. Configuration Errors

Misconfigured proxy can break Traefik:
- Forgetting to enable `CONTAINERS: 1` breaks discovery
- Forgetting `NETWORKS: 1` breaks IP resolution
- Syntax errors cause silent failures

---

## Alternatives to Docker Socket Proxy

### 1. Direct Socket Access (Less Secure)

Mount the socket directly into Traefik:

```yaml
traefik:
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:ro
```

**Pros:**
- Simpler configuration
- No additional container
- No proxy overhead

**Cons:**
- Full Docker API access if Traefik compromised
- No filtering of dangerous operations
- Violates principle of least privilege

### 2. Docker Socket with SELinux/AppArmor

Use mandatory access control to limit socket operations:

```bash
# Example AppArmor profile (simplified)
profile traefik {
  /var/run/docker.sock rw,
  deny /var/run/docker.sock w,  # Read only
}
```

**Pros:**
- Kernel-level enforcement
- No additional container

**Cons:**
- Complex to configure correctly
- Platform-specific (SELinux on RHEL, AppArmor on Ubuntu)
- Harder to audit and understand
- Not API-level filtering

### 3. File Provider Only (No Docker Access)

Don't use Docker provider; manage routes via files:

```yaml
providers:
  file:
    directory: "./dynamic"
    watch: true
```

**Pros:**
- No Docker socket access needed
- Maximum security

**Cons:**
- No automatic service discovery
- Manual route configuration required
- Loses main benefit of Traefik + Docker

### 4. Kubernetes with RBAC

If using Kubernetes, RBAC provides native permission control:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: traefik-ingress-controller
rules:
  - apiGroups: [""]
    resources: ["services", "endpoints", "secrets"]
    verbs: ["get", "list", "watch"]
```

**Pros:**
- Native Kubernetes security model
- Fine-grained RBAC

**Cons:**
- Requires Kubernetes (overkill for simple deployments)
- Different operational model

---

## Security Comparison

| Aspect | Direct Socket | Socket Proxy | File Provider |
|--------|---------------|--------------|---------------|
| Container creation | Possible | Blocked | N/A |
| Command execution | Possible | Blocked | N/A |
| Secret access | Possible | Blocked | N/A |
| Image operations | Possible | Blocked | N/A |
| Service discovery | Automatic | Automatic | Manual |
| Attack surface | High | Low | Minimal |
| Complexity | Low | Medium | Low |
| Compliance friendly | No | Yes | Yes |

---

## When to Use Docker Socket Proxy

### Use It When:

- Running in production environments
- Security compliance is required
- Multiple services need Docker access
- Defense in depth is a priority
- You want documented, auditable access control

### Skip It When:

- Local development only
- Trusted environment with no external access
- Simplicity is more important than security
- You're using Kubernetes (use RBAC instead)
- File provider is sufficient for your needs

---

## Troubleshooting

### Traefik Can't Connect to Proxy

```bash
# Check proxy is running
docker ps | grep socket-proxy

# Check proxy logs
docker logs docker-socket-proxy

# Test proxy endpoint
docker exec traefik wget -qO- http://docker-socket-proxy:2375/version
```

### Containers Not Discovered

```bash
# Verify CONTAINERS is enabled
docker exec docker-socket-proxy env | grep CONTAINERS

# Check Traefik can list containers
docker exec traefik wget -qO- http://docker-socket-proxy:2375/containers/json
```

### Network Issues

```bash
# Verify both on same network
docker network inspect docker-proxy

# Check network connectivity
docker exec traefik ping docker-socket-proxy
```

---

## Conclusion

The Docker Socket Proxy is a security best practice for production deployments. While it adds complexity, the security benefits outweigh the costs:

| Factor | Weight |
|--------|--------|
| Security improvement | High |
| Complexity added | Low-Medium |
| Performance impact | Negligible |
| Compliance value | High |
| Operational overhead | Low |

**Recommendation:** Use the socket proxy in production. The configuration in this platform is pre-configured and tested. The slight additional complexity is worthwhile for the security benefits.
