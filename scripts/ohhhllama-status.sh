#!/bin/bash
#
# ohhhllama - Interactive Menu & Status
#

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Configuration
PROXY_URL="http://localhost:11434"
OLLAMA_URL="http://127.0.0.1:11435"

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                         ohhhllama                             ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_divider() {
    echo -e "${DIM}──────────────────────────────────────────────────────────────${NC}"
}

press_enter() {
    echo ""
    echo -e "${DIM}Press Enter to continue...${NC}"
    read -r
}

# ============================================================================
# Status Functions
# ============================================================================

get_service_status() {
    local proxy_status timer_status ollama_status
    
    proxy_status=$(systemctl is-active ollama-proxy 2>/dev/null || echo "inactive")
    timer_status=$(systemctl is-active ollama-queue.timer 2>/dev/null || echo "inactive")
    
    # Check Ollama via API
    if curl -s --max-time 2 "$OLLAMA_URL/api/tags" &>/dev/null; then
        ollama_status="running"
    else
        ollama_status="not responding"
    fi
    
    echo "$proxy_status|$timer_status|$ollama_status"
}

print_status_summary() {
    local services
    services=$(get_service_status)
    
    local proxy_status=$(echo "$services" | cut -d'|' -f1)
    local timer_status=$(echo "$services" | cut -d'|' -f2)
    local ollama_status=$(echo "$services" | cut -d'|' -f3)
    
    # Service indicators
    local proxy_icon timer_icon ollama_icon
    [[ "$proxy_status" == "active" ]] && proxy_icon="${GREEN}✓${NC}" || proxy_icon="${RED}✗${NC}"
    [[ "$timer_status" == "active" ]] && timer_icon="${GREEN}✓${NC}" || timer_icon="${RED}✗${NC}"
    [[ "$ollama_status" == "running" ]] && ollama_icon="${GREEN}✓${NC}" || ollama_icon="${RED}✗${NC}"
    
    echo -e "${YELLOW}=== Status Summary ===${NC}"
    echo -e "  Services: Proxy $proxy_icon  Timer $timer_icon  Ollama $ollama_icon"
    
    # Queue info
    local queue_info
    queue_info=$(curl -s "$PROXY_URL/api/queue" 2>/dev/null)
    if [[ -n "$queue_info" ]]; then
        local pending=$(echo "$queue_info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('counts',{}).get('pending',0))" 2>/dev/null || echo "?")
        local completed=$(echo "$queue_info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('counts',{}).get('completed',0))" 2>/dev/null || echo "?")
        local docker_pending=$(echo "$queue_info" | python3 -c "import sys,json; d=json.load(sys.stdin); q=d.get('queue',[]); print(len([m for m in q if m.get('status')=='pending' and m.get('type')=='docker']))" 2>/dev/null || echo "0")
        local queue_line="  Queue: ${BOLD}$pending${NC} pending | $completed completed"
        if [[ "$docker_pending" != "0" && "$docker_pending" != "?" ]]; then
            queue_line="$queue_line | ${BOLD}$docker_pending${NC} docker"
        fi
        echo -e "$queue_line"
    fi
    
    # Disk info
    local disk_info
    disk_info=$(curl -s "$PROXY_URL/api/health" 2>/dev/null)
    if [[ -n "$disk_info" ]]; then
        local used=$(echo "$disk_info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('checks',{}).get('disk',{}).get('used_percent','?'))" 2>/dev/null || echo "?")
        local free=$(echo "$disk_info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('checks',{}).get('disk',{}).get('free_gb','?'))" 2>/dev/null || echo "?")
        echo -e "  Disk: ${used}% used | ${free} GB free"
    fi
    
    # Model count
    local model_count
    model_count=$(curl -s "$OLLAMA_URL/api/tags" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('models',[])))" 2>/dev/null || echo "?")
    echo -e "  Models: ${BOLD}$model_count${NC} installed"
    
    echo ""
}

# ============================================================================
# Menu Option Functions
# ============================================================================

