#!/bin/bash
#
# ohhhllama - Queue Processor
# Processes pending model downloads from the queue
#
# This script is designed to be run by cron at off-peak hours (e.g., 3 AM)
# It can also be run manually to process the queue immediately.
#
set -e

# Configuration
DB_PATH="${DB_PATH:-/var/lib/ohhhllama/queue.db}"
OLLAMA_BACKEND="${OLLAMA_BACKEND:-http://127.0.0.1:11435}"
DISK_PATH="${DISK_PATH:-/data/ollama}"
DISK_THRESHOLD="${DISK_THRESHOLD:-90}"
LOG_PREFIX="[ohhhllama-queue]"
MAX_RETRIES=3
RETRY_DELAY=60

# HuggingFace configuration
HF_BACKEND_SCRIPT="${HF_BACKEND_SCRIPT:-/opt/ohhhllama/huggingface/hf_backend.py}"
HF_VENV="${HF_VENV:-/opt/ohhhllama/huggingface/.venv}"

# Docker configuration
DOCKER_SAVE_DIR="${DOCKER_SAVE_DIR:-/data/docker}"

# Colors (only if terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Logging functions
log_info() {
    echo -e "${BLUE}${LOG_PREFIX}${NC} [INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_success() {
    echo -e "${GREEN}${LOG_PREFIX}${NC} [OK] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_warn() {
    echo -e "${YELLOW}${LOG_PREFIX}${NC} [WARN] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo -e "${RED}${LOG_PREFIX}${NC} [ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Check dependencies
check_dependencies() {
    if ! command -v sqlite3 &> /dev/null; then
        log_error "sqlite3 is required but not installed"
        exit 1
    fi
    
    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed"
        exit 1
    fi
}

# Check if database exists
check_database() {
    if [[ ! -f "$DB_PATH" ]]; then
        log_warn "Queue database not found at $DB_PATH"
        log_info "No models to process"
        exit 0
    fi
}

# Check if Ollama is available
check_ollama() {
    if ! curl -s --max-time 10 "$OLLAMA_BACKEND/api/tags" > /dev/null 2>&1; then
        log_error "Ollama backend not available at $OLLAMA_BACKEND"
        exit 1
    fi
    log_info "Ollama backend is available"
}

# Check disk space
check_disk_space() {
    local path="${DISK_PATH}"
    local threshold="${DISK_THRESHOLD}"
    
    if [[ ! -d "$path" ]]; then
        log_warn "Disk path $path does not exist, skipping disk check"
        return 0
    fi
    
    local usage
    usage=$(df "$path" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    
    if [[ -z "$usage" ]]; then
        log_warn "Could not determine disk usage for $path"
        return 0
    fi
    
    if [[ $usage -ge $threshold ]]; then
        log_error "Disk usage at ${usage}% (threshold: ${threshold}%)"
        return 1
    fi
    
    log_info "Disk usage: ${usage}% (threshold: ${threshold}%)"
    return 0
}

# Get pending models from queue (returns: model|type)
get_pending_models() {
    sqlite3 "$DB_PATH" "SELECT model || '|' || COALESCE(type, 'ollama') FROM queue WHERE status = 'pending' ORDER BY created_at ASC;"
}

# Update model status
update_status() {
    local model="$1"
    local new_status="$2"
    local error_msg="${3:-}"
    
    if [[ -n "$error_msg" ]]; then
        sqlite3 "$DB_PATH" "UPDATE queue SET status = '$new_status', error = '$error_msg', updated_at = datetime('now') WHERE model = '$model' AND status IN ('pending', 'downloading');"
    else
        sqlite3 "$DB_PATH" "UPDATE queue SET status = '$new_status', updated_at = datetime('now') WHERE model = '$model' AND status IN ('pending', 'downloading');"
    fi
}

# Download a model
download_model() {
    local model="$1"
    local attempt=1
    
    # Check disk space before downloading
    if ! check_disk_space; then
        log_error "Skipping $model due to insufficient disk space"
        update_status "$model" "failed" "Insufficient disk space"
        return 1
    fi
    
    log_info "Downloading model: $model"
    update_status "$model" "downloading"
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        log_info "Attempt $attempt of $MAX_RETRIES for $model"
        
        # Make the pull request to Ollama
        # Stream the response to show progress
        local response
        local http_code
        
        # Use curl to pull the model, capturing both response and status
        http_code=$(curl -s -w "%{http_code}" -o /tmp/ollama_pull_response.txt \
            --max-time 7200 \
            -X POST "$OLLAMA_BACKEND/api/pull" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"$model\", \"stream\": false}")
        
        response=$(cat /tmp/ollama_pull_response.txt 2>/dev/null || echo "")
        rm -f /tmp/ollama_pull_response.txt
        
        if [[ "$http_code" == "200" ]]; then
            log_success "Successfully downloaded: $model"
            update_status "$model" "completed"
            return 0
        else
            log_warn "Download failed (HTTP $http_code): $response"
            
            if [[ $attempt -lt $MAX_RETRIES ]]; then
                log_info "Retrying in $RETRY_DELAY seconds..."
                sleep $RETRY_DELAY
            fi
        fi
        
        ((attempt++)) || true
    done
    
    log_error "Failed to download $model after $MAX_RETRIES attempts"
    update_status "$model" "failed" "Download failed after $MAX_RETRIES attempts"
    return 1
}

# Download a HuggingFace model
download_hf_model() {
    local model_data="$1"
    local attempt=1
    
    # Parse model data - could be plain repo_id or JSON with extra params
    local repo_id
    local quant="Q4_K_M"
    local custom_name=""
    local convert="true"
    
    if [[ "$model_data" == "{"* ]]; then
        # JSON format - extract fields
        repo_id=$(echo "$model_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('repo_id',''))")
        quant=$(echo "$model_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('quant','Q4_K_M'))")
        custom_name=$(echo "$model_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name',''))")
        convert=$(echo "$model_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('convert', True)).lower())")
    else
        repo_id="$model_data"
    fi
    
    if [[ -z "$repo_id" ]]; then
        log_error "Invalid HuggingFace model data: $model_data"
        update_status "$model_data" "failed" "Invalid model data"
        return 1
    fi
    
    # Check disk space before downloading
    if ! check_disk_space; then
        log_error "Skipping $repo_id due to insufficient disk space"
        update_status "$model_data" "failed" "Insufficient disk space"
        return 1
    fi
    
    # Log with appropriate message based on convert flag
    if [[ "$convert" == "true" ]]; then
        log_info "Downloading HuggingFace model for Ollama: $repo_id (quant: $quant)"
    else
        log_info "Downloading HuggingFace model (no conversion): $repo_id"
    fi
    update_status "$model_data" "downloading"
    
    # Check if venv exists
    if [[ ! -d "$HF_VENV" ]]; then
        log_error "HuggingFace venv not found at $HF_VENV"
        update_status "$model_data" "failed" "HuggingFace environment not set up"
        return 1
    fi
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        log_info "Attempt $attempt of $MAX_RETRIES for $repo_id"
        
        # Run the HuggingFace backend
        local python_cmd="
import sys
sys.path.insert(0, '/opt/ohhhllama/huggingface')
from hf_backend import process_huggingface_model
import json

result = process_huggingface_model(
    repo_id='$repo_id',
    model_name='$custom_name' if '$custom_name' else None,
    quant='$quant',
    convert=$([[ "$convert" == "true" ]] && echo "True" || echo "False")
)
print(json.dumps(result))
"
        local output
        local exit_code=0
        output=$($HF_VENV/bin/python3 -c "$python_cmd" 2>&1) || exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            # Check the result status
            local status=$(echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null)
            
            if [[ "$status" == "completed" ]]; then
                if [[ "$convert" == "true" ]]; then
                    log_success "Successfully downloaded and converted HuggingFace model: $repo_id"
                else
                    log_success "Successfully downloaded HuggingFace model: $repo_id (no conversion)"
                fi
                update_status "$model_data" "completed"
                return 0
            fi
        fi
        
        log_warn "HuggingFace download failed (exit code $exit_code)"
        log_warn "Output: $output"
        
        if [[ $attempt -lt $MAX_RETRIES ]]; then
            log_info "Retrying in $RETRY_DELAY seconds..."
            sleep $RETRY_DELAY
        fi
        
        ((attempt++)) || true
    done
    
    log_error "Failed to download HuggingFace model $repo_id after $MAX_RETRIES attempts"
    update_status "$model_data" "failed" "Download failed after $MAX_RETRIES attempts"
    return 1
}

# Download and save a Docker image
download_docker_image() {
    local image="$1"
    local attempt=1
    
    if [[ -z "$image" ]]; then
        log_error "Invalid Docker image name"
        update_status "$image" "failed" "Invalid image name"
        return 1
    fi
    
    # Check disk space before downloading
    if ! check_disk_space; then
        log_error "Skipping $image due to insufficient disk space"
        update_status "$image" "failed" "Insufficient disk space"
        return 1
    fi
    
    # Create save directory if needed
    mkdir -p "$DOCKER_SAVE_DIR"
    
    # Generate safe filename from image name
    # nginx:latest -> nginx_latest.tar
    # ghcr.io/user/repo:v1.0 -> ghcr.io_user_repo_v1.0.tar
    local safe_name=$(echo "$image" | tr '/:@' '_')
    local tar_path="$DOCKER_SAVE_DIR/${safe_name}.tar"
    
    log_info "Downloading Docker image: $image"
    log_info "Will save to: $tar_path"
    update_status "$image" "downloading"
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        log_info "Attempt $attempt of $MAX_RETRIES for $image"
        
        # Step 1: Pull the image
        log_info "Pulling image..."
        if ! sudo docker pull "$image" 2>&1; then
            log_warn "Docker pull failed"
            if [[ $attempt -lt $MAX_RETRIES ]]; then
                log_info "Retrying in $RETRY_DELAY seconds..."
                sleep $RETRY_DELAY
                ((attempt++))
                continue
            fi
            log_error "Failed to pull Docker image $image after $MAX_RETRIES attempts"
            update_status "$image" "failed" "Docker pull failed after $MAX_RETRIES attempts"
            return 1
        fi
        
        # Step 2: Save the image to tar
        log_info "Saving image to $tar_path..."
        if sudo docker save "$image" -o "$tar_path" 2>&1; then
            # Make the tar file readable by others
            sudo chmod 644 "$tar_path"
            
            local size=$(du -h "$tar_path" | cut -f1)
            log_success "Successfully saved Docker image: $image ($size)"
            log_info "To load later: docker load -i $tar_path"
            update_status "$image" "completed"
            return 0
        else
            log_warn "Docker save failed"
            # Clean up partial file
            sudo rm -f "$tar_path"
            
            if [[ $attempt -lt $MAX_RETRIES ]]; then
                log_info "Retrying in $RETRY_DELAY seconds..."
                sleep $RETRY_DELAY
            fi
        fi
        
        ((attempt++)) || true
    done
    
    log_error "Failed to save Docker image $image after $MAX_RETRIES attempts"
    update_status "$image" "failed" "Docker save failed after $MAX_RETRIES attempts"
    return 1
}

# Process the queue
process_queue() {
    local models
    models=$(get_pending_models)
    
    if [[ -z "$models" ]]; then
        log_info "No pending models in queue"
        return 0
    fi
    
    local total=$(echo "$models" | wc -l)
    local current=0
    local success=0
    local failed=0
    
    log_info "Found $total model(s) to download"
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        # Parse model|type format
        local model="${line%|*}"
        local type="${line##*|}"
        
        ((current++)) || true
        log_info "Processing $current of $total: $model (type: $type)"
        
        if [[ "$type" == "huggingface" ]]; then
            if download_hf_model "$model"; then
                ((success++)) || true
            else
                ((failed++)) || true
            fi
        elif [[ "$type" == "docker" ]]; then
            if download_docker_image "$model"; then
                ((success++)) || true
            else
                ((failed++)) || true
            fi
        else
            # Default to Ollama
            if download_model "$model"; then
                ((success++)) || true
            else
                ((failed++)) || true
            fi
        fi
        
        # Small delay between downloads
        sleep 5
        
    done <<< "$models"
    
    log_info "Queue processing complete: $success succeeded, $failed failed"
}

# Show queue status
show_status() {
    if [[ ! -f "$DB_PATH" ]]; then
        echo "No queue database found"
        return
    fi
    
    echo ""
    echo "Queue Status:"
    echo "============="
    
    local pending=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM queue WHERE status = 'pending';")
    local downloading=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM queue WHERE status = 'downloading';")
    local completed=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM queue WHERE status = 'completed';")
    local failed=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM queue WHERE status = 'failed';")
    
    # Type breakdown
    local ollama_pending=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM queue WHERE status = 'pending' AND (type = 'ollama' OR type IS NULL);")
    local hf_pending=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM queue WHERE status = 'pending' AND type = 'huggingface';")
    local docker_pending=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM queue WHERE status = 'pending' AND type = 'docker';")
    
    echo "  Pending:     $pending (Ollama: $ollama_pending, HuggingFace: $hf_pending, Docker: $docker_pending)"
    echo "  Downloading: $downloading"
    echo "  Completed:   $completed"
    echo "  Failed:      $failed"
    echo ""
    
    if [[ "$pending" -gt 0 ]]; then
        echo "Pending models:"
        sqlite3 "$DB_PATH" "SELECT '  - [' || COALESCE(type, 'ollama') || '] ' || model || ' (' || created_at || ')' FROM queue WHERE status = 'pending' ORDER BY created_at ASC LIMIT 10;"
        
        if [[ "$pending" -gt 10 ]]; then
            echo "  ... and $((pending - 10)) more"
        fi
    fi
}

# Main
main() {
    log_info "Starting queue processor"
    log_info "Database: $DB_PATH"
    log_info "Backend: $OLLAMA_BACKEND"
    
    check_dependencies
    check_database
    check_ollama
    
    # Show status before processing
    show_status
    
    # Process the queue
    process_queue
    
    # Show status after processing
    show_status
    
    log_info "Queue processor finished"
}

# Handle arguments
case "${1:-}" in
    --status|-s)
        check_database
        show_status
        ;;
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --status, -s    Show queue status without processing"
        echo "  --help, -h      Show this help message"
        echo ""
        echo "Environment variables:"
        echo "  DB_PATH         Path to SQLite database (default: /var/lib/ohhhllama/queue.db)"
        echo "  OLLAMA_BACKEND  Ollama backend URL (default: http://127.0.0.1:11435)"
        ;;
    *)
        main
        ;;
esac
