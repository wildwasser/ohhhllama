#!/bin/bash
#
# ohhhllama - Docker Installer
# Installs Docker CE on Ubuntu/Debian
#
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

# Check if Docker is already installed
if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | tr -d ',')
    log_success "Docker is already installed: $DOCKER_VERSION"
    
    # Ensure Docker is running
    if ! systemctl is-active --quiet docker; then
        log_info "Starting Docker service..."
        systemctl start docker
        systemctl enable docker
    fi
    
    exit 0
fi

log_info "Installing Docker CE..."

# Remove old versions
log_info "Removing old Docker versions (if any)..."
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Install prerequisites
log_info "Installing prerequisites..."
apt-get update -qq
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Add Docker's official GPG key
log_info "Adding Docker GPG key..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Set up repository
log_info "Setting up Docker repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
log_info "Installing Docker packages..."
apt-get update -qq
apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Start Docker
log_info "Starting Docker service..."
systemctl start docker
systemctl enable docker

# Add current user to docker group (if not root)
if [[ -n "$SUDO_USER" ]]; then
    log_info "Adding $SUDO_USER to docker group..."
    usermod -aG docker "$SUDO_USER"
    log_info "Note: Log out and back in for group changes to take effect"
fi

# Verify installation
if docker --version &> /dev/null; then
    DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | tr -d ',')
    log_success "Docker installed successfully: $DOCKER_VERSION"
else
    log_error "Docker installation failed"
    exit 1
fi

# Test Docker
log_info "Testing Docker..."
if docker run --rm hello-world &> /dev/null; then
    log_success "Docker is working correctly"
else
    log_error "Docker test failed"
    exit 1
fi

log_success "Docker installation complete!"
