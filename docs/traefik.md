# Traefik Troubleshooting Guide

Common issues and solutions for the Traefik Docker Hosting Platform.

## Docker Socket Connection Issues

### Error: Cannot connect to `unix:///var/run/docker.sock`

**Symptoms:**
- Traefik fails to start
- Error messages about socket connection refused or permission denied
- No containers are discovered by Traefik

**Solutions:**

1. **Check Docker socket permissions**

   The Traefik container runs as user `1000:1000`. Ensure the Docker socket is accessible:

   ```bash
   # Check socket permissions
   ls -la /var/run/docker.sock

   # Add user to docker group (if running without socket proxy)
   sudo usermod -aG docker $USER
   ```

2. **Verify Docker is running**

   ```bash
   sudo systemctl status docker
   sudo systemctl start docker
   ```

3. **Check volume mount in docker-compose.yml**

   If using direct socket access, ensure the socket is mounted:

   ```yaml
   volumes:
     - /var/run/docker.sock:/var/run/docker.sock:ro
   ```

4. **Use Docker Socket Proxy (Recommended)**

   The socket proxy provides secure, read-only access. Update `traefik.yml`:

   ```yaml
   providers:
     docker:
       endpoint: "tcp://docker-socket-proxy:2375"
   ```

   Ensure the socket proxy service is healthy:

   ```bash
   docker compose ps docker-socket-proxy
   docker compose logs docker-socket-proxy
   ```

5. **SELinux/AppArmor issues (Linux)**

   On systems with SELinux enabled:

   ```bash
   # Check if SELinux is blocking access
   sudo ausearch -m avc -ts recent

   # Temporarily set permissive mode for testing
   sudo setenforce 0
   ```

---

## Container Discovery Issues

### Containers not appearing in Traefik

**Solutions:**

1. **Verify labels are correct**

   Containers must have `traefik.enable=true`:

   ```yaml
   labels:
     - "traefik.enable=true"
     - "traefik.http.routers.myapp.rule=Host(`example.com`)"
   ```

2. **Check network connectivity**

   Containers must be on the `traefik-public` network:

   ```yaml
   networks:
     - traefik-public
   ```

3. **Verify exposedByDefault setting**

   In `traefik.yml`, `exposedByDefault: false` requires explicit opt-in:

   ```yaml
   providers:
     docker:
       exposedByDefault: false  # Containers need traefik.enable=true
   ```

4. **Check Traefik logs**

   ```bash
   docker compose logs -f traefik
   # Or check the log file
   tail -f traefik/logs/traefik.log
   ```

---

## SSL/TLS Certificate Issues

### Let's Encrypt certificates not being issued

**Solutions:**

1. **Verify ACME email is set**

   Check `.env` file:

   ```bash
   ACME_EMAIL=your-email@example.com
   ```

2. **Check HTTP challenge accessibility**

   Port 80 must be accessible from the internet for HTTP-01 challenge:

   ```bash
   # Test from external server
   curl -I http://yourdomain.com/.well-known/acme-challenge/test
   ```

3. **Check ACME storage permissions**

   ```bash
   ls -la traefik/acme/
   # File should be writable by UID 1000
   chmod 600 traefik/acme/acme.json
   chown 1000:1000 traefik/acme/acme.json
   ```

4. **Use staging server for testing**

   In `traefik.yml`, switch to staging to avoid rate limits:

   ```yaml
   certificatesResolvers:
     letsencrypt:
       acme:
         caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"
   ```

5. **Check rate limits**

   Let's Encrypt has rate limits. Check https://letsencrypt.org/docs/rate-limits/

---

## Routing Issues

### 404 Not Found errors

**Solutions:**

1. **Verify Host rule matches request**

   ```yaml
   labels:
     - "traefik.http.routers.myapp.rule=Host(`example.com`)"
   ```

   Test with curl:

   ```bash
   curl -H "Host: example.com" http://localhost
   ```

2. **Check entrypoint configuration**

   Ensure router uses correct entrypoint:

   ```yaml
   labels:
     - "traefik.http.routers.myapp.entrypoints=websecure"
   ```

3. **Verify service port**

   Traefik needs to know which port to forward to:

   ```yaml
   labels:
     - "traefik.http.services.myapp.loadbalancer.server.port=8080"
   ```

### 502 Bad Gateway errors

**Solutions:**

1. **Check if backend service is running**

   ```bash
   docker compose ps
   docker compose logs myapp
   ```

2. **Verify network connectivity**

   ```bash
   # Enter Traefik container and test connectivity
   docker compose exec traefik wget -qO- http://myapp:8080/health
   ```

3. **Check service health**

   Ensure backend passes health checks before Traefik routes to it.

---

## Dashboard Access Issues

### Cannot access Traefik dashboard

**Solutions:**

1. **Verify dashboard is enabled**

   In `traefik.yml`:

   ```yaml
   api:
     dashboard: true
     insecure: false
   ```

2. **Check dashboard routing**

   Review `traefik/dynamic/dashboard.yml` for correct Host rule.

3. **Verify authentication middleware**

   Dashboard should be protected. Check BasicAuth credentials:

   ```bash
   # Generate password hash
   htpasswd -nb admin yourpassword
   ```

4. **Check firewall rules**

   The internal entrypoint (port 8082) should not be exposed externally.

---

## Performance Issues

### Slow response times

**Solutions:**

1. **Check resource limits**

   In `docker-compose.yml`:

   ```yaml
   deploy:
     resources:
       limits:
         cpus: '1.0'
         memory: 512M
   ```

2. **Review access logs**

   ```bash
   tail -f traefik/logs/access.log | jq .
   ```

3. **Check for retry loops**

   Review middleware configuration for infinite retry scenarios.

---

## Useful Commands

```bash
# View Traefik logs
docker compose logs -f traefik

# Check Traefik configuration
docker compose exec traefik traefik healthcheck

# Restart Traefik
docker compose restart traefik

# Validate docker-compose.yml
docker compose config

# List all routers (via API)
curl -s http://localhost:8082/api/http/routers | jq .

# List all services (via API)
curl -s http://localhost:8082/api/http/services | jq .
```

---

## Getting Help

- Traefik Documentation: https://doc.traefik.io/traefik/
- Traefik GitHub Issues: https://github.com/traefik/traefik/issues
- Community Forum: https://community.traefik.io/
