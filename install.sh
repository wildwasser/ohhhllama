#!/bin/bash
#
# ohhhllama - Master Installer
# Bandwidth-friendly Ollama with download queuing
#
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Paths
INSTALL_DIR="/opt/ohhhllama"
DATA_DIR="/var/lib/ohhhllama"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${CYAN}==>${NC} ${CYAN}$1${NC}"
}

# Header
print_header() {
    echo -e "${CYAN}"
    echo "  ___  _     _     _     _ _                       "
    echo " / _ \| |__ | |__ | |__ | | | __ _ _ __ ___   __ _ "
    echo "| | | | '_ \| '_ \| '_ \| | |/ _\` | '_ \` _ \ / _\` |"
    echo "| |_| | | | | | | | | | | | | (_| | | | | | | (_| |"
    echo " \___/|_| |_|_| |_|_| |_|_|_|\__,_|_| |_| |_|\__,_|"
    echo -e "${NC}"
    echo "Bandwidth-friendly Ollama with download queuing"
    echo "================================================"
    echo ""
}

# Check root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    log_success "Running as root"
}

# Check OS
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS. This script requires Ubuntu/Debian."
        exit 1
    fi
    
    . /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" && "$ID_LIKE" != *"debian"* ]]; then
        log_warn "This script is designed for Ubuntu/Debian. Proceeding anyway..."
    else
        log_success "Detected OS: $PRETTY_NAME"
    fi
}

# Check Python
check_python() {
    if command -v python3 &> /dev/null; then
        PYTHON_VERSION=$(python3 --version 2>&1 | cut -d' ' -f2)
        log_success "Python 3 found: $PYTHON_VERSION"
    else
        log_info "Installing Python 3..."
        apt-get update -qq
        apt-get install -y python3 python3-pip
        log_success "Python 3 installed"
    fi
}

# Install Docker
install_docker() {
    log_step "Checking Docker installation"
    
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | tr -d ',')
        log_success "Docker already installed: $DOCKER_VERSION"
        
        # Ensure Docker is running
        if ! systemctl is-active --quiet docker; then
            log_info "Starting Docker service..."
            systemctl start docker
            systemctl enable docker
        fi
        return 0
    fi
    
    log_info "Docker not found. Installing Docker CE..."
    
    # Run Docker install script
    if [[ -f "$SCRIPT_DIR/scripts/install-docker.sh" ]]; then
        bash "$SCRIPT_DIR/scripts/install-docker.sh"
    else
        # Inline Docker installation
        apt-get update -qq
        apt-get install -y ca-certificates curl gnupg
        
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        apt-get update -qq
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
        systemctl start docker
        systemctl enable docker
    fi
    
    log_success "Docker installed successfully"
}

# Install Ollama container
install_ollama() {
    log_step "Setting up Ollama container"
    
    # Stop existing container if running
    if docker ps -a --format '{{.Names}}' | grep -q '^ollama$'; then
        log_info "Stopping existing Ollama container..."
        docker stop ollama 2>/dev/null || true
        docker rm ollama 2>/dev/null || true
        log_success "Removed existing Ollama container"
    fi
    
    # Pull latest image
    log_info "Pulling Ollama image..."
    docker pull ollama/ollama:latest
    
    # Run container
    log_info "Starting Ollama container on port 11435..."
    docker run -d \
        --name ollama \
        -p 127.0.0.1:11435:11434 \
        -v ollama:/root/.ollama \
        --restart unless-stopped \
        ollama/ollama:latest
    
    # Wait for Ollama to be ready
    log_info "Waiting for Ollama to be ready..."
    for i in {1..30}; do
        if curl -s http://127.0.0.1:11435/api/tags > /dev/null 2>&1; then
            log_success "Ollama is ready on port 11435"
            return 0
        fi
        sleep 1
    done
    
    log_error "Ollama failed to start within 30 seconds"
    docker logs ollama
    exit 1
}