view_full_status() {
    print_header
    echo -e "${YELLOW}=== Service Status ===${NC}"
    echo -n "  Proxy:     "; systemctl is-active ollama-proxy 2>/dev/null || echo "unknown"
    echo -n "  Timer:     "; systemctl is-active ollama-queue.timer 2>/dev/null || echo "unknown"
    
    # Ollama check via API
    if curl -s --max-time 2 "$OLLAMA_URL/api/tags" &>/dev/null; then
        echo "  Ollama:    running"
    else
        echo "  Ollama:    not responding"
    fi
    echo ""
    
    # Next scheduled run
    echo -e "${YELLOW}=== Queue Schedule ===${NC}"
    local timer_info
    timer_info=$(systemctl list-timers ollama-queue.timer --no-pager 2>/dev/null | grep ollama-queue)
    if [[ -n "$timer_info" ]]; then
        local next_run=$(echo "$timer_info" | awk '{print $1, $2, $3}')
        local time_left=$(echo "$timer_info" | awk '{print $4}')
        echo "  Next run: $next_run ($time_left left)"
    else
        echo "  Timer not active"
    fi
    echo ""
    
    # Queue status
    echo -e "${YELLOW}=== Queue Status ===${NC}"
    curl -s "$PROXY_URL/api/queue" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    c = d.get('counts', {})
    print(f\"  Pending: {c.get('pending', 0)}, Downloading: {c.get('downloading', 0)}, Completed: {c.get('completed', 0)}, Failed: {c.get('failed', 0)}\")
    
    queue = d.get('queue', [])
    ollama_pending = [m for m in queue if m.get('status') == 'pending' and m.get('type', 'ollama') == 'ollama']
    hf_pending = [m for m in queue if m.get('status') == 'pending' and m.get('type') == 'huggingface']
    
    if ollama_pending:
        print()
        print('  Ollama models queued:')
        for m in ollama_pending[:5]:
            print(f\"    • {m.get('model')}\")
        if len(ollama_pending) > 5:
            print(f\"    ... and {len(ollama_pending) - 5} more\")
    
    if hf_pending:
        print()
        print('  HuggingFace models queued:')
        for m in hf_pending[:5]:
            model = m.get('model', '')
            if model.startswith('{'):
                try:
                    md = json.loads(model)
                    model = md.get('repo_id', model)
                except: pass
            print(f\"    • {model}\")
        if len(hf_pending) > 5:
            print(f\"    ... and {len(hf_pending) - 5} more\")
except Exception as e:
    print(f'  Could not fetch queue status: {e}')
" 2>/dev/null
    echo ""
    
    # Disk status
    echo -e "${YELLOW}=== Disk Status ===${NC}"
    curl -s "$PROXY_URL/api/health" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    disk = d.get('checks', {}).get('disk', {})
    print(f\"  Path: {disk.get('path', 'N/A')}\")
    print(f\"  Used: {disk.get('used_percent', 'N/A')}% | Free: {disk.get('free_gb', 'N/A')} GB\")
except:
    print('  Could not fetch disk status')
" 2>/dev/null
    echo ""
    
    # Available models
    echo -e "${YELLOW}=== Available Models ===${NC}"
    curl -s "$OLLAMA_URL/api/tags" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    models = d.get('models', [])
    if models:
        for m in models:
            name = m.get('name', 'unknown')
            size_bytes = m.get('size', 0)
            size_gb = size_bytes / (1024**3)
            if size_gb >= 1:
                size_str = f'{size_gb:.1f} GB'
            else:
                size_mb = size_bytes / (1024**2)
                size_str = f'{size_mb:.0f} MB'
            print(f'    • {name} ({size_str})')
        print()
        print(f'  Total: {len(models)} model(s)')
    else:
        print('  No models installed')
except Exception as e:
    print(f'  Could not fetch models: {e}')
" 2>/dev/null
    echo ""
    
    # HuggingFace cache
    echo -e "${YELLOW}=== HuggingFace Cache ===${NC}"
    if [[ -d "/data/huggingface/gguf" ]]; then
        local gguf_count=$(find /data/huggingface/gguf -name "*.gguf" 2>/dev/null | wc -l)
        local gguf_size=$(du -sh /data/huggingface/gguf 2>/dev/null | cut -f1)
        echo "  GGUF files: $gguf_count ($gguf_size)"
    else
        echo "  No HuggingFace cache found"
    fi
    echo ""
    
    press_enter
}

queue_ollama_model() {
    print_header
    echo -e "${YELLOW}=== Queue Ollama Model ===${NC}"
    echo ""
    echo -e "${BOLD}What to enter:${NC}"
    echo "  Enter an Ollama model name exactly as it appears in the Ollama library."
    echo ""
    echo -e "${BOLD}Format:${NC}"
    echo "  modelname           - Downloads the default/latest version"
    echo "  modelname:tag       - Downloads a specific version/size"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  llama3              - Meta's Llama 3 (latest)"
    echo "  llama3:8b           - Llama 3 8B parameter version"
    echo "  llama3:70b          - Llama 3 70B parameter version"
    echo "  mistral             - Mistral 7B"
    echo "  codellama:13b       - Code Llama 13B"
    echo "  phi3:mini           - Microsoft Phi-3 Mini"
    echo ""
    echo -e "${BOLD}Where to find models:${NC}"
    echo -e "  Browse: ${CYAN}https://ollama.com/library${NC}"
    echo ""
    print_divider
    echo ""
    
    read -rp "Enter model name (or 'q' to cancel): " model_name
    
    if [[ "$model_name" == "q" || -z "$model_name" ]]; then
        echo "Cancelled."
        press_enter
        return
    fi
    
    echo ""
    echo "Queueing model: $model_name"
    
    local response
    response=$(curl -s -X POST "$PROXY_URL/api/pull" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$model_name\"}")
    
    echo ""
    if echo "$response" | grep -q '"status"'; then
        echo -e "${GREEN}✓ Model queued successfully!${NC}"
        echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"  Status: {d.get('status')}\"); print(f\"  Message: {d.get('message')}\")" 2>/dev/null
    else
        echo -e "${RED}✗ Failed to queue model${NC}"
        echo "  Response: $response"
    fi
    
    press_enter
}

queue_huggingface_model() {
    print_header
    echo -e "${YELLOW}=== Queue HuggingFace Model ===${NC}"
    echo ""
    echo -e "${BOLD}What to enter:${NC}"
    echo "  Enter a HuggingFace repository ID."
    echo ""
    echo -e "${BOLD}Format:${NC}"
    echo "  username/model-name       (any HuggingFace model)"
    echo "  username/model-name-GGUF  (pre-quantized, ready for Ollama)"
    echo ""
    echo -e "${BOLD}Where to find models:${NC}"
    echo -e "  • All models: ${CYAN}https://huggingface.co/models${NC}"
    echo -e "  • GGUF models: ${CYAN}https://huggingface.co/models?library=gguf${NC}"
    echo ""
    echo -e "${BOLD}Popular GGUF providers:${NC}"
    echo "  • TheBloke      - Huge collection of quantized models"
    echo "  • bartowski     - High-quality quantizations"
    echo "  • QuantFactory  - Various model quantizations"
    echo ""
    echo -e "${BOLD}Supported architectures for conversion:${NC}"
    echo "  Llama, Mistral, Mixtral, Qwen2, Phi, Phi3, Gemma, Gemma2,"
    echo "  Falcon, GPT2, GPT-NeoX, StableLM, OLMo"
    echo ""
    echo -e "${DIM}Note: Models without GGUF and unsupported architectures can still${NC}"
    echo -e "${DIM}be downloaded for other uses (training, research, etc.)${NC}"
    echo ""
    print_divider
    echo ""
    
    read -rp "Enter HuggingFace repo ID (or 'q' to cancel): " repo_id
    
    if [[ "$repo_id" == "q" || -z "$repo_id" ]]; then
        echo "Cancelled."
        press_enter
        return
    fi
    
    echo ""
    echo -e "${BLUE}Checking model...${NC}"
    
    # Run pre-flight check using the HF backend
    local check_result
    check_result=$(/opt/ohhhllama/huggingface/.venv/bin/python3 -c "
import sys
sys.path.insert(0, '/opt/ohhhllama/huggingface')
from hf_backend import quick_check_model
import json
result = quick_check_model('$repo_id')
print(json.dumps(result))
" 2>/dev/null)
    
    if [[ -z "$check_result" ]]; then
        echo -e "${RED}✗ Failed to check model (is HuggingFace module installed?)${NC}"
        press_enter
        return
    fi
    
    # Parse the check result
    local can_download can_convert has_gguf gguf_repo architecture warning error
    can_download=$(echo "$check_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('can_download', False))")
    can_convert=$(echo "$check_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('can_convert', False))")
    has_gguf=$(echo "$check_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('has_gguf', False))")
    gguf_repo=$(echo "$check_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('gguf_repo') or '')")
    architecture=$(echo "$check_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('architecture') or 'Unknown')")
    warning=$(echo "$check_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('warning') or '')")
    error=$(echo "$check_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error') or '')")
    
    echo ""
    
    # Handle errors
    if [[ -n "$error" ]]; then
        echo -e "${RED}✗ Error: $error${NC}"
        press_enter
        return
    fi
    
    # Show model info
    echo -e "${BOLD}Model Information:${NC}"
    echo "  Repository:    $repo_id"
    echo "  Architecture:  $architecture"
    
    if [[ "$has_gguf" == "True" ]]; then
        echo -e "  GGUF files:    ${GREEN}Yes (ready for Ollama)${NC}"
        if [[ -n "$gguf_repo" && "$gguf_repo" != "$repo_id" ]]; then
            echo "  GGUF source:   $gguf_repo"
        fi
    else
        echo -e "  GGUF files:    ${YELLOW}No${NC}"
    fi
    
    if [[ "$can_convert" == "True" ]]; then
        echo -e "  Ollama ready:  ${GREEN}Yes (can be converted)${NC}"
    else
        echo -e "  Ollama ready:  ${RED}No (architecture not supported)${NC}"
    fi
    
    echo ""
    
    # Handle non-convertible models
    if [[ "$can_convert" != "True" ]]; then
        echo -e "${YELLOW}⚠ Warning: This model cannot be converted for Ollama${NC}"
        if [[ -n "$warning" ]]; then
            echo -e "  $warning"
        fi
        echo ""
        echo "You can still download it to /data/huggingface/models/ for other uses"
        echo "(training, research, use with transformers library, etc.)"
        echo ""
        read -rp "Download anyway (without Ollama conversion)? [y/N]: " download_anyway
        
        if [[ ! "$download_anyway" =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            press_enter
            return
        fi
        
        # Queue for download only
        local json_data="{\"repo_id\": \"$repo_id\", \"convert\": false}"
        
        local response
        response=$(curl -s -X POST "$PROXY_URL/api/hf/queue" \
            -H "Content-Type: application/json" \
            -d "$json_data")
        
        echo ""
        if echo "$response" | grep -q '"queued"\|"already_queued"'; then
            echo -e "${GREEN}✓ Model queued for download (no Ollama conversion)${NC}"
            echo "  Will be saved to: /data/huggingface/models/"
        else
            echo -e "${RED}✗ Failed to queue model${NC}"
            echo "  Response: $response"
        fi
        
        press_enter
        return
    fi
    
    # Model CAN be converted - ask if user wants Ollama conversion
    echo -e "${GREEN}✓ This model can be used with Ollama${NC}"
    echo ""
    echo "Options:"
    echo "  1) Download AND convert for Ollama (recommended)"
    echo "  2) Download only (to /data/huggingface/models/)"
    echo "  3) Cancel"
    echo ""
    read -rp "Choice [1-3]: " convert_choice
    
    case "$convert_choice" in
        1)
            # Full conversion - ask for quant and name
            # Get available GGUF files and show quantization options
            local gguf_files
            gguf_files=$(echo "$check_result" | python3 -c "
import sys, json, re

d = json.load(sys.stdin)
files = d.get('gguf_files', [])

if not files:
    print('NONE')
else:
    # Parse quant types from filenames and estimate sizes
    quants = []
    for f in files:
        # Extract quant type from filename (e.g., 'model.Q4_K_M.gguf' or 'model-Q4_K_M.gguf')
        match = re.search(r'[._-](Q[0-9]+_?[A-Z0-9_]*|F16|F32)', f, re.IGNORECASE)
        if match:
            quant = match.group(1).upper()
            quants.append((quant, f))
    
    # Sort by quant quality (Q8 > Q6 > Q5 > Q4 > Q3 > Q2)
    def quant_sort_key(item):
        q = item[0]
        if q.startswith('Q8'): return 1
        if q.startswith('Q6'): return 2
        if q.startswith('Q5'): return 3
        if q.startswith('Q4'): return 4
        if q.startswith('Q3'): return 5
        if q.startswith('Q2'): return 6
        if q == 'F16': return 0
        if q == 'F32': return -1
        return 10
    
    quants.sort(key=quant_sort_key)
    
    # Remove duplicates keeping first (best variant)
    seen = set()
    unique = []
    for q, f in quants:
        base = q.split('_')[0]  # Q4, Q5, etc.
        if base not in seen:
            seen.add(base)
            unique.append((q, f))
    
    for q, f in unique:
        print(f'{q}|{f}')
" 2>/dev/null)
            
            if [[ "$gguf_files" == "NONE" || -z "$gguf_files" ]]; then
                # No GGUF files found - use default options
                echo ""
                echo -e "${BOLD}Quantization options:${NC}"
                echo "  Q4_K_M  - Good balance of quality/size (recommended)"
                echo "  Q5_K_M  - Better quality, larger size"
                echo "  Q8_0    - Best quality, largest size"
                echo "  Q3_K_M  - Smaller size, lower quality"
                echo ""
                read -rp "Enter quantization [Q4_K_M]: " quant
                quant=${quant:-Q4_K_M}
            else
                # Show available quantizations from the repo
                echo ""
                echo -e "${BOLD}Available quantizations in this repo:${NC}"
                
                local quant_array=()
                local i=1
                local default_idx=1
                
                while IFS='|' read -r q f; do
                    [[ -z "$q" ]] && continue
                    quant_array+=("$q|$f")
                    
                    # Mark Q4_K_M or similar as recommended
                    local marker=""
                    if [[ "$q" == "Q4_K_M" || "$q" == "Q4_K" ]]; then
                        marker=" ${GREEN}(recommended)${NC}"
                        default_idx=$i
                    fi
                    
                    echo -e "  $i) $q$marker"
                    ((i++))
                done <<< "$gguf_files"
                
                echo ""
                read -rp "Select quantization [${default_idx}]: " quant_choice
                quant_choice=${quant_choice:-$default_idx}
                
                # Get the selected quant
                if [[ "$quant_choice" =~ ^[0-9]+$ ]] && [[ $quant_choice -ge 1 ]] && [[ $quant_choice -le ${#quant_array[@]} ]]; then
                    local selected="${quant_array[$((quant_choice-1))]}"
                    quant="${selected%%|*}"
                    local selected_file="${selected#*|}"
                    echo ""
                    echo -e "  Selected: ${BOLD}$quant${NC}"
                    echo -e "  File: ${DIM}$selected_file${NC}"
                else
                    echo -e "${RED}Invalid selection, using Q4_K_M${NC}"
                    quant="Q4_K_M"
                fi
            fi
            
            echo ""
            echo -e "${BOLD}Custom model name (optional):${NC}"
            echo "  Leave blank to auto-generate from repo name."
            echo "  Use lowercase letters, numbers, and hyphens only."
            echo ""
            read -rp "Enter custom name [auto]: " custom_name
            
            echo ""
            echo "Queueing for download and Ollama conversion:"
            echo "  Repo:  $repo_id"
            echo "  Quant: $quant"
            [[ -n "$custom_name" ]] && echo "  Name:  $custom_name"
            
            local json_data="{\"repo_id\": \"$repo_id\", \"quant\": \"$quant\", \"convert\": true"
            [[ -n "$custom_name" ]] && json_data="$json_data, \"name\": \"$custom_name\""
            json_data="$json_data}"
            
            local response
            response=$(curl -s -X POST "$PROXY_URL/api/hf/queue" \
                -H "Content-Type: application/json" \
                -d "$json_data")
            
            echo ""
            if echo "$response" | grep -q '"queued"\|"already_queued"'; then
                echo -e "${GREEN}✓ Model queued for download and Ollama conversion${NC}"
                echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"  Queue ID: {d.get('queue_id', 'N/A')}\")" 2>/dev/null
            else
                echo -e "${RED}✗ Failed to queue model${NC}"
                echo "  Response: $response"
            fi
            ;;
        2)
            # Download only
            local json_data="{\"repo_id\": \"$repo_id\", \"convert\": false}"
            
            local response
            response=$(curl -s -X POST "$PROXY_URL/api/hf/queue" \
                -H "Content-Type: application/json" \
                -d "$json_data")
            
            echo ""
            if echo "$response" | grep -q '"queued"\|"already_queued"'; then
                echo -e "${GREEN}✓ Model queued for download only${NC}"
                echo "  Will be saved to: /data/huggingface/models/"
            else
                echo -e "${RED}✗ Failed to queue model${NC}"
                echo "  Response: $response"
            fi
            ;;
        *)
            echo "Cancelled."
            ;;
    esac
    
    press_enter
}

queue_docker_image() {
    print_header
    echo -e "${YELLOW}=== Queue Docker Image ===${NC}"
    echo ""
    echo -e "${BOLD}What to enter:${NC}"
    echo "  Enter a Docker image name with optional tag."
    echo ""
    echo -e "${BOLD}Format:${NC}"
    echo "  image                    - Uses :latest tag"
    echo "  image:tag                - Specific version"
    echo "  registry/image:tag       - From specific registry"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  nginx                    - Nginx web server (latest)"
    echo "  postgres:15              - PostgreSQL version 15"
    echo "  redis:7-alpine           - Redis 7 on Alpine Linux"
    echo "  python:3.11-slim         - Python 3.11 slim image"
    echo "  ghcr.io/user/app:v1.0    - From GitHub Container Registry"
    echo "  nvcr.io/nvidia/cuda:12.0 - NVIDIA CUDA image"
    echo ""
    echo -e "${BOLD}Where to find images:${NC}"
    echo -e "  • Docker Hub: ${CYAN}https://hub.docker.com${NC}"
    echo -e "  • GitHub:     ${CYAN}https://ghcr.io${NC}"
    echo -e "  • NVIDIA:     ${CYAN}https://ngc.nvidia.com${NC}"
    echo ""
    echo -e "${BOLD}What happens:${NC}"
    echo "  1. Image is pulled at scheduled time"
    echo "  2. Saved as .tar file to /data/docker/"
    echo "  3. Load later with: docker load -i /data/docker/<image>.tar"
    echo ""
    print_divider
    echo ""
    
    read -rp "Enter Docker image name (or 'q' to cancel): " image_name
    
    if [[ "$image_name" == "q" || -z "$image_name" ]]; then
        echo "Cancelled."
        press_enter
        return
    fi
    
    # Add :latest if no tag specified
    if [[ "$image_name" != *":"* && "$image_name" != *"@"* ]]; then
        image_name="${image_name}:latest"
        echo -e "${DIM}(No tag specified, using :latest)${NC}"
    fi
    
    echo ""
    echo "Queueing Docker image: $image_name"
    
    local response
    response=$(curl -s -X POST "$PROXY_URL/api/docker/queue" \
        -H "Content-Type: application/json" \
        -d "{\"image\": \"$image_name\"}")
    
    echo ""
    if echo "$response" | grep -q '"queued"\|"already_queued"'; then
        local status=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null)
        
        if [[ "$status" == "already_queued" ]]; then
            echo -e "${YELLOW}! Image already in queue${NC}"
        else
            echo -e "${GREEN}✓ Docker image queued successfully!${NC}"
            echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"  Queue ID: {d.get('queue_id', 'N/A')}\")" 2>/dev/null
        fi
        
        # Show where it will be saved
        local safe_name=$(echo "$image_name" | tr '/:@' '_')
        echo ""
        echo "  Will be saved to: /data/docker/${safe_name}.tar"
        echo "  Load with:        docker load -i /data/docker/${safe_name}.tar"
    else
        echo -e "${RED}✗ Failed to queue image${NC}"
        echo "  Response: $response"
    fi
    
    press_enter
}

view_queue() {
    while true; do
        print_header
        echo -e "${YELLOW}=== Download Queue ===${NC}"
        echo ""
        
        local queue_data
        queue_data=$(curl -s "$PROXY_URL/api/queue" 2>/dev/null)
        
        if [[ -z "$queue_data" ]]; then
            echo "Could not fetch queue data"
            press_enter
            return
        fi
        
        # Parse and display queue
        local pending_items
        pending_items=$(echo "$queue_data" | python3 -c "
import sys, json

d = json.load(sys.stdin)
c = d.get('counts', {})

print(f\"Pending: {c.get('pending', 0)} | Downloading: {c.get('downloading', 0)} | Completed: {c.get('completed', 0)} | Failed: {c.get('failed', 0)}\")
print()

queue = d.get('queue', [])
pending = [m for m in queue if m.get('status') == 'pending']

if pending:
    print('PENDING_ITEMS')
    for i, m in enumerate(pending, 1):
        model = m.get('model', 'unknown')
        mtype = m.get('type', 'ollama')
        created = m.get('created_at', '')[:16]
        
        # Parse JSON model data for HF
        display_name = model
        if model.startswith('{'):
            try:
                md = json.loads(model)
                display_name = md.get('repo_id', model)
                if md.get('quant'):
                    display_name += f\" ({md.get('quant')}\"
                    if not md.get('convert', True):
                        display_name += ', download only'
                    display_name += ')'
            except:
                pass
        
        # Output format: index|type|model|display_name|created
        print(f'{i}|{mtype}|{model}|{display_name}|{created}')
else:
    print('NO_PENDING')

# Show downloading
downloading = [m for m in queue if m.get('status') == 'downloading']
if downloading:
    print('DOWNLOADING')
    for m in downloading:
        model = m.get('model', 'unknown')
        mtype = m.get('type', 'ollama')
        if model.startswith('{'):
            try:
                md = json.loads(model)
                model = md.get('repo_id', model)
            except:
                pass
        print(f'{mtype}|{model}')
" 2>/dev/null)
        
        # Display counts (first line)
        echo "$pending_items" | head -1
        echo ""
        
        # Check if there are pending items
        if echo "$pending_items" | grep -q "^NO_PENDING"; then
            echo "No pending downloads in queue."
            echo ""
            
            # Show recent
            echo -e "${YELLOW}Recent (completed/failed):${NC}"
            echo "$queue_data" | python3 -c "
import sys, json
d = json.load(sys.stdin)
recent = d.get('recent', [])
if recent:
    for m in recent[:10]:
        model = m.get('model', 'unknown')
        status = m.get('status', 'unknown')
        error = m.get('error', '')
        icon = '✓' if status == 'completed' else '✗'
        print(f'  {icon} {model} - {status}')
        if error:
            print(f'      Error: {error}')
else:
    print('  No recent items')
" 2>/dev/null
            echo ""
            press_enter
            return
        fi
        
        # Display pending items
        echo -e "${YELLOW}Pending Downloads:${NC}"
        echo ""
        
        local item_count=0
        local items_array=()
        
        while IFS= read -r line; do
            if [[ "$line" == "PENDING_ITEMS" ]]; then
                continue
            fi
            if [[ "$line" == "DOWNLOADING" ]] || [[ "$line" == "NO_PENDING" ]] || [[ -z "$line" ]]; then
                break
            fi
            # Skip the counts line
            if [[ "$line" == Pending:* ]]; then
                continue
            fi
            
            # Parse: index|type|model|display_name|created
            IFS='|' read -r idx mtype model display_name created <<< "$line"
            
            if [[ -n "$idx" && "$idx" =~ ^[0-9]+$ ]]; then
                items_array+=("$model")
                echo -e "  ${BOLD}$idx)${NC} [$mtype] $display_name"
                echo -e "     ${DIM}Added: $created${NC}"
                ((item_count++))
            fi
        done <<< "$pending_items"
        
        echo ""
        
        # Show downloading if any
        if echo "$pending_items" | grep -q "^DOWNLOADING"; then
            echo -e "${YELLOW}Currently Downloading:${NC}"
            echo "$pending_items" | sed -n '/^DOWNLOADING/,/^$/p' | tail -n +2 | while IFS='|' read -r mtype model; do
                [[ -n "$model" ]] && echo -e "  ⬇ [$mtype] $model"
            done
            echo ""
        fi
        
        # Show recent
        echo -e "${YELLOW}Recent (completed/failed):${NC}"
        echo "$queue_data" | python3 -c "
import sys, json
d = json.load(sys.stdin)
recent = d.get('recent', [])
if recent:
    for m in recent[:5]:
        model = m.get('model', 'unknown')
        status = m.get('status', 'unknown')
        icon = '✓' if status == 'completed' else '✗'
        # Truncate long model names
        if len(model) > 50:
            model = model[:47] + '...'
        print(f'  {icon} {model}')
else:
    print('  No recent items')
" 2>/dev/null
        
        echo ""
        print_divider
        echo ""
        echo "Options:"
        echo "  [number]  Remove item from queue"
        echo "  a)        Remove ALL pending items"
        echo "  q)        Back to menu"
        echo ""
        read -rp "Choice: " queue_choice
        
        case "$queue_choice" in
            q|Q|"")
                return
                ;;
            a|A)
                echo ""
                read -rp "Remove ALL ${item_count} pending items? [y/N]: " confirm_all
                if [[ "$confirm_all" =~ ^[Yy]$ ]]; then
                    local removed=0
                    for model in "${items_array[@]}"; do
                        local response
                        response=$(curl -s -X DELETE "$PROXY_URL/api/queue" \
                            -H "Content-Type: application/json" \
                            -d "{\"model\": \"$model\"}")
                        
                        if echo "$response" | grep -q '"deleted"\|"success"'; then
                            ((removed++))
                        fi
                    done
                    echo -e "${GREEN}✓ Removed $removed item(s) from queue${NC}"
                    sleep 1
                fi
                ;;
            [0-9]*)
                if [[ $queue_choice -ge 1 && $queue_choice -le $item_count ]]; then
                    local model_to_remove="${items_array[$((queue_choice-1))]}"
                    
                    # Get display name for confirmation
                    local display_name="$model_to_remove"
                    if [[ "$model_to_remove" == "{"* ]]; then
                        display_name=$(echo "$model_to_remove" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('repo_id', d.get('name', 'unknown')))" 2>/dev/null)
                    fi
                    
                    echo ""
                    read -rp "Remove '$display_name' from queue? [y/N]: " confirm
                    
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        local response
                        response=$(curl -s -X DELETE "$PROXY_URL/api/queue" \
                            -H "Content-Type: application/json" \
                            -d "{\"model\": \"$model_to_remove\"}")
                        
                        if echo "$response" | grep -q '"deleted"\|"success"'; then
                            echo -e "${GREEN}✓ Removed from queue${NC}"
                        else
                            echo -e "${RED}✗ Failed to remove: $response${NC}"
                        fi
                        sleep 1
                    fi
                else
                    echo -e "${RED}Invalid selection${NC}"
                    sleep 1
                fi
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

process_queue_now() {
    print_header
    echo -e "${YELLOW}=== Process Queue Now ===${NC}"
    echo ""
    echo "This will start processing all pending downloads immediately."
    echo "Downloads normally run at the scheduled time (usually late night)."
    echo ""
    read -rp "Start processing now? [y/N]: " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo ""
        echo "Starting queue processor..."
        echo ""
        sudo systemctl start ollama-queue.service
        echo ""
        echo "Queue processor started. Check logs with:"
        echo "  sudo journalctl -u ollama-queue.service -f"
    else
        echo "Cancelled."
    fi
    
    press_enter
}

list_models() {
    print_header
    echo -e "${YELLOW}=== Installed Models ===${NC}"
    echo ""
    
    curl -s "$OLLAMA_URL/api/tags" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    models = d.get('models', [])
    
    if not models:
        print('No models installed.')
        sys.exit(0)
    
    # Calculate total size
    total_size = sum(m.get('size', 0) for m in models)
    total_gb = total_size / (1024**3)
    
    print(f'Total: {len(models)} models ({total_gb:.1f} GB)')
    print()
    print(f'{\"Name\":<40} {\"Size\":>10} {\"Family\":<15} {\"Quant\":<10}')
    print('-' * 80)
    
    for m in sorted(models, key=lambda x: x.get('name', '')):
        name = m.get('name', 'unknown')
        size_bytes = m.get('size', 0)
        size_gb = size_bytes / (1024**3)
        if size_gb >= 1:
            size_str = f'{size_gb:.1f} GB'
        else:
            size_mb = size_bytes / (1024**2)
            size_str = f'{size_mb:.0f} MB'
        
        details = m.get('details', {})
        family = details.get('family', '-')
        quant = details.get('quantization_level', '-')
        
        print(f'{name:<40} {size_str:>10} {family:<15} {quant:<10}')
        
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null
    echo ""
    
    press_enter
}

remove_model() {
    print_header
    echo -e "${YELLOW}=== Remove Model ===${NC}"
    echo ""
    
    # Get models into an array
    local models_json
    models_json=$(curl -s "$OLLAMA_URL/api/tags" 2>/dev/null)
    
    # List current models with numbers
    echo "Installed models:"
    echo ""
    
    local model_list
    model_list=$(echo "$models_json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    models = d.get('models', [])
    for i, m in enumerate(models, 1):
        name = m.get('name', 'unknown')
        size_bytes = m.get('size', 0)
        size_gb = size_bytes / (1024**3)
        size_str = f'{size_gb:.1f} GB' if size_gb >= 1 else f'{size_bytes / (1024**2):.0f} MB'
        print(f'{i}|{name}|{size_str}')
except:
    pass
" 2>/dev/null)
    
    if [[ -z "$model_list" ]]; then
        echo "  No models installed or could not fetch models."
        press_enter
        return
    fi
    
    # Display the list
    while IFS='|' read -r num name size; do
        echo "  $num) $name ($size)"
    done <<< "$model_list"
    
    local model_count
    model_count=$(echo "$model_list" | wc -l)
    
    echo ""
    print_divider
    echo ""
    
    read -rp "Enter model number or name to remove (or 'q' to cancel): " selection
    
    if [[ "$selection" == "q" || -z "$selection" ]]; then
        echo "Cancelled."
        press_enter
        return
    fi
    
    local model_name
    
    # Check if selection is a number
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        # Get model name by number
        if [[ "$selection" -ge 1 && "$selection" -le "$model_count" ]]; then
            model_name=$(echo "$model_list" | sed -n "${selection}p" | cut -d'|' -f2)
        else
            echo -e "${RED}Invalid selection: $selection${NC}"
            press_enter
            return
        fi
    else
        # Assume it's a model name
        model_name="$selection"
    fi
    
    echo ""
    read -rp "Are you sure you want to remove '$model_name'? [y/N]: " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo ""
        echo "Removing model..."
        
        local response
        response=$(curl -s -X DELETE "$OLLAMA_URL/api/delete" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"$model_name\"}")
        
        if [[ -z "$response" ]] || echo "$response" | grep -q "success\|null"; then
            echo -e "${GREEN}✓ Model removed successfully${NC}"
        else
            echo -e "${RED}✗ Failed to remove model${NC}"
            echo "  Response: $response"
        fi
    else
        echo "Cancelled."
    fi
    
    press_enter
}

view_logs() {
    print_header
    echo -e "${YELLOW}=== View Logs ===${NC}"
    echo ""
    echo "  1) Proxy logs (ollama-proxy)"
    echo "  2) Queue processor logs (ollama-queue)"
    echo "  3) Back to menu"
    echo ""
    read -rp "Choice [1-3]: " log_choice
    
    case "$log_choice" in
        1)
            echo ""
            echo "Showing last 50 proxy log entries (Ctrl+C to exit):"
            echo ""
            sudo journalctl -u ollama-proxy -n 50 --no-pager
            ;;
        2)
            echo ""
            echo "Showing last 50 queue processor log entries:"
            echo ""
            sudo journalctl -u ollama-queue.service -n 50 --no-pager
            ;;
        *)
            return
            ;;
    esac
    
    press_enter
}

# ============================================================================
# Main Menu
# ============================================================================

show_menu() {
    print_header
    print_status_summary
    
    echo -e "${YELLOW}=== Menu ===${NC}"
    echo "  1) View full status"
    echo "  2) Queue Ollama model"
    echo "  3) Queue HuggingFace model"
    echo "  4) Queue Docker image"
    echo "  5) View queue"
    echo "  6) Process queue now"
    echo "  7) List installed models"
    echo "  8) Remove a model"
    echo "  9) View logs"
    echo "  0) Exit"
    echo ""
}

main_menu() {
    while true; do
        show_menu
        read -rp "Choice [0-9]: " choice
        
        case "$choice" in
            1) view_full_status ;;
            2) queue_ollama_model ;;
            3) queue_huggingface_model ;;
            4) queue_docker_image ;;
            5) view_queue ;;
            6) process_queue_now ;;
            7) list_models ;;
            8) remove_model ;;
            9) view_logs ;;
            0|q|Q) 
                echo ""
                echo "Goodbye!"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice${NC}"
                sleep 1
                ;;
        esac
    done
}

