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
        echo -e "  Queue: ${BOLD}$pending${NC} pending | $completed completed"
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
    echo "  Enter a HuggingFace repository ID for a model with GGUF files."
    echo ""
    echo -e "${BOLD}Format:${NC}"
    echo "  username/model-name-GGUF"
    echo ""
    echo -e "${BOLD}Where to find models:${NC}"
    echo -e "  1. Go to: ${CYAN}https://huggingface.co/models?library=gguf${NC}"
    echo "  2. Search for a model (e.g., 'llama', 'mistral', 'phi')"
    echo "  3. Look for repos ending in '-GGUF' (these have pre-converted files)"
    echo "  4. Copy the repo ID from the URL or page header"
    echo ""
    echo -e "${BOLD}Popular GGUF providers:${NC}"
    echo "  • TheBloke      - Huge collection of quantized models"
    echo "  • bartowski     - High-quality quantizations"
    echo "  • QuantFactory  - Various model quantizations"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  TheBloke/Llama-2-7B-GGUF"
    echo "  TheBloke/Mistral-7B-v0.1-GGUF"
    echo "  bartowski/Meta-Llama-3-8B-Instruct-GGUF"
    echo "  TheBloke/CodeLlama-13B-GGUF"
    echo ""
    echo -e "${BOLD}Supported architectures (for non-GGUF repos):${NC}"
    echo "  Llama, Mistral, Mixtral, Qwen2, Phi, Phi3, Gemma, Gemma2,"
    echo "  Falcon, GPT2, GPT-NeoX, StableLM, OLMo"
    echo ""
    echo -e "${DIM}Note: If the repo already has GGUF files, they'll be downloaded directly.${NC}"
    echo -e "${DIM}Otherwise, the model will be converted (requires more time & disk space).${NC}"
    echo ""
    print_divider
    echo ""
    
    read -rp "Enter HuggingFace repo ID (or 'q' to cancel): " repo_id
    
    if [[ "$repo_id" == "q" || -z "$repo_id" ]]; then
        echo "Cancelled."
        press_enter
        return
    fi
    
    # Ask for quantization
    echo ""
    echo -e "${BOLD}Quantization options:${NC}"
    echo "  Q4_K_M  - Good balance of quality/size (recommended)"
    echo "  Q5_K_M  - Better quality, larger size"
    echo "  Q8_0    - Best quality, largest size"
    echo "  Q3_K_M  - Smaller size, lower quality"
    echo ""
    read -rp "Enter quantization [Q4_K_M]: " quant
    quant=${quant:-Q4_K_M}
    
    # Ask for custom name (optional)
    echo ""
    echo -e "${BOLD}Custom model name (optional):${NC}"
    echo "  Leave blank to auto-generate from repo name."
    echo "  Use lowercase letters, numbers, and hyphens only."
    echo ""
    read -rp "Enter custom name [auto]: " custom_name
    
    echo ""
    echo "Queueing HuggingFace model:"
    echo "  Repo: $repo_id"
    echo "  Quant: $quant"
    [[ -n "$custom_name" ]] && echo "  Name: $custom_name"
    
    local json_data="{\"repo_id\": \"$repo_id\", \"quant\": \"$quant\""
    [[ -n "$custom_name" ]] && json_data="$json_data, \"name\": \"$custom_name\""
    json_data="$json_data}"
    
    local response
    response=$(curl -s -X POST "$PROXY_URL/api/hf/queue" \
        -H "Content-Type: application/json" \
        -d "$json_data")
    
    echo ""
    if echo "$response" | grep -q '"queued"\|"already_queued"'; then
        echo -e "${GREEN}✓ Model queued successfully!${NC}"
        echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"  Status: {d.get('status')}\"); print(f\"  Message: {d.get('message')}\")" 2>/dev/null
    else
        echo -e "${RED}✗ Failed to queue model${NC}"
        echo "  Response: $response"
    fi
    
    press_enter
}

view_queue() {
    print_header
    echo -e "${YELLOW}=== Download Queue ===${NC}"
    echo ""
    
    curl -s "$PROXY_URL/api/queue" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    c = d.get('counts', {})
    
    print(f\"Pending: {c.get('pending', 0)} | Downloading: {c.get('downloading', 0)} | Completed: {c.get('completed', 0)} | Failed: {c.get('failed', 0)}\")
    print()
    
    queue = d.get('queue', [])
    if queue:
        print('Pending/Downloading:')
        print('-' * 60)
        for m in queue:
            model = m.get('model', 'unknown')
            mtype = m.get('type', 'ollama')
            status = m.get('status', 'unknown')
            created = m.get('created_at', '')[:16]
            
            # Parse JSON model data for HF
            if model.startswith('{'):
                try:
                    md = json.loads(model)
                    model = md.get('repo_id', model)
                    if md.get('quant'):
                        model += f\" ({md.get('quant')})\"
                except: pass
            
            status_icon = '⏳' if status == 'pending' else '⬇️' if status == 'downloading' else '?'
            print(f\"  {status_icon} [{mtype}] {model}\")
            print(f\"      Added: {created}\")
        print()
    else:
        print('No pending downloads.')
        print()
    
    recent = d.get('recent', [])
    if recent:
        print('Recent (completed/failed):')
        print('-' * 60)
        for m in recent[:5]:
            model = m.get('model', 'unknown')
            status = m.get('status', 'unknown')
            updated = m.get('updated_at', '')[:16]
            error = m.get('error', '')
            
            status_icon = '✓' if status == 'completed' else '✗'
            print(f\"  {status_icon} {model} - {status}\")
            if error:
                print(f\"      Error: {error}\")
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null
    
    press_enter
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
    echo "  4) View queue"
    echo "  5) Process queue now"
    echo "  6) List installed models"
    echo "  7) Remove a model"
    echo "  8) View logs"
    echo "  0) Exit"
    echo ""
}

main_menu() {
    while true; do
        show_menu
        read -rp "Choice [0-8]: " choice
        
        case "$choice" in
            1) view_full_status ;;
            2) queue_ollama_model ;;
            3) queue_huggingface_model ;;
            4) view_queue ;;
            5) process_queue_now ;;
            6) list_models ;;
            7) remove_model ;;
            8) view_logs ;;
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
