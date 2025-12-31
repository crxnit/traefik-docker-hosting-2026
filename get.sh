#!/bin/bash
# =============================================================================
# Traefik Docker Hosting Platform - Quick Installer
# =============================================================================
# Usage: curl -sSL https://raw.githubusercontent.com/crxnit/traefik-docker-hosting-2026/main/get.sh | sudo bash
# =============================================================================

set -euo pipefail

REPO_URL="https://github.com/crxnit/traefik-docker-hosting-2026.git"
INSTALL_DIR="/opt/traefik-hosting"

echo ""
echo "  Traefik Docker Hosting Platform - Quick Installer"
echo "  =================================================="
echo ""

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

# Check for git
if ! command -v git &>/dev/null; then
    echo "Installing git..."
    apt-get update -qq && apt-get install -y -qq git
fi

# Clone repository
echo "Cloning repository to ${INSTALL_DIR}..."
if [[ -d "$INSTALL_DIR" ]]; then
    echo "Directory exists. Updating..."
    cd "$INSTALL_DIR" && git pull
else
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

# Run installer
echo ""
echo "Running installation script..."
cd "$INSTALL_DIR"
chmod +x setup/install.sh
./setup/install.sh

echo ""
echo "Installation complete!"
