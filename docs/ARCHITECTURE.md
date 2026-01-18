# ohhhllama Architecture

This document explains the technical architecture of ohhhllama.

## Overview

ohhhllama is a transparent proxy that sits between Ollama clients and the Ollama server. It intercepts model download requests and queues them for off-peak processing. It supports both native Ollama models and HuggingFace models (which are converted to GGUF format and imported into Ollama).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Client Machine                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────┐                                                            │
│  │   Client    │  (ollama CLI, curl, OpenWebUI, applications)               │
│  │ :11434      │                                                            │
│  └──────┬──────┘                                                            │
│         │                                                                   │
│         ▼                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                   ohhhllama Proxy (Python)                           │   │
│  │                         :11434                                       │   │
│  │  ┌─────────────────────────────────────────────────────────────┐    │   │
│  │  │  Request Router                                              │    │   │
│  │  │  - POST /api/pull → Queue Handler (Ollama models)           │    │   │
│  │  │  - POST /api/hf/queue → HuggingFace Queue Handler           │    │   │
│  │  │  - GET /api/queue → Queue Status                            │    │   │
│  │  │  - DELETE /api/queue → Remove from Queue                    │    │   │
│  │  │  - GET /api/tags → Modified (adds queued models)            │    │   │
│  │  │  - DELETE /api/delete → Intercept (queued models)           │    │   │
│  │  │  - GET /api/health → Health Check                           │    │   │
│  │  │  - Everything else → Pass-through                           │    │   │
│  │  └─────────────────────────────────────────────────────────────┘    │   │
│  │                         │                                            │   │
│  │                         ▼                                            │   │
│  │  ┌─────────────────────────────────────────────────────────────┐    │   │
│  │  │  SQLite Database                                             │    │   │
│  │  │  /var/lib/ohhhllama/queue.db                                │    │   │
│  │  │  - queue table (pending downloads, type: ollama|huggingface)│    │   │
│  │  │  - rate_limits table (per-IP tracking)                      │    │   │
│  │  └─────────────────────────────────────────────────────────────┘    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│         │                                                                   │
│         ▼                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                   Ollama (Docker Container)                          │   │
│  │                         :11435                                       │   │
│  │  - Model inference                                                   │   │
│  │  - Model storage (/root/.ollama via volume)                         │   │
│  │  - Accepts GGUF imports via Modelfile                               │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                   Queue Processor (Systemd Timer)                    │   │
│  │                   Runs at 10 PM (configurable)                       │   │
│  │  ┌───────────────────────────────────────────────────────────────┐  │   │
│  │  │  Dual-Type Processing                                          │  │   │
│  │  │  - type='ollama' → Direct Ollama API pull                     │  │   │
│  │  │  - type='huggingface' → HuggingFace Backend Pipeline          │  │   │
│  │  └───────────────────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                   HuggingFace Backend (Python)                       │   │
│  │                   /opt/ohhhllama/huggingface/hf_backend.py          │   │
│  │  - Model discovery (check_model, search_gguf_repo)                  │   │
│  │  - GGUF download or model conversion                                │   │
│  │  - Ollama import via Modelfile                                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Proxy Server (`proxy.py`)

The proxy is a Python HTTP server that:

- Listens on port 11434 (standard Ollama port)
- Intercepts specific requests (POST /api/pull, POST /api/hf/queue)
- Passes through all other requests unchanged
- Manages the SQLite database

**Key Features:**
- Threaded request handling for concurrency
- Streaming response support for large payloads
- Header preservation for compatibility
- Dual-type queue support (Ollama and HuggingFace)

**HuggingFace Endpoint:**
```
POST /api/hf/queue
Content-Type: application/json

{
    "repo_id": "meta-llama/Llama-2-7b",
    "quant": "Q4_K_M",           // Optional, default: Q4_K_M
    "name": "my-custom-name"     // Optional custom Ollama model name
}
```

### 2. SQLite Database

We chose SQLite because:

