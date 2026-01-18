#!/bin/bash
#
# ohhhllama - Ollama Container Installer
# Runs Ollama in Docker on port 11435
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

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
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
    -v ollama:/root/.ollama \
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
