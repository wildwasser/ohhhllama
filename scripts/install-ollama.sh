#!/bin/bash
#
# ohhhllama - Ollama Container Installer
# Runs Ollama in Docker on port 11435
#
set -e

# Configuration
OLLAMA_DATA_PATH="${OLLAMA_DATA_PATH:-/data/ollama}"
MIN_FREE_SPACE_GB="${MIN_FREE_SPACE_GB:-10}"

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

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if /data is mounted
check_data_mount() {
    local data_parent
    data_parent=$(dirname "$OLLAMA_DATA_PATH")
    
    if ! mountpoint -q "$data_parent" 2>/dev/null; then
        # Check if it's a subdirectory of a mount
        if ! df "$data_parent" &>/dev/null; then
            log_error "$data_parent is not mounted"
            log_error "Please mount your data partition before running this script"
            exit 1
        fi
    fi
    log_success "$data_parent is available"
}

# Check minimum free space
check_free_space() {
    local path="$1"
    local min_gb="$2"
    
    # Get free space in GB
    local free_kb
    free_kb=$(df -k "$path" 2>/dev/null | tail -1 | awk '{print $4}')
    local free_gb=$((free_kb / 1024 / 1024))
    
    if [[ $free_gb -lt $min_gb ]]; then
        log_error "Insufficient disk space: ${free_gb}GB free, need at least ${min_gb}GB"
        exit 1
    fi
    log_success "Disk space OK: ${free_gb}GB free (minimum: ${min_gb}GB)"
}

# Setup data directory with proper permissions
setup_data_directory() {
    local path="$1"
    
    if [[ ! -d "$path" ]]; then
        log_info "Creating $path..."
        mkdir -p "$path"
    fi
    
    # Set ownership and permissions
    chown root:root "$path"
    chmod 755 "$path"
    log_success "Data directory ready: $path (root:root, 755)"
}

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed. Run install-docker.sh first."
    exit 1
fi

# Check if Docker is running
if ! docker info &> /dev/null; then
    log_error "Docker is not running. Start Docker first."
    exit 1
fi

# Pre-flight checks
log_info "Running pre-flight checks..."
check_data_mount
check_free_space "$(dirname "$OLLAMA_DATA_PATH")" "$MIN_FREE_SPACE_GB"
setup_data_directory "$OLLAMA_DATA_PATH"

# Stop and remove existing container
if docker ps -a --format '{{.Names}}' | grep -q '^ollama$'; then
    log_info "Stopping existing Ollama container..."
    docker stop ollama 2>/dev/null || true
    docker rm ollama 2>/dev/null || true
    log_success "Removed existing container"
fi

# Pull latest image
log_info "Pulling Ollama image..."
docker pull ollama/ollama:latest
log_success "Image pulled"

# Check for GPU support
GPU_FLAGS=""
if command -v nvidia-smi &> /dev/null && docker info 2>/dev/null | grep -q "Runtimes.*nvidia"; then
    log_info "NVIDIA GPU detected, enabling GPU support..."
    GPU_FLAGS="--gpus all"
fi

# Run container
log_info "Starting Ollama container..."
docker run -d \
    --name ollama \
    $GPU_FLAGS \
    -p 127.0.0.1:11435:11434 \
    -v "$OLLAMA_DATA_PATH:/root/.ollama" \
    --restart unless-stopped \
    ollama/ollama:latest

log_success "Container started"

# Wait for Ollama to be ready
log_info "Waiting for Ollama to be ready..."
MAX_WAIT=30
for i in $(seq 1 $MAX_WAIT); do
    if curl -s http://127.0.0.1:11435/api/tags > /dev/null 2>&1; then
        log_success "Ollama is ready on port 11435"
        break
    fi
    
    if [[ $i -eq $MAX_WAIT ]]; then
        log_error "Ollama failed to start within ${MAX_WAIT} seconds"
        log_info "Container logs:"
        docker logs ollama
        exit 1
    fi
    
    sleep 1
done

# Show container info
log_info "Container details:"
docker ps --filter "name=ollama" --format "  ID: {{.ID}}\n  Image: {{.Image}}\n  Status: {{.Status}}\n  Ports: {{.Ports}}"

echo ""
log_success "Ollama is running!"
echo ""
echo "Test with:"
echo "  curl http://127.0.0.1:11435/api/tags"
echo ""
echo "Note: The proxy will listen on port 11434 (standard Ollama port)"
echo "      and forward requests to port 11435 (this container)"
