#!/bin/bash
#
# ohhhllama - Proxy Installer
# Installs the proxy service
#
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Paths
INSTALL_DIR="/opt/ohhhllama"
DATA_DIR="/var/lib/ohhhllama"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# Create directories
log_info "Creating directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/scripts"
mkdir -p "$DATA_DIR"

# Copy files
log_info "Copying files..."

if [[ -f "$SCRIPT_DIR/proxy/proxy.py" ]]; then
    cp "$SCRIPT_DIR/proxy/proxy.py" "$INSTALL_DIR/proxy.py"
    log_success "Copied proxy.py"
else
    log_error "proxy.py not found at $SCRIPT_DIR/proxy/proxy.py"
    exit 1
fi

if [[ -f "$SCRIPT_DIR/scripts/process-queue.sh" ]]; then
    cp "$SCRIPT_DIR/scripts/process-queue.sh" "$INSTALL_DIR/scripts/process-queue.sh"
    chmod +x "$INSTALL_DIR/scripts/process-queue.sh"
    log_success "Copied process-queue.sh"
fi

if [[ -f "$SCRIPT_DIR/config/ohhhllama.conf.example" ]]; then
    cp "$SCRIPT_DIR/config/ohhhllama.conf.example" "$INSTALL_DIR/ohhhllama.conf.example"
    log_success "Copied config example"
fi

# Create default config if not exists
if [[ ! -f "$INSTALL_DIR/ohhhllama.conf" ]]; then
    cp "$INSTALL_DIR/ohhhllama.conf.example" "$INSTALL_DIR/ohhhllama.conf"
    log_success "Created default config"
fi

# Set permissions
chmod 755 "$INSTALL_DIR"
chmod 755 "$DATA_DIR"
chmod 644 "$INSTALL_DIR/proxy.py"
chmod 644 "$INSTALL_DIR/ohhhllama.conf"

# Install systemd service
log_info "Installing systemd service..."

if [[ -f "$SCRIPT_DIR/systemd/ollama-proxy.service" ]]; then
    cp "$SCRIPT_DIR/systemd/ollama-proxy.service" /etc/systemd/system/
else
    # Create service file inline
    cat > /etc/systemd/system/ollama-proxy.service << 'EOF'
[Unit]
Description=ohhhllama - Ollama Proxy with Download Queue
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/ohhhllama/proxy.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=-/opt/ohhhllama/ohhhllama.conf

# Security hardening
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/ohhhllama
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
fi

log_success "Installed systemd service"

# Install timer and service for queue processing
log_info "Installing systemd timer..."

if [[ -f "$SCRIPT_DIR/systemd/ollama-queue.timer" ]]; then
    cp "$SCRIPT_DIR/systemd/ollama-queue.timer" /etc/systemd/system/
    log_success "Installed ollama-queue.timer"
fi

if [[ -f "$SCRIPT_DIR/systemd/ollama-queue.service" ]]; then
    cp "$SCRIPT_DIR/systemd/ollama-queue.service" /etc/systemd/system/
    log_success "Installed ollama-queue.service"
fi

# Reload systemd
systemctl daemon-reload

# Enable and start service
log_info "Enabling and starting service..."
systemctl enable ollama-proxy
systemctl start ollama-proxy

# Enable and start timer
log_info "Enabling queue timer..."
systemctl enable --now ollama-queue.timer

# Wait and verify
sleep 2

if systemctl is-active --quiet ollama-proxy; then
    log_success "ollama-proxy service is running"
else
    log_error "Service failed to start"
    journalctl -u ollama-proxy -n 20
    exit 1
fi

# Test proxy
log_info "Testing proxy..."
if curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
    log_success "Proxy is responding on port 11434"
else
    log_error "Proxy is not responding"
    exit 1
fi

echo ""
log_success "Proxy installation complete!"
echo ""
echo "Service management:"
echo "  sudo systemctl status ollama-proxy"
echo "  sudo systemctl restart ollama-proxy"
echo "  sudo journalctl -u ollama-proxy -f"
echo ""
echo "Queue timer:"
echo "  sudo systemctl list-timers ollama-queue.timer"
echo "  sudo systemctl start ollama-queue.service  # Run queue now"
echo "  sudo journalctl -u ollama-queue.service"
echo ""
echo "Configuration: $INSTALL_DIR/ohhhllama.conf"
echo "Queue database: $DATA_DIR/queue.db"