- **Zero configuration** - No separate database server needed
- **Reliable** - ACID compliant, handles crashes gracefully
- **Portable** - Single file, easy to backup/restore
- **Sufficient** - Queue operations are simple CRUD

**Schema:**

```sql
-- Download queue (supports both Ollama and HuggingFace models)
CREATE TABLE queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    model TEXT NOT NULL,           -- Model name or HuggingFace repo_id (may be JSON for HF)
    type TEXT DEFAULT 'ollama',    -- 'ollama' or 'huggingface'
    requester_ip TEXT NOT NULL,    -- Who requested it
    status TEXT DEFAULT 'pending', -- pending/downloading/completed/failed
    error TEXT,                    -- Error message if failed
    created_at TIMESTAMP,          -- When requested
    updated_at TIMESTAMP           -- Last status change
);

-- Rate limiting
CREATE TABLE rate_limits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ip_address TEXT NOT NULL,
    request_date DATE NOT NULL,
    request_count INTEGER DEFAULT 1,
    UNIQUE(ip_address, request_date)
);
```

**HuggingFace Model Storage:**

For HuggingFace models with custom parameters, the `model` field stores JSON:
```json
{"repo_id": "meta-llama/Llama-2-7b", "quant": "Q5_K_M", "name": "llama2-custom"}
```

### 3. Queue Processor (`process-queue.sh`)

A bash script that:

- Runs via systemd timer at 10 PM (configurable via `/etc/systemd/system/ollama-queue.timer`)
- Queries pending items from SQLite with their type
- Routes to appropriate download handler based on type
- Updates status on success/failure
- Implements retry logic with backoff

**Dual-Type Processing:**

```bash
# Parse model|type format from database
local model="${line%|*}"
local type="${line##*|}"

if [[ "$type" == "huggingface" ]]; then
    download_hf_model "$model"
else
    download_model "$model"  # Default to Ollama
fi
```

### 4. HuggingFace Backend Module (`hf_backend.py`)

A comprehensive Python module for HuggingFace model integration.

**Configuration:**
```python
HF_CACHE_DIR = Path("/data/huggingface")      # Downloaded models cache
OLLAMA_MODELS_DIR = Path("/data/ollama")       # Ollama model storage
LLAMA_CPP_DIR = Path("/opt/llama.cpp")         # llama.cpp for conversion
DEFAULT_QUANT = "Q4_K_M"                       # Default quantization
```

**Key Components:**

#### Data Classes

```python
@dataclass
class ModelInfo:
    """Information about a HuggingFace model."""
    repo_id: str
    architecture: Optional[str] = None
    is_convertible: bool = False
    has_gguf: bool = False
    gguf_files: List[str] = field(default_factory=list)
    gguf_repo: Optional[str] = None
    error: Optional[str] = None

@dataclass
class ProcessResult:
    """Result of processing a HuggingFace model."""
    status: str  # "completed", "failed", "partial"
    steps: List[Dict[str, Any]] = field(default_factory=list)
    error: Optional[str] = None
    model_name: Optional[str] = None
    gguf_path: Optional[str] = None
```

#### Model Discovery Functions

**`check_model(repo_id, token)`** - Analyzes a HuggingFace repository:
1. Fetches repository file list via HuggingFace API
2. Checks for existing GGUF files in the repo
3. If no GGUF, fetches `config.json` to determine architecture
4. Checks if architecture is supported for conversion
5. Searches for existing GGUF repos from known providers

**`search_gguf_repo(repo_id, token)`** - Finds pre-quantized GGUF versions:
- Checks known GGUF providers: TheBloke, bartowski, QuantFactory, mradermacher
- Tries name variations (hyphens, underscores, case)
- Returns first repo found with actual GGUF files

