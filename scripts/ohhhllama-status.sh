#!/bin/bash
#
# ohhhllama - Quick Status and Help
#

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}                    ${GREEN}ohhhllama${NC} - Quick Reference                ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}=== Service Status ===${NC}"
echo -n "Proxy:     "; systemctl is-active ollama-proxy 2>/dev/null || echo "unknown"
echo -n "Timer:     "; systemctl is-active ollama-queue.timer 2>/dev/null || echo "unknown"
echo -n "Ollama:    "; docker ps --filter "name=ollama" --format "{{.Status}}" 2>/dev/null || echo "unknown"
echo ""

echo -e "${YELLOW}=== Queue Status ===${NC}"

# Get next run time - parse more carefully
timer_info=$(systemctl list-timers ollama-queue.timer --no-pager 2>/dev/null | grep ollama-queue)
if [[ -n "$timer_info" ]]; then
    # Extract fields: NEXT is columns 1-3 (day date time), LEFT is column 4
    next_day=$(echo "$timer_info" | awk '{print $1}')
    next_date=$(echo "$timer_info" | awk '{print $2}')
    next_time=$(echo "$timer_info" | awk '{print $3}' | cut -d: -f1,2)  # Remove seconds
    time_left=$(echo "$timer_info" | awk '{print $4}')
    echo "  Next download: ${next_day} ${next_date} ${next_time} UTC (${time_left} left)"
else
    echo "  Next download: Timer not active"
fi

# Queue counts and models
curl -s http://localhost:11434/api/queue 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    c = d.get('counts', {})
    print(f\"  Pending: {c.get('pending', 0)}, Downloading: {c.get('downloading', 0)}, Completed: {c.get('completed', 0)}, Failed: {c.get('failed', 0)}\")
    
    # Show pending models
    queue = d.get('queue', [])
    pending = [m for m in queue if m.get('status') == 'pending']
    if pending:
        print()
        print('  Queued models:')
        for m in pending[:10]:  # Limit to 10
            print(f\"    • {m.get('model')}\")
        if len(pending) > 10:
            print(f\"    ... and {len(pending) - 10} more\")
    
    # Show if any downloading
    downloading = [m for m in queue if m.get('status') == 'downloading']
    if downloading:
        print()
        print('  Currently downloading:')
        for m in downloading:
            print(f\"    ⬇ {m.get('model')}\")
except:
    print('  Could not fetch queue status')
" 2>/dev/null
echo ""

echo -e "${YELLOW}=== Disk Status ===${NC}"
curl -s http://localhost:11434/api/health 2>/dev/null | python3 -c "
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

echo -e "${YELLOW}=== Common Commands ===${NC}"
echo "  Queue a model:        curl http://localhost:11434/api/pull -d '{\"name\": \"llama2\"}'"
echo "  View queue:           curl http://localhost:11434/api/queue"
echo "  Remove from queue:    curl -X DELETE http://localhost:11434/api/queue -d '{\"name\": \"model\"}'"
echo "  View models:          curl http://localhost:11434/api/tags"
echo "  Health check:         curl http://localhost:11434/api/health"
echo "  Process queue now:    sudo systemctl start ollama-queue.service"
echo ""

echo -e "${YELLOW}=== Service Commands ===${NC}"
echo "  Restart proxy:        sudo systemctl restart ollama-proxy"
echo "  View proxy logs:      journalctl -u ollama-proxy -f"
echo "  View queue logs:      journalctl -u ollama-queue.service -n 50"
echo "  Check timer:          systemctl list-timers ollama-queue.timer"
echo ""

echo -e "${YELLOW}=== Configuration ===${NC}"
echo "  Config file:          /opt/ohhhllama/ohhhllama.conf"
echo "  Timer schedule:       /etc/systemd/system/ollama-queue.timer"
echo "  Queue database:       /var/lib/ohhhllama/queue.db"
echo "  Model storage:        /data/ollama"
echo ""

echo -e "${YELLOW}=== Edit Timer Schedule ===${NC}"
echo "  sudo nano /etc/systemd/system/ollama-queue.timer"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl restart ollama-queue.timer"
echo ""
