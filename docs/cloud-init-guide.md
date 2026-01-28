# Cloud-Init Best Practices for Platform Deployment

This guide discusses what should and should not be included in cloud-init scripts when deploying the Traefik Docker Hosting Platform.

---

## Overview

Cloud-init is a standard for early initialization of cloud instances. It runs once during first boot and handles system configuration before the instance is fully available. Understanding its limitations is crucial for reliable deployments.

### Key Characteristics of Cloud-Init

- Runs during early boot (before SSH is available)
- Typically has a timeout (default 120-300 seconds)
- Limited error visibility during execution
- No interactive input possible
- Network may not be fully configured initially
- Runs as root

---

## What TO DO in Cloud-Init

### 1. System Package Updates

```yaml
package_update: true
package_upgrade: true
```

**Why:** Security patches should be applied before the system is accessible. This is a one-time operation that benefits from running early.

### 2. Essential Package Installation

```yaml
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - git
  - ufw
  - fail2ban
```

**Why:** These are quick to install and required for subsequent steps. Package installation is idempotent and well-suited to cloud-init.

### 3. User Creation and SSH Key Setup

```yaml
users:
  - name: deploy
    groups: [sudo, docker]
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... user@example.com
```

**Why:** Users must exist before SSH access. This is a core cloud-init function with robust support.

### 4. Basic Firewall Configuration

```yaml
runcmd:
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 22/tcp
  - ufw allow 80/tcp
  - ufw allow 443/tcp
  - ufw --force enable
```

**Why:** Firewall rules are simple, quick to apply, and critical for security from first boot.

### 5. SSH Hardening

```yaml
runcmd:
  - sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
  - sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
  - systemctl restart sshd
```

**Why:** SSH must be hardened before the instance is accessible. Simple sed commands are reliable.

### 6. Docker Repository Setup

```yaml
runcmd:
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

**Why:** Adding repositories and installing Docker is well-understood and reliable. Docker is required for everything else.

### 7. Directory Structure Creation

```yaml
runcmd:
  - mkdir -p /opt/traefik-hosting
  - chown deploy:deploy /opt/traefik-hosting
```

**Why:** Creating directories is instant and has no failure modes.

### 8. Timezone and Locale Configuration

```yaml
timezone: UTC
locale: en_US.UTF-8
```

**Why:** System locale must be set early. Built-in cloud-init support.

### 9. Hostname Configuration

```yaml
hostname: traefik-host
fqdn: traefik.example.com
manage_etc_hosts: true
```

**Why:** Hostname must be set before services start. Native cloud-init function.

### 10. Swap Configuration

```yaml
swap:
  filename: /swapfile
  size: 2G
```

**Why:** Swap should exist before memory-intensive operations. Quick to set up.

---

## What NOT TO DO in Cloud-Init

### 1. Clone Git Repositories

```yaml
# AVOID
runcmd:
  - git clone https://github.com/user/repo.git /opt/app
```

**Problems:**
- Network may be unstable during early boot
- Git operations can hang or timeout
- Repository unavailability causes complete deployment failure
- No retry logic in cloud-init
- SSH key-based clones are problematic (keys not yet configured)

**Alternative:** Use a separate provisioning script run via SSH after instance is up.

### 2. Run Docker Compose

```yaml
# AVOID
runcmd:
  - cd /opt/app && docker compose up -d
```

**Problems:**
- Image pulls can exceed cloud-init timeout
- Docker daemon may not be fully ready
- Network-dependent operations are unreliable
- Failures are silent and hard to debug
- No compose file exists yet (see git clone above)

**Alternative:** Run compose commands after SSH access is available, with proper error handling.

### 3. Generate SSL Certificates

```yaml
# AVOID
runcmd:
  - certbot certonly --standalone -d example.com
```

**Problems:**
- Requires DNS to be configured (may not be ready)
- Let's Encrypt rate limits make retries problematic
- HTTP challenge requires ports to be open and reachable
- Timeout issues with ACME protocol

**Alternative:** Let Traefik handle certificate generation after deployment, or run certbot interactively.

### 4. Database Initialization

```yaml
# AVOID
runcmd:
  - docker exec db psql -c "CREATE DATABASE app;"
```

**Problems:**
- Container may not be running yet
- Database initialization can be slow
- Migrations should be versioned and repeatable
- Error handling is critical for data operations

**Alternative:** Use init scripts within containers or run migrations as a separate deployment step.

### 5. Interactive Configuration

```yaml
# AVOID
runcmd:
  - ./configure --interactive
```

**Problems:**
- Cloud-init has no TTY
- Cannot respond to prompts
- Script will hang indefinitely

**Alternative:** Use non-interactive flags or pre-configure with environment variables/config files.

### 6. Download Large Files

```yaml
# AVOID
runcmd:
  - wget https://example.com/large-file.tar.gz
  - tar xzf large-file.tar.gz
```

**Problems:**
- Network timeouts during download
- No resume capability
- Fills up disk if partially downloaded
- Cloud-init timeout exceeded

**Alternative:** Use pre-built images or download after instance is running.

### 7. Build Container Images

```yaml
# AVOID
runcmd:
  - docker build -t myapp .
```

**Problems:**
- Build times are unpredictable
- Requires source code (see git clone issues)
- Resource-intensive during boot
- Can exceed timeouts

**Alternative:** Use pre-built images from a registry.

### 8. Complex Shell Scripts

```yaml
# AVOID
runcmd:
  - |
    for i in $(seq 1 10); do
      if curl -s http://service:8080/health; then
        break
      fi
      sleep 10
    done