**Supported Architectures for Conversion:**
```python
SUPPORTED_ARCHITECTURES = [
    "LlamaForCausalLM", "MistralForCausalLM", "MixtralForCausalLM",
    "Qwen2ForCausalLM", "PhiForCausalLM", "Phi3ForCausalLM",
    "GemmaForCausalLM", "Gemma2ForCausalLM", "FalconForCausalLM",
    "GPT2LMHeadModel", "GPTNeoXForCausalLM", "StableLmForCausalLM",
    "OlmoForCausalLM",
]
```

#### Download Functions

**`download_gguf(repo_id, filename, output_dir, token)`**:
- Tries `huggingface-cli` first (best for large files, supports resume)
- Falls back to `wget` with resume support
- Last resort: `urllib` (no resume)

**`download_model_for_conversion(repo_id, output_dir, token)`**:
- Downloads safetensors, JSON configs, and tokenizer files
- Uses `huggingface-cli` with include filters

**`select_gguf_file(gguf_files, quant)`**:
- Selects best GGUF file matching quantization preference
- Falls back through quality hierarchy: Q8_0 → Q6_K → Q5_K_M → ... → Q2_K

#### Conversion Functions

**`convert_to_gguf(model_dir, output_path, dtype)`**:
- Uses llama.cpp's `convert_hf_to_gguf.py` script
- Converts HuggingFace format to GGUF (typically f16 first)

**`quantize_gguf(input_path, output_path, quant_type)`**:
- Uses llama.cpp's `llama-quantize` binary
- Applies quantization (Q4_K_M, Q5_K_M, etc.)

#### Ollama Integration

**`create_modelfile(gguf_path, model_name, system_prompt, template)`**:
- Generates Ollama Modelfile pointing to GGUF
- Adds default parameters (temperature, top_p, stop tokens)

**`import_to_ollama(modelfile_path, model_name)`**:
- Uses `docker exec` to run `ollama create` inside container
- Sanitizes model name (lowercase, hyphens)

### 5. Ollama Container

Standard Ollama Docker container with:

- Port mapped to 11435 (internal only)
- Volume for model persistence (`/data/ollama`)
- Volume for HuggingFace cache (`/data/huggingface`)
- Auto-restart policy

## Request Flow

### Normal Request (e.g., /api/chat)

```
Client → Proxy → Ollama → Proxy → Client
         (pass-through)
```

1. Client sends request to proxy (port 11434)
2. Proxy forwards request to Ollama (port 11435)
3. Ollama processes and responds
4. Proxy streams response back to client

### Ollama Pull Request (POST /api/pull)

```
Client → Proxy → [Check] → Queue → Client
                    ↓
              (if exists)
                    ↓
                 Ollama
```

1. Client requests model download
2. Proxy checks if model already exists
3. If exists: pass through to Ollama
4. If not exists:
   - Check rate limit
   - Check for duplicate in queue
   - Add to queue (type='ollama')
   - Return "queued" response

### HuggingFace Queue Request (POST /api/hf/queue)

```
Client → Proxy → [Validate] → Queue → Client
                     │
                     ▼
              Store with type='huggingface'
              (may include quant, custom name as JSON)
```

1. Client sends HuggingFace repo_id with optional parameters
2. Proxy validates request and checks rate limit
3. Checks for duplicate in queue
4. Stores in queue with `type='huggingface'`
5. Returns "queued" response with queue_id

### Queue Processing (10 PM default)

#### Ollama Model Processing

```
Systemd Timer → Processor → SQLite → Ollama API
                               ↓
                         (update status)
```

1. Systemd timer triggers processor script
2. Script queries pending items with type='ollama'
3. For each item:
   - Update status to "downloading"
   - Call Ollama pull API
   - Update status to "completed" or "failed"

#### HuggingFace Model Processing

