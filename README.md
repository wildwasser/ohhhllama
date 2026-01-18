# ohhhllama

**Bandwidth-friendly Ollama with download queuing**

Stop your Ollama server from downloading 70GB models during peak hours. ohhhllama is a transparent proxy that intercepts model pull requests and queues them for off-peak processing.

## Features

- **Transparent Proxy** - Drop-in replacement for Ollama API on port 11434
- **Download Queue** - Model pulls are queued, not executed immediately
- **Off-Peak Processing** - Queue processes at 3 AM (configurable)
- **Request Deduplication** - Same model requested 10 times? Downloaded once
- **Rate Limiting** - Prevent abuse with per-IP daily limits
- **SQLite Storage** - Simple, reliable, no external dependencies
- **Full API Compatibility** - All other Ollama endpoints pass through unchanged

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

## Requirements

- Ubuntu 20.04+ (or Debian-based Linux)
- Docker (installed automatically if missing)
- Python 3.8+
- Root/sudo access for installation

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
                           ▼ (3 AM cron)
                    ┌─────────────┐
                    │  Download   │
                    │  Processor  │
                    └─────────────┘
```

1. Client requests `POST /api/pull` for a model
2. Proxy intercepts, adds to SQLite queue, returns "queued" response
3. At 3 AM, cron job processes queue and downloads models
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
| `QUEUE_SCHEDULE` | `0 3 * * *` | Cron schedule for queue processing |

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

### Queue Management

```bash
# View queue
curl http://localhost:11434/api/queue

# Process queue manually (as root)
sudo /opt/ohhhllama/scripts/process-queue.sh

# View queue database directly
sudo sqlite3 /var/lib/ohhhllama/queue.db "SELECT * FROM queue;"
```

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
# Check cron job
sudo crontab -l | grep ohhhllama

# Run queue processor manually
sudo /opt/ohhhllama/scripts/process-queue.sh

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
