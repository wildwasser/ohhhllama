# ohhhllama

**Bandwidth-friendly Ollama proxy with HuggingFace integration and download queuing.**

Queue model downloads for off-peak hours. Supports both Ollama library models and HuggingFace GGUF models with automatic conversion.

## Features

- :clock1: **Scheduled Downloads** - Queue models for off-peak download (default: 10 PM)
- :hugs: **HuggingFace Integration** - Download GGUF models directly from HuggingFace
- :arrows_counterclockwise: **Auto-Conversion** - Automatically converts HuggingFace models to Ollama format
- :bar_chart: **Interactive CLI** - User-friendly menu for managing models
- :lock: **Rate Limiting** - Prevent abuse with per-IP daily limits
- :floppy_disk: **Disk Monitoring** - Automatic disk space checks before downloads
- :electric_plug: **Transparent Proxy** - Drop-in replacement for Ollama API

## Quick Start

### Installation

```bash
git clone https://github.com/wildwasser/ohhhllama.git
cd ohhhllama
sudo ./install.sh
```

The installer will:
- Install Docker (if not present)
- Set up Ollama in a Docker container
- Install the ohhhllama proxy service
- Set up the download queue timer
- Install the HuggingFace integration module

### Usage

#### Interactive Menu

```bash
ohhhllama
```

This opens an interactive menu where you can:
- View system status
- Queue Ollama models
- Queue HuggingFace models
- View/manage the download queue
- List and remove installed models
- View logs

#### Quick Status

```bash
ohhhllama --status
```

#### Queue Models via API

**Ollama models:**
```bash
curl http://localhost:11434/api/pull -d '{"name": "llama3:8b"}'
```

**HuggingFace models:**
```bash
curl http://localhost:11434/api/hf/queue -d '{"repo_id": "TheBloke/Mistral-7B-v0.1-GGUF"}'
```

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Client/App    │────▶│ ohhhllama Proxy │────▶│ Ollama (Docker) │
│  (port 11434)   │     │   (port 11434)  │     │   (port 11435)  │
└─────────────────┘     └────────┬────────┘     └─────────────────┘
                                 │
                                 ▼
                        ┌─────────────────┐
                        │  SQLite Queue   │
                        │   Database      │
                        └────────┬────────┘
                                 │
                                 ▼ (scheduled)
                        ┌─────────────────┐
                        │ Queue Processor │
                        │  (systemd timer)│
                        └─────────────────┘
```

## Configuration

Configuration file: `/opt/ohhhllama/ohhhllama.conf`

```bash
# Ollama backend URL (internal)
OLLAMA_BACKEND=http://127.0.0.1:11435

# Proxy listen port
LISTEN_PORT=11434

# Queue database path
DB_PATH=/var/lib/ohhhllama/queue.db

# Rate limit (requests per IP per day)
RATE_LIMIT=5

# Disk monitoring
DISK_PATH=/data/ollama
DISK_THRESHOLD=90

# HuggingFace settings
HF_CACHE_DIR=/data/huggingface
```

## API Reference

### Standard Ollama Endpoints

All standard Ollama API endpoints are proxied transparently:
- `GET /api/tags` - List models
- `POST /api/generate` - Generate text
- `POST /api/chat` - Chat completion
- `POST /api/pull` - Pull model (queued for off-peak)
- `DELETE /api/delete` - Delete model

### ohhhllama Extensions

#### Queue Status
```bash
GET /api/queue
```

Returns queue status and pending downloads.

#### Health Check
```bash
GET /api/health
```

Returns system health including disk space and service status.

#### Queue HuggingFace Model
```bash
POST /api/hf/queue
Content-Type: application/json

{
  "repo_id": "TheBloke/Llama-2-7B-GGUF",
  "quant": "Q4_K_M",      # Optional, default: Q4_K_M
  "name": "my-llama"      # Optional, custom Ollama model name
}
```

## HuggingFace Integration

### Supported Sources

1. **GGUF Repositories** (recommended)
   - Pre-quantized models ready for Ollama
   - Providers: TheBloke, bartowski, QuantFactory, mradermacher
   - Example: `TheBloke/Mistral-7B-v0.1-GGUF`

2. **Standard HuggingFace Models**
   - Automatically converted to GGUF
   - Requires supported architecture

### Supported Architectures

Models with these architectures can be converted:
- LlamaForCausalLM (Llama, Llama 2, Llama 3)
- MistralForCausalLM, MixtralForCausalLM
- Qwen2ForCausalLM
- PhiForCausalLM, Phi3ForCausalLM
- GemmaForCausalLM, Gemma2ForCausalLM
- FalconForCausalLM
- GPT2LMHeadModel, GPTNeoXForCausalLM
- StableLmForCausalLM
- OlmoForCausalLM

### Quantization Options

| Type | Bits | Quality | Size | Use Case |
|------|------|---------|------|----------|
| Q8_0 | 8 | Best | Large | Maximum quality |
| Q5_K_M | 5.5 | Better | Medium | Quality-focused |
| Q4_K_M | 4.5 | Good | Small | **Recommended default** |
| Q3_K_M | 3.4 | Lower | Smaller | Memory constrained |

## Directory Structure

```
/opt/ohhhllama/
├── proxy.py                 # Main proxy server
├── ohhhllama.conf           # Configuration
├── scripts/
│   └── process-queue.sh     # Queue processor
├── huggingface/
│   ├── hf_backend.py        # HuggingFace module
│   ├── requirements.txt
│   └── .venv/               # Python environment
└── ...

/data/
├── ollama/                  # Ollama model storage
│   ├── models/
│   └── modelfiles/
└── huggingface/             # HuggingFace cache
    └── gguf/                # Downloaded GGUF files

/var/lib/ohhhllama/
└── queue.db                 # SQLite queue database
```

## Service Management

```bash
# Proxy service
sudo systemctl status ollama-proxy
sudo systemctl restart ollama-proxy
sudo journalctl -u ollama-proxy -f

# Queue timer
sudo systemctl list-timers ollama-queue.timer
sudo systemctl start ollama-queue.service  # Process now

# Queue processor logs
sudo journalctl -u ollama-queue.service -n 50
```

## Scheduled Downloads

By default, queued downloads run at 10 PM daily. To change:

```bash
sudo nano /etc/systemd/system/ollama-queue.timer
sudo systemctl daemon-reload
sudo systemctl restart ollama-queue.timer
```

Timer format uses systemd calendar syntax:
- `OnCalendar=*-*-* 22:00:00` - Daily at 10 PM
- `OnCalendar=*-*-* 03:00:00` - Daily at 3 AM

## Troubleshooting

### Models not downloading

1. Check queue status: `ohhhllama` → View queue
2. Check logs: `sudo journalctl -u ollama-queue.service -n 50`
3. Process manually: `sudo systemctl start ollama-queue.service`

### HuggingFace downloads failing

1. Verify venv exists: `ls /opt/ohhhllama/huggingface/.venv`
2. Check disk space: `df -h /data`
3. Test manually:
   ```bash
   /opt/ohhhllama/huggingface/.venv/bin/python3 \
     /opt/ohhhllama/huggingface/hf_backend.py \
     TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF
   ```

### Proxy not responding

1. Check service: `sudo systemctl status ollama-proxy`
2. Check Ollama container: `sudo docker ps | grep ollama`
3. Restart: `sudo systemctl restart ollama-proxy`

## Uninstallation

```bash
cd /path/to/ohhhllama
sudo ./uninstall.sh
```

## License

MIT License - see [LICENSE](LICENSE)

## Contributing

Contributions welcome! Please open an issue or PR on GitHub.