```
Systemd Timer → Processor → SQLite → HuggingFace Backend
                               │
                               ▼
                    ┌──────────────────────┐
                    │  check_model()       │
                    │  - Has GGUF?         │
                    │  - Is convertible?   │
                    │  - Find GGUF repo?   │
                    └──────────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
        [Has GGUF]      [Convertible]     [Not Supported]
              │                │                │
              ▼                ▼                ▼
        download_gguf()  download_model()    FAIL
              │                │
              │                ▼
              │         convert_to_gguf()
              │                │
              │                ▼
              │         quantize_gguf()
              │                │
              └───────┬────────┘
                      ▼
              create_modelfile()
                      │
                      ▼
              import_to_ollama()
                      │
                      ▼
              (update status)
```

**Detailed HuggingFace Flow:**

1. **Check Model** (`check_model`):
   - Query HuggingFace API for repository info
   - Check if repo contains GGUF files directly
   - If not, check model architecture for conversion support
   - Search for existing GGUF repos from providers

2. **Get GGUF File**:
   - **If GGUF exists**: Select best file matching quant preference, download
   - **If convertible**: Download safetensors, convert to GGUF, quantize

3. **Import to Ollama**:
   - Create Modelfile with GGUF path
   - Run `ollama create` via docker exec
   - Model becomes available for inference

### Tags Request (GET /api/tags)

```
Client → Proxy → Ollama → Proxy → [Merge Queued] → Client
                                        ↓
                                    SQLite
```

1. Client requests model list
2. Proxy forwards to Ollama, gets real models
3. Proxy queries pending models from queue (both types)
4. Proxy merges queued models with `* [QUEUED]` prefix
5. Combined list returned to client

### Delete Request (DELETE /api/delete)

```
Client → Proxy → [Check Queue] → Queue (if queued) → Client
                      ↓
               (if not queued)
                      ↓
                   Ollama → Client
```

1. Client requests model deletion
2. Proxy checks if model is in queue (pending status)
3. If queued: remove from queue, return success
4. If not queued: pass through to Ollama backend

## Data Flow Diagrams

### Ollama Model Download Flow

```
┌─────────┐    POST /api/pull     ┌─────────┐
│ Client  │ ──────────────────────▶│  Proxy  │
└─────────┘                        └────┬────┘
                                        │
                                        ▼
                              ┌─────────────────┐
                              │ Model exists?   │
                              └────────┬────────┘
                                       │
                    ┌──────────────────┼──────────────────┐
                    │ YES              │ NO               │
                    ▼                  ▼                  │
              ┌──────────┐      ┌─────────────┐          │
              │ Pass to  │      │ Rate limit  │          │
              │ Ollama   │      │ check       │          │
              └──────────┘      └──────┬──────┘          │
                                       │                  │
                                       ▼                  │
                              ┌─────────────────┐        │
                              │ Add to queue    │        │
                              │ type='ollama'   │        │
                              └────────┬────────┘        │
                                       │                  │
                                       ▼                  │
                              ┌─────────────────┐        │
                              │ Return 202      │        │
                              │ "queued"        │        │
                              └─────────────────┘        │
                                                         │
                    ═══════════════════════════════════════
                              LATER (10 PM)
                    ═══════════════════════════════════════
                                                         │
                              ┌─────────────────┐        │
                              │ Queue Processor │        │
                              └────────┬────────┘        │
                                       │                  │
                                       ▼                  │
                              ┌─────────────────┐        │
                              │ Ollama API      │        │
                              │ POST /api/pull  │        │
                              └────────┬────────┘        │
                                       │                  │
                                       ▼                  │
                              ┌─────────────────┐        │
                              │ Update status   │        │
                              │ completed/failed│        │
                              └─────────────────┘        │
```

### HuggingFace Model Download Flow