```

**Problems:**
- Debugging is extremely difficult
- No logging visibility
- Complex logic belongs in proper scripts
- Retry loops can hang indefinitely

**Alternative:** Write a proper script, test it, and run it after SSH access.

### 9. Secret Generation and Storage

```yaml
# AVOID
runcmd:
  - openssl rand -base64 32 > /opt/app/.env
  - echo "DB_PASSWORD=$(openssl rand -base64 32)" >> /opt/app/.env
```

**Problems:**
- Secrets visible in cloud-init logs
- Cloud-init logs may be accessible to other users
- No secure secret management
- Secrets may be included in instance snapshots

**Alternative:** Use a secrets manager (Vault, AWS Secrets Manager) or generate secrets interactively.

### 10. Service Health Checks

```yaml
# AVOID
runcmd:
  - until curl -s localhost:8080/health; do sleep 5; done
```

**Problems:**
- Can loop forever if service fails
- No timeout handling
- Blocks subsequent cloud-init modules
- No alerting on failure

**Alternative:** Use proper health checks in systemd units or container orchestration.

---

## Recommended Cloud-Init Structure

```yaml
#cloud-config

# =============================================================================
# System Configuration (Safe for cloud-init)
# =============================================================================

hostname: traefik-host
timezone: UTC
locale: en_US.UTF-8

package_update: true
package_upgrade: true

packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - git
  - ufw
  - fail2ban
  - unattended-upgrades

users:
  - name: deploy
    groups: [sudo]
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - ssh-ed25519 AAAA...

# =============================================================================
# Run Commands (Quick, reliable operations only)
# =============================================================================

runcmd:
  # Docker installation
  - curl -fsSL https://get.docker.com | sh
  - usermod -aG docker deploy

  # Firewall
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 22/tcp
  - ufw allow 80/tcp
  - ufw allow 443/tcp
  - ufw --force enable

  # SSH hardening
  - sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
  - sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
  - sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
  - systemctl restart sshd

  # Prepare directory
  - mkdir -p /opt/traefik-hosting
  - chown deploy:deploy /opt/traefik-hosting

  # Signal completion
  - touch /opt/traefik-hosting/.cloud-init-complete

# =============================================================================
# Final Message
# =============================================================================

final_message: |
  Cloud-init complete. System ready for application deployment.
  Connect via SSH and run the installation script:
    ssh deploy@$HOSTNAME
    cd /opt/traefik-hosting
    curl -fsSL https://raw.githubusercontent.com/user/repo/main/get.sh | bash
```

---

## Post-Cloud-Init Deployment Script

After cloud-init completes, run this via SSH:

```bash
#!/bin/bash
set -euo pipefail

# Wait for cloud-init to complete
while [ ! -f /opt/traefik-hosting/.cloud-init-complete ]; do
  echo "Waiting for cloud-init..."
  sleep 5
done

cd /opt/traefik-hosting

# Clone repository (with retries)
for i in {1..3}; do
  git clone https://github.com/user/traefik-docker-hosting.git . && break
  echo "Git clone failed, retrying in 10s..."
  sleep 10
done

# Configure environment
cp .env.example .env
# Edit .env with actual values...

# Start services
docker compose up -d

# Verify deployment
docker compose ps
```

---

## Cloud Provider Considerations

### AWS EC2

- Use IMDSv2 for metadata access
- cloud-init logs: `/var/log/cloud-init-output.log`
- Consider using Systems Manager for post-boot configuration

### DigitalOcean

- Droplet metadata available at `169.254.169.254`
- cloud-init logs: `/var/log/cloud-init-output.log`
- Use reserved IPs before DNS configuration

### Hetzner Cloud

- Good cloud-init support
- Logs at `/var/log/cloud-init-output.log`
- Consider using private networks for internal traffic

### Vultr

- cloud-init support varies by image
- Test thoroughly before production use

---

## Debugging Cloud-Init

### View Logs

```bash
# Full output log
cat /var/log/cloud-init-output.log

# Cloud-init specific log
cat /var/log/cloud-init.log

# Status
cloud-init status --long
```

### Re-run Cloud-Init (Testing Only)

```bash
# Clean and re-run (destroys state)
sudo cloud-init clean
sudo cloud-init init
sudo cloud-init modules --mode=config
sudo cloud-init modules --mode=final
```

### Validate Config

```bash
cloud-init schema --config-file user-data.yaml
```

---

## Summary

### DO in Cloud-Init

| Task | Reason |
|------|--------|
| Package updates | Quick, essential for security |
| User creation | Must happen before SSH |
| SSH key setup | Required for access |
| Firewall rules | Simple, critical for security |
| Docker installation | Well-tested, reliable |
| Directory creation | Instant, no failure modes |
| System configuration | Native cloud-init function |

### DON'T in Cloud-Init

| Task | Reason |
|------|--------|
| Git clone | Network unreliable, can hang |
| Docker compose up | Timeout issues, dependency on clone |
| SSL certificates | DNS/network dependencies |
| Database setup | Requires running services |
| Large downloads | Timeout, network issues |
| Image builds | Unpredictable timing |
| Secret generation | Security concerns |
| Health checks | Can hang indefinitely |

### Golden Rule

**Cloud-init should prepare the system for deployment, not perform the deployment itself.**

The goal is a secure, accessible system where the actual application deployment can be performed reliably via SSH with proper error handling, logging, and retry logic.
