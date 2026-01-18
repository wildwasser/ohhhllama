# ohhhllama

**Version 1.0.4** | [Documentation](docs/) | [Report Issue](https://github.com/wildwasser/ohhhllama/issues)

**Bandwidth-friendly Ollama with download queuing**

Stop your Ollama server from downloading 70GB models during peak hours. ohhhllama is a transparent proxy that intercepts model pull requests and queues them for off-peak processing.

## Features

- 🚀 **Transparent Proxy** - Drop-in replacement for Ollama API on port 11434
- 📥 **Download Queue** - Model pulls are queued, not executed immediately  
- 🌙 **Off-Peak Processing** - Queue processes at 10 PM (configurable via systemd timer)
- 🔄 **Request Deduplication** - Same model requested 10 times? Downloaded once
- 🛡️ **Rate Limiting** - Prevent abuse with per-IP daily limits (default: 5/day)
- 💾 **External Storage** - Models stored on /data partition, not root filesystem
- 📊 **Disk Monitoring** - Rejects new requests when disk is >90% full
- 🏥 **Health Endpoint** - `/api/health` for monitoring integration
- 👀 **Queue Visibility** - Queued models appear in `ollama list` with `[QUEUED]` tag
- 🗑️ **Queue Management** - Delete queued models via API or OpenWebUI
- 🖥️ **Status Command** - Run `ohhhllama` for instant status and command reference
- 🔌 **OpenWebUI Compatible** - Full integration with OpenWebUI model management
- 📦 **Zero Dependencies** - Python stdlib only, no pip packages needed

## Quick Start

```bash
# One-liner install (requires sudo)
curl -fsSL https://raw.githubusercontent.com/wildwasser/ohhhllama/main/install.sh | sudo bash
```

Or clone and install:

```bash
git clone https://github.com/wildwasser/ohhhllama.git
cd ohhhllama
sudo ./install.sh
```

## Status Command

After installation, run `ohhhllama` from anywhere to see status and commands:

```bash
$ ohhhllama
╔══════════════════════════════════════════════════════════════╗
║                    ohhhllama - Quick Reference                ║
╚══════════════════════════════════════════════════════════════╝

=== Service Status ===
Proxy:     active
Timer:     active
Ollama:    Up 2 hours

=== Next Scheduled Download ===
Sun 2026-01-19 22:00:00 UTC  11h left

=== Queue Status ===
  Pending: 2, Downloading: 0, Completed: 5, Failed: 0

=== Disk Status ===
  Path: /data/ollama
  Used: 12% | Free: 396.5 GB

=== Common Commands ===
  Queue a model:        curl http://localhost:11434/api/pull -d '{"name": "llama2"}'
  View queue:           curl http://localhost:11434/api/queue
  View models:          curl http://localhost:11434/api/tags
  Health check:         curl http://localhost:11434/api/health
  Remove from queue:    curl -X DELETE http://localhost:11434/api/queue -d '{"name": "model"}'
  Process queue now:    sudo systemctl start ollama-queue.service

=== Service Commands ===
  Restart proxy:        sudo systemctl restart ollama-proxy
  View proxy logs:      journalctl -u ollama-proxy -f
  View queue logs:      journalctl -u ollama-queue.service -n 50
  Check timer:          systemctl list-timers ollama-queue.timer

=== Configuration ===
  Config file:          /opt/ohhhllama/ohhhllama.conf
  Timer schedule:       /etc/systemd/system/ollama-queue.timer
  Queue database:       /var/lib/ohhhllama/queue.db
  Model storage:        /data/ollama
```

## Requirements

- **Operating System**: Ubuntu 20.04+ or Debian-based Linux
- **Python 3.8+**: Uses only standard library (no pip packages required)
- **Docker**: Installed automatically if missing
- **sqlite3**: CLI tool for queue processing (installed automatically)
- **curl**: For API calls (installed automatically)
- **Root/sudo access**: Required for installation
- **External storage**: Partition mounted at `/data` (recommended, ~500GB+ for models)

### What Gets Installed

The installer will automatically install these if missing:
- Docker CE (if not present)
- sqlite3 CLI tool
- curl

No Python virtual environment or pip packages are needed - the proxy uses only Python standard library modules.

## Pre-Installation Checklist

Before running the installer, verify:

```bash
# Check Python version (need 3.8+)
python3 --version

# Check if Docker is installed (optional - installer will add it)
docker --version

# Check if /data partition is mounted (recommended)
df -h /data

# Check available space
df -h
```

## How It Works

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Client    │────▶│  ohhhllama  │────▶│   Ollama    │
│ (port 11434)│     │   (proxy)   │     │ (port 11435)│
└─────────────┘     └─────────────┘     └─────────────┘
                           │
                           ▼
                    ┌─────────────┐
                    │   SQLite    │
                    │   Queue     │
                    └─────────────┘
                           │
                           ▼ (3 AM systemd timer)
                    ┌─────────────┐
                    │  Download   │
                    │  Processor  │
                    └─────────────┘
```

1. Client requests `POST /api/pull` for a model
2. Proxy intercepts, adds to SQLite queue, returns "queued" response
3. At 10 PM, systemd timer triggers queue processing and downloads models
4. All other API calls pass through unchanged to Ollama

## Configuration

Configuration is done via environment variables. Copy the example config:

```bash
sudo cp /opt/ohhhllama/ohhhllama.conf.example /opt/ohhhllama/ohhhllama.conf
sudo nano /opt/ohhhllama/ohhhllama.conf
```

### Options

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_BACKEND` | `http://127.0.0.1:11435` | Ollama backend URL |
| `LISTEN_PORT` | `11434` | Proxy listen port |
| `DB_PATH` | `/var/lib/ohhhllama/queue.db` | SQLite database path |
| `RATE_LIMIT` | `5` | Max model requests per IP per day |
| `DISK_PATH` | `/data/ollama` | Path to monitor for disk space |
| `DISK_THRESHOLD` | `90` | Disk usage threshold (percent) |
| `CLEANUP_DAYS` | `30` | Auto-cleanup old entries after N days |

> **Note:** Queue processing schedule is controlled by the systemd timer. See [Systemd Timer](#systemd-timer) section below.

After changing config, restart the service:

```bash
sudo systemctl restart ollama-proxy
```

## Usage

### Normal Ollama Commands (unchanged)

```bash
# List models
ollama list

# Run a model (if already downloaded)
ollama run llama2

# Chat API
curl http://localhost:11434/api/chat -d '{
  "model": "llama2",
  "messages": [{"role": "user", "content": "Hello!"}]
}'
```

### Pull Requests (queued)

```bash
# Request a model - gets queued
curl http://localhost:11434/api/pull -d '{"name": "llama2:70b"}'
# Response: {"status": "queued", "message": "Model llama2:70b added to download queue"}

# Check queue status
curl http://localhost:11434/api/queue
# Response: {"queue": [{"model": "llama2:70b", "status": "pending", ...}]}
```

### Health Check

```bash
# Check system health
curl http://localhost:11434/api/health
# Response:
# {
#   "status": "healthy",
#   "checks": {
#     "proxy": {"status": "ok"},
#     "backend": {"status": "ok", "url": "http://127.0.0.1:11435"},
#     "disk": {"status": "ok", "path": "/data/ollama", "used_percent": 45, "free_gb": 248},
#     "database": {"status": "ok", "path": "/var/lib/ohhhllama/queue.db"}
#   },
#   "timestamp": "2024-..."
# }
```

Health status values:
- `healthy` - All systems operational
- `degraded` - Some non-critical issues (e.g., disk warning)
- `unhealthy` - Critical issues (e.g., backend down, disk full)

### Queue Management

```bash
# View queue
curl http://localhost:11434/api/queue

# Remove a model from queue
curl -X DELETE http://localhost:11434/api/queue -d '{"name": "llama2:70b"}'

# Process queue manually (as root)
sudo /opt/ohhhllama/scripts/process-queue.sh

# View queue database directly
sudo sqlite3 /var/lib/ohhhllama/queue.db "SELECT * FROM queue;"
```

### OpenWebUI Integration

ohhhllama is fully compatible with OpenWebUI. Queued models appear in the model list with a `* [QUEUED]` prefix, making them easy to identify.

When you delete a queued model through OpenWebUI's model management interface (or via `ollama rm`), ohhhllama automatically:
1. Detects that it's a queued model (not a real Ollama model)
2. Removes it from the download queue
3. Returns success to the client

This means you can manage your download queue directly from OpenWebUI without needing to use the `/api/queue` endpoint.

## Service Management

```bash
# Check proxy status
sudo systemctl status ollama-proxy

# View proxy logs
sudo journalctl -u ollama-proxy -f

# Restart proxy
sudo systemctl restart ollama-proxy

# Check Ollama container
docker ps | grep ollama
docker logs ollama
```

## Systemd Timer

Queue processing is handled by a systemd timer that runs at 10 PM daily by default.

### Check Timer Status

```bash
# View timer status and next run time
sudo systemctl list-timers ollama-queue.timer

# Check if timer is enabled
sudo systemctl status ollama-queue.timer
```

### Change Schedule

Edit the timer file to change when queue processing runs:

```bash
sudo nano /etc/systemd/system/ollama-queue.timer
```

Modify the `OnCalendar` line. Examples:
- `OnCalendar=*-*-* 22:00:00` - 10 PM daily (default)
- `OnCalendar=*-*-* 03:00:00` - 3 AM daily
- `OnCalendar=Sat *-*-* 04:00:00` - 4 AM on Saturdays only
- `OnCalendar=*-*-* 01,13:00:00` - 1 AM and 1 PM daily

After editing, reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama-queue.timer
```

### Run Queue Manually

```bash
# Process queue immediately (don't wait for timer)
sudo systemctl start ollama-queue.service
```

### View Queue Logs

```bash
# View recent queue processing logs
sudo journalctl -u ollama-queue.service -n 50

# Follow logs in real-time
sudo journalctl -u ollama-queue.service -f
```

## External Storage Setup

For production use, it's recommended to store Ollama models on a dedicated partition to avoid filling up your root filesystem.

### Setting Up /data Partition

1. **Create and mount the partition:**
   ```bash
   # Example: Format and mount a new disk
   sudo mkfs.ext4 /dev/sdb1
   sudo mkdir /data
   sudo mount /dev/sdb1 /data
   
   # Add to /etc/fstab for persistence
   echo '/dev/sdb1 /data ext4 defaults 0 2' | sudo tee -a /etc/fstab
   ```

2. **Create the Ollama data directory:**
   ```bash
   sudo mkdir -p /data/ollama
   sudo chown root:root /data/ollama
   sudo chmod 755 /data/ollama
   ```

3. **Install ohhhllama:**
   The installer will automatically detect and use `/data/ollama` for model storage.

### Disk Space Monitoring

ohhhllama monitors disk space and:
- Rejects new pull requests when disk usage exceeds `DISK_THRESHOLD` (default: 90%)
- Reports disk status via the `/api/health` endpoint
- Checks disk space before each download in the queue processor

Configure thresholds in `/opt/ohhhllama/ohhhllama.conf`:
```bash
DISK_PATH=/data/ollama
DISK_THRESHOLD=90
```

## Troubleshooting

### Proxy won't start

```bash
# Check if port 11434 is in use
sudo lsof -i :11434

# Check service logs
sudo journalctl -u ollama-proxy -n 50

# Verify Ollama is running
curl http://127.0.0.1:11435/api/tags
```

### Models not downloading

```bash
# Check timer status
sudo systemctl list-timers ollama-queue.timer

# Run queue processor manually
sudo systemctl start ollama-queue.service

# Check queue processor logs
sudo journalctl -u ollama-queue.service -n 50

# Check queue status
sqlite3 /var/lib/ohhhllama/queue.db "SELECT * FROM queue WHERE status='pending';"
```

### Connection refused

```bash
# Ensure Ollama container is running
docker start ollama

# Ensure proxy is running
sudo systemctl start ollama-proxy

# Test backend directly
curl http://127.0.0.1:11435/api/tags
```

### Rate limit hit

```bash
# Check your request count
curl http://localhost:11434/api/queue

# Rate limits reset daily at midnight
# Or manually clear (careful!):
sudo sqlite3 /var/lib/ohhhllama/queue.db "DELETE FROM rate_limits;"
```

## Uninstall

```bash
sudo ./uninstall.sh
```

This will:
- Stop and disable services
- Remove installed files
- Optionally remove Docker container and data
- Optionally keep or remove the queue database

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed technical documentation.

## API Reference

See [docs/API.md](docs/API.md) for complete API documentation.

## License

MIT License - see [LICENSE](LICENSE)

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## Credits

Created by [wildwasser](https://github.com/wildwasser)

---

*"Because downloading 70GB at 2 PM is just rude."*