```
┌─────────┐   POST /api/hf/queue  ┌─────────┐
│ Client  │ ──────────────────────▶│  Proxy  │
└─────────┘                        └────┬────┘
     │                                  │
     │  {                               ▼
     │    "repo_id": "org/model",  ┌─────────────┐
     │    "quant": "Q4_K_M",       │ Rate limit  │
     │    "name": "custom"         │ check       │
     │  }                          └──────┬──────┘
     │                                    │
     │                                    ▼
     │                            ┌─────────────────┐
     │                            │ Add to queue    │
     │                            │ type='huggingface'
     │                            └────────┬────────┘
     │                                     │
     │                                     ▼
     │                            ┌─────────────────┐
     │                            │ Return 202      │
     │                            │ "queued"        │
     │                            └─────────────────┘
     │
     │            ═══════════════════════════════════════
     │                          LATER (10 PM)
     │            ═══════════════════════════════════════
     │
     │                            ┌─────────────────┐
     │                            │ Queue Processor │
     │                            └────────┬────────┘
     │                                     │
     │                                     ▼
     │                            ┌─────────────────┐
     │                            │ HF Backend      │
     │                            │ hf_backend.py   │
     │                            └────────┬────────┘
     │                                     │
     │                    ┌────────────────┼────────────────┐
     │                    ▼                ▼                ▼
     │              ┌──────────┐    ┌──────────┐    ┌──────────┐
     │              │ Has GGUF │    │ Convert  │    │ Search   │
     │              │ in repo  │    │ from HF  │    │ GGUF     │
     │              └────┬─────┘    └────┬─────┘    │ providers│
     │                   │               │          └────┬─────┘
     │                   ▼               ▼               │
     │              ┌──────────┐    ┌──────────┐        │
     │              │ Download │    │ Download │        │
     │              │ GGUF     │    │ safetensors       │
     │              └────┬─────┘    └────┬─────┘        │
     │                   │               │               │
     │                   │               ▼               │
     │                   │          ┌──────────┐        │
     │                   │          │ Convert  │        │
     │                   │          │ to GGUF  │        │
     │                   │          └────┬─────┘        │
     │                   │               │               │
     │                   │               ▼               │
     │                   │          ┌──────────┐        │
     │                   │          │ Quantize │        │
     │                   │          │ (Q4_K_M) │        │
     │                   │          └────┬─────┘        │
     │                   │               │               │
     │                   └───────┬───────┘───────┬──────┘
     │                           ▼               │
     │                    ┌──────────────┐       │
     │                    │ Create       │       │
     │                    │ Modelfile    │       │
     │                    └──────┬───────┘       │
     │                           │               │
     │                           ▼               │
     │                    ┌──────────────┐       │
     │                    │ ollama create│       │
     │                    │ (docker exec)│       │
     │                    └──────┬───────┘       │
     │                           │               │
     │                           ▼               │
     │                    ┌──────────────┐       │
     │                    │ Model ready  │       │
     │                    │ in Ollama    │       │
     │                    └──────────────┘       │
```

## Deduplication

The proxy prevents duplicate downloads:

1. **Existing models**: Before queuing, check if model exists in Ollama
2. **Pending queue**: Before adding, check if model is already pending

```python
def is_model_in_queue(model: str) -> bool:
    cursor.execute("""
        SELECT COUNT(*) FROM queue
        WHERE model = ? AND status = 'pending'
    """, (model,))
    return cursor.fetchone()[0] > 0
```

## Rate Limiting

Per-IP daily limits prevent abuse:

```python
def check_rate_limit(ip_address: str) -> tuple[bool, int]:
    cursor.execute("""
        SELECT request_count FROM rate_limits
        WHERE ip_address = ? AND request_date = ?
    """, (ip_address, today))
    
    current_count = row[0] if row else 0
    return current_count < RATE_LIMIT, RATE_LIMIT - current_count
```

Rate limits reset at midnight (based on SQLite date comparison).

## Security Considerations

### Network Isolation

- Ollama binds to 127.0.0.1:11435 (localhost only)
- Proxy can bind to 0.0.0.0:11434 if needed
- No direct external access to Ollama

### Systemd Hardening

```ini
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/ohhhllama
PrivateTmp=yes
```

### Input Validation

- JSON parsing with error handling
- Model name extraction with fallbacks
- Rate limit enforcement
- HuggingFace repo_id validation

### HuggingFace Token Handling

