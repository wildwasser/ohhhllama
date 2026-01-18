#!/bin/bash
#
# ohhhllama - Uninstaller
# Clean removal of ohhhllama components
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

# Check root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Ask yes/no question
ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -r -p "$prompt" response
    response=${response:-$default}
    
    [[ "$response" =~ ^[Yy]$ ]]
}

# Header
print_header() {
    echo -e "${RED}"
    echo "  ___  _     _     _     _ _                       "
    echo " / _ \| |__ | |__ | |__ | | | __ _ _ __ ___   __ _ "
    echo "| | | | '_ \| '_ \| '_ \| | |/ _\` | '_ \` _ \ / _\` |"
    echo "| |_| | | | | | | | | | | | | (_| | | | | | | (_| |"
    echo " \___/|_| |_|_| |_|_| |_|_|_|\__,_|_| |_| |_|\__,_|"
    echo -e "${NC}"
    echo "Uninstaller"
    echo "==========="
    echo ""
}

# Stop services
stop_services() {
    log_step "Stopping services"
    
    # Stop and disable queue timer
    if systemctl is-active --quiet ollama-queue.timer 2>/dev/null; then
        log_info "Stopping ollama-queue timer..."
        systemctl disable --now ollama-queue.timer
        log_success "Stopped and disabled ollama-queue timer"
    else
        log_info "ollama-queue timer not running"
    fi
    
    # Stop proxy service
    if systemctl is-active --quiet ollama-proxy 2>/dev/null; then
        log_info "Stopping ollama-proxy service..."
        systemctl stop ollama-proxy
        log_success "Stopped ollama-proxy"
    else
        log_info "ollama-proxy service not running"
    fi
    
    # Disable proxy service
    if systemctl is-enabled --quiet ollama-proxy 2>/dev/null; then
        log_info "Disabling ollama-proxy service..."
        systemctl disable ollama-proxy
        log_success "Disabled ollama-proxy"
    fi
}

# Remove systemd files
remove_systemd() {
    log_step "Removing systemd files"
    
    if [[ -f /etc/systemd/system/ollama-proxy.service ]]; then
        rm -f /etc/systemd/system/ollama-proxy.service
        log_success "Removed ollama-proxy.service"
    fi
    
    if [[ -f /etc/systemd/system/ollama-queue.timer ]]; then
        rm -f /etc/systemd/system/ollama-queue.timer
        log_success "Removed ollama-queue.timer"
    fi
    
    if [[ -f /etc/systemd/system/ollama-queue.service ]]; then
        rm -f /etc/systemd/system/ollama-queue.service
        log_success "Removed ollama-queue.service"
    fi
    
    systemctl daemon-reload
    log_success "Reloaded systemd"
}



# Remove install directory
remove_install_dir() {
    log_step "Removing installation directory"
    
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        log_success "Removed $INSTALL_DIR"
    else
        log_info "$INSTALL_DIR not found"
    fi
}

# Handle data directory
handle_data_dir() {
    log_step "Handling data directory"
    
    if [[ -d "$DATA_DIR" ]]; then
        if [[ -f "$DATA_DIR/queue.db" ]]; then
            # Show queue stats
            if command -v sqlite3 &> /dev/null; then
                local pending=$(sqlite3 "$DATA_DIR/queue.db" "SELECT COUNT(*) FROM queue WHERE status='pending';" 2>/dev/null || echo "0")
                local total=$(sqlite3 "$DATA_DIR/queue.db" "SELECT COUNT(*) FROM queue;" 2>/dev/null || echo "0")
                log_info "Queue database contains $total entries ($pending pending)"
            fi
        fi
        
        echo ""
        if ask_yes_no "Remove data directory ($DATA_DIR) including queue database?"; then
            rm -rf "$DATA_DIR"
            log_success "Removed $DATA_DIR"
        else
            log_info "Keeping $DATA_DIR"
        fi
    else
        log_info "$DATA_DIR not found"
    fi
}

# Handle Docker container
handle_docker() {
    log_step "Handling Docker container"
    
    if ! command -v docker &> /dev/null; then
        log_info "Docker not installed, skipping"
        return
    fi
    
    if docker ps -a --format '{{.Names}}' | grep -q '^ollama$'; then
        echo ""
        if ask_yes_no "Stop and remove Ollama Docker container?"; then
            log_info "Stopping Ollama container..."
            docker stop ollama 2>/dev/null || true
            docker rm ollama 2>/dev/null || true
            log_success "Removed Ollama container"
            
            echo ""
            if ask_yes_no "Remove Ollama Docker volume (contains downloaded models)?"; then
                docker volume rm ollama 2>/dev/null || true
                log_success "Removed Ollama volume"
            else
                log_info "Keeping Ollama volume (models preserved)"
            fi
        else
            log_info "Keeping Ollama container"
        fi
    else
        log_info "Ollama container not found"
    fi
}

# Remove log files
remove_logs() {
    log_step "Removing log files"
    
    if [[ -f /var/log/ohhhllama-queue.log ]]; then
        rm -f /var/log/ohhhllama-queue.log
        log_success "Removed /var/log/ohhhllama-queue.log"
    fi
}

# Print summary
print_summary() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  ohhhllama uninstalled successfully!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    
    # Check what's left
    local remaining=()
    
    if [[ -d "$DATA_DIR" ]]; then
        remaining+=("Data directory: $DATA_DIR")
    fi
    
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^ollama$'; then
        remaining+=("Docker container: ollama")
    fi
    
    if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -q '^ollama$'; then
        remaining+=("Docker volume: ollama")
    fi
    
    if [[ ${#remaining[@]} -gt 0 ]]; then
        echo "The following items were kept:"
        for item in "${remaining[@]}"; do
            echo "  - $item"
        done
        echo ""
    fi
    
    echo "Thank you for using ohhhllama!"
    echo ""
}

# Main
main() {
    print_header
    
    check_root
    
    echo -e "${YELLOW}This will uninstall ohhhllama from your system.${NC}"
    echo ""
    
    if ! ask_yes_no "Continue with uninstallation?"; then
        log_info "Uninstallation cancelled"
        exit 0
    fi
    
    stop_services
    remove_systemd
    remove_install_dir
    handle_data_dir
    handle_docker
    remove_logs
    
    print_summary
}

main "$@"