# Install proxy
install_proxy() {
    log_step "Installing ohhhllama proxy"
    
    # Create directories
    log_info "Creating directories..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/scripts"
    mkdir -p "$DATA_DIR"
    
    # Copy files
    log_info "Copying files..."
    cp "$SCRIPT_DIR/proxy/proxy.py" "$INSTALL_DIR/proxy.py"
    cp "$SCRIPT_DIR/scripts/process-queue.sh" "$INSTALL_DIR/scripts/process-queue.sh"
    cp "$SCRIPT_DIR/config/ohhhllama.conf.example" "$INSTALL_DIR/ohhhllama.conf.example"
    
    # Make scripts executable
    chmod +x "$INSTALL_DIR/scripts/process-queue.sh"
    
    # Create default config if not exists
    if [[ ! -f "$INSTALL_DIR/ohhhllama.conf" ]]; then
        cp "$INSTALL_DIR/ohhhllama.conf.example" "$INSTALL_DIR/ohhhllama.conf"
    fi
    
    # Set permissions
    chmod 755 "$INSTALL_DIR"
    chmod 755 "$DATA_DIR"
    
    log_success "Files installed to $INSTALL_DIR"
}

# Install systemd service
install_service() {
    log_step "Installing systemd service"
    
    # Copy service file
    cp "$SCRIPT_DIR/systemd/ollama-proxy.service" /etc/systemd/system/
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable and start service
    systemctl enable ollama-proxy
    systemctl start ollama-proxy
    
    # Verify service is running
    sleep 2
    if systemctl is-active --quiet ollama-proxy; then
        log_success "ollama-proxy service is running"
    else
        log_error "ollama-proxy service failed to start"
        journalctl -u ollama-proxy -n 20
        exit 1
    fi
}

# Install systemd timer for queue processing
install_timer() {
    log_step "Installing systemd timer for queue processing"
    
    # Copy timer and service files
    cp "$SCRIPT_DIR/systemd/ollama-queue.timer" /etc/systemd/system/
    cp "$SCRIPT_DIR/systemd/ollama-queue.service" /etc/systemd/system/
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable and start timer
    systemctl enable --now ollama-queue.timer
    
    log_success "Systemd timer installed (runs at 3 AM daily)"
}

# Verify installation
verify_installation() {
    log_step "Verifying installation"
    
    local errors=0
    
    # Check Docker
    if docker ps | grep -q ollama; then
        log_success "Ollama container running"
    else
        log_error "Ollama container not running"
        ((errors++))
    fi
    
    # Check proxy service
    if systemctl is-active --quiet ollama-proxy; then
        log_success "Proxy service running"
    else
        log_error "Proxy service not running"
        ((errors++))
    fi
    
    # Check proxy responds
    if curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
        log_success "Proxy responding on port 11434"
    else
        log_error "Proxy not responding on port 11434"
        ((errors++))
    fi
    
    # Check timer
    if systemctl is-enabled --quiet ollama-queue.timer 2>/dev/null; then
        log_success "Queue timer enabled"
    else
        log_warn "Queue timer not enabled"
    fi
    
    return $errors
}

# Print success message
print_success() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  ohhhllama installed successfully!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo "Quick test commands:"
    echo ""
    echo -e "  ${CYAN}# List models${NC}"
    echo "  curl http://localhost:11434/api/tags"
    echo ""
    echo -e "  ${CYAN}# Queue a model download${NC}"
    echo "  curl http://localhost:11434/api/pull -d '{\"name\": \"llama2\"}'"
    echo ""
    echo -e "  ${CYAN}# Check queue${NC}"
    echo "  curl http://localhost:11434/api/queue"
    echo ""
    echo -e "  ${CYAN}# Process queue now (instead of waiting for 3 AM)${NC}"
    echo "  sudo systemctl start ollama-queue.service"
    echo ""
    echo "Service management:"
    echo "  sudo systemctl status ollama-proxy"
    echo "  sudo journalctl -u ollama-proxy -f"
    echo ""
    echo "Queue timer:"
    echo "  sudo systemctl list-timers ollama-queue.timer"
    echo "  sudo journalctl -u ollama-queue.service"
    echo ""
    echo "Configuration: /opt/ohhhllama/ohhhllama.conf"
    echo "Queue database: /var/lib/ohhhllama/queue.db"
    echo ""
}

# Main
main() {
    print_header
    
    log_step "Starting installation"
    
    check_root
    check_os
    check_python
    install_docker
    install_ollama
    install_proxy
    install_service
    install_timer
    
    if verify_installation; then
        print_success
    else
        log_error "Installation completed with errors. Check the logs above."
        exit 1
    fi
}

main "$@"