- Token read from `HF_TOKEN` environment variable
- Used for gated models requiring authentication
- Never logged or stored in database

## Failure Modes

### Proxy Crashes

- Systemd auto-restarts (RestartSec=5)
- Queue persists in SQLite
- No data loss

### Ollama Unavailable

- Proxy returns 502 Bad Gateway
- Queue continues to accept requests
- Downloads retry when Ollama returns

### Download Fails

- Processor retries 3 times with 60s delay
- Status set to "failed" with error message
- Can be manually retried by resetting status

### HuggingFace-Specific Failures

- **Model not found**: Error stored, status set to "failed"
- **Unsupported architecture**: Clear error message in status
- **Conversion failure**: Intermediate files cleaned up, error logged
- **Import failure**: GGUF preserved for manual retry

## Performance

### Proxy Overhead

- Minimal for pass-through requests
- SQLite operations are fast (< 1ms)
- Threading handles concurrent requests

### Memory Usage

- Proxy: ~50MB typical
- SQLite: Negligible (file-based)
- Streaming prevents large memory buffers
- HuggingFace backend: Variable during conversion (depends on model size)

### Scalability

- Single-machine design
- Suitable for small teams (< 50 users)
- For larger deployments, consider Redis queue

## Disk Space Monitoring

The proxy monitors disk space to prevent storage exhaustion:

### Flow

```
Pull Request → Check Disk Space → Queue (if OK) or 507 Error (if full)
                     │
                     ▼
              os.statvfs(DISK_PATH)
                     │
                     ▼
              Calculate usage %
                     │
                     ▼
              Compare to DISK_THRESHOLD
```

### Configuration

```bash
DISK_PATH=/data/ollama      # Path to monitor
DISK_THRESHOLD=90           # Reject requests above this %
```

### Behavior

- **< threshold - 10%**: Status "ok"
- **>= threshold - 10%**: Status "warning" (still accepts requests)
- **>= threshold**: Status "critical" (rejects new requests with HTTP 507)

## Health Check Endpoint

The `/api/health` endpoint provides comprehensive system status:

```json
{
  "status": "healthy|degraded|unhealthy",
  "checks": {
    "proxy": {"status": "ok"},
    "backend": {"status": "ok|error", "url": "..."},
    "disk": {"status": "ok|warning|critical", "path": "...", "used_percent": N, "free_gb": N},
    "database": {"status": "ok|error", "path": "..."}
  },
  "timestamp": "ISO-8601"
}
```

### Status Determination

- **healthy**: All checks pass
- **degraded**: Non-critical issues (disk warning, database error)
- **unhealthy**: Critical issues (backend down, disk critical)

## Cleanup Processes

### Orphan Cleanup (on startup)

When the proxy starts, it resets any entries stuck in "downloading" status back to "pending". These are from interrupted previous runs.

```python
def cleanup_orphaned_downloads():
    UPDATE queue SET status = 'pending'
    WHERE status = 'downloading'
```

### Auto-cleanup (on startup)

Old completed/failed entries are automatically removed:

```python
def cleanup_old_entries():
    DELETE FROM queue
    WHERE status IN ('completed', 'failed')
    AND updated_at < datetime('now', '-30 days')
```

Configurable via `CLEANUP_DAYS` environment variable.

### HuggingFace Temp File Cleanup

The HuggingFace backend cleans up temporary conversion files:
- Intermediate f16 GGUF files (after quantization)
- Downloaded safetensors (after conversion)
- Controlled by `cleanup=True` parameter

## Future Improvements

1. **Priority queue** - Urgent models download first
2. **Bandwidth limiting** - Throttle download speed
3. **Web UI** - Visual queue management
4. **Notifications** - Alert when downloads complete
5. **Multi-backend** - Support multiple Ollama instances
6. **HuggingFace model caching** - Reuse downloaded GGUF files
7. **Parallel HuggingFace downloads** - Process multiple HF models concurrently
8. **Model metadata storage** - Track original HuggingFace repo for imported models