# ============================================================================
# Entry Point
# ============================================================================

# Handle command line arguments
case "${1:-}" in
    --status|-s)
        # Status-only mode (non-interactive)
        print_header
        print_status_summary
        
        echo -e "${YELLOW}=== Queue ===${NC}"
        curl -s "$PROXY_URL/api/queue" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    c = d.get('counts', {})
    print(f\"  Pending: {c.get('pending', 0)}, Completed: {c.get('completed', 0)}, Failed: {c.get('failed', 0)}\")
    queue = d.get('queue', [])
    pending = [m for m in queue if m.get('status') == 'pending']
    if pending:
        print()
        for m in pending[:5]:
            mtype = m.get('type', 'ollama')
            model = m.get('model', '')
            if model.startswith('{'):
                try:
                    md = json.loads(model)
                    model = md.get('repo_id', model)
                except: pass
            print(f\"    • [{mtype}] {model}\")
except: pass
" 2>/dev/null
        echo ""
        
        echo -e "${YELLOW}=== Models ===${NC}"
        curl -s "$OLLAMA_URL/api/tags" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    models = d.get('models', [])
    for m in models[:10]:
        name = m.get('name', 'unknown')
        size_gb = m.get('size', 0) / (1024**3)
        print(f'    • {name} ({size_gb:.1f} GB)')
    if len(models) > 10:
        print(f'    ... and {len(models) - 10} more')
    print(f'  Total: {len(models)} model(s)')
except: pass
" 2>/dev/null
        echo ""
        
        echo -e "${DIM}Run 'ohhhllama' without arguments for interactive menu${NC}"
        ;;
    --help|-h)
        echo "ohhhllama - Ollama Model Manager with HuggingFace Support"
        echo ""
        echo "Usage: ohhhllama [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  (none)        Interactive menu mode"
        echo "  --status, -s  Show status summary (non-interactive)"
        echo "  --help, -h    Show this help message"
        echo ""
        echo "Features:"
        echo "  • Queue Ollama models for off-peak download"
        echo "  • Queue HuggingFace GGUF models"
        echo "  • Automatic conversion of HuggingFace models"
        echo "  • View and manage installed models"
        echo ""
        ;;
    *)
        main_menu
        ;;
esac
