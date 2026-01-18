# ohhhllama Architecture

This document explains the technical architecture of ohhhllama.

## Overview

ohhhllama is a transparent proxy that sits between Ollama clients and the Ollama server. It intercepts model download requests and queues them for off-peak processing.

```
┌─────────────────────────────────────────────────────────────────┐
│                         Client Machine                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐                                                │
│  │   Client    │  (ollama CLI, curl, applications)              │
│  │ :11434      │                                                │
│  └──────┬──────┘                                                │
│         │                                                       │
│         ▼                                                       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              ohhhllama Proxy (Python)                    │   │
│  │                    :11434                                │   │
│  │  ┌─────────────────────────────────────────────────┐    │   │
│  │  │  Request Router                                  │    │   │
│  │  │  - POST /api/pull → Queue Handler               │    │   │
│  │  │  - GET /api/queue → Queue Status                │    │   │
│  │  │  - Everything else → Pass-through               │    │   │
│  │  └─────────────────────────────────────────────────┘    │   │
│  │                         │                                │   │
│  │                         ▼                                │   │
│  │  ┌─────────────────────────────────────────────────┐    │   │
│  │  │  SQLite Database                                 │    │   │
│  │  │  /var/lib/ohhhllama/queue.db                    │    │   │
│  │  │  - queue table (pending downloads)              │    │   │
│  │  │  - rate_limits table (per-IP tracking)          │    │   │
│  │  └─────────────────────────────────────────────────┘    │   │
│  └─────────────────────────────────────────────────────────┘   │
│         │                                                       │
│         ▼                                                       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Ollama (Docker Container)                   │   │
│  │                    :11435                                │   │
│  │  - Model inference                                       │   │
│  │  - Model storage (/root/.ollama via volume)             │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Queue Processor (Systemd Timer)             │   │
│  │              Runs at 3 AM                                │   │
│  │  - Reads pending items from SQLite                      │   │
│  │  - Downloads models via Ollama API                      │   │
│  │  - Updates status in database                           │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Proxy Server (`proxy.py`)

The proxy is a Python HTTP server that:

- Listens on port 11434 (standard Ollama port)
- Intercepts specific requests (POST /api/pull)
- Passes through all other requests unchanged
- Manages the SQLite database

**Key Features:**
- Threaded request handling for concurrency
- Streaming response support for large payloads
- Header preservation for compatibility

### 2. SQLite Database

We chose SQLite because:

- **Zero configuration** - No separate database server needed
- **Reliable** - ACID compliant, handles crashes gracefully
- **Portable** - Single file, easy to backup/restore
- **Sufficient** - Queue operations are simple CRUD

**Schema:**

```sql
-- Download queue
CREATE TABLE queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    model TEXT NOT NULL,           -- Model name (e.g., "llama2:70b")
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

### 3. Queue Processor (`process-queue.sh`)

A bash script that:

- Runs via systemd timer at 3 AM (configurable via `/etc/systemd/system/ollama-queue.timer`)
- Queries pending items from SQLite
- Downloads each model via Ollama API
- Updates status on success/failure
- Implements retry logic with backoff

### 4. Ollama Container

Standard Ollama Docker container with:

- Port mapped to 11435 (internal only)
- Volume for model persistence
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

### Pull Request (POST /api/pull)

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
   - Add to queue
   - Return "queued" response

### Queue Processing (3 AM)

```
Systemd Timer → Processor → SQLite → Ollama
                               ↓
                           (update status)
```

1. Systemd timer triggers processor script
2. Script queries pending items
3. For each item:
   - Update status to "downloading"
   - Call Ollama pull API
   - Update status to "completed" or "failed"

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

## Performance

### Proxy Overhead

- Minimal for pass-through requests
- SQLite operations are fast (< 1ms)
- Threading handles concurrent requests

### Memory Usage

- Proxy: ~50MB typical
- SQLite: Negligible (file-based)
- Streaming prevents large memory buffers

### Scalability

- Single-machine design
- Suitable for small teams (< 50 users)
- For larger deployments, consider Redis queue

## Future Improvements

1. **Priority queue** - Urgent models download first
2. **Bandwidth limiting** - Throttle download speed
3. **Web UI** - Visual queue management
4. **Notifications** - Alert when downloads complete
5. **Multi-backend** - Support multiple Ollama instances
