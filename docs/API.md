# ohhhllama API Reference

ohhhllama acts as a transparent proxy for Ollama, adding queue management and HuggingFace integration.

**Base URL:** `http://localhost:11434`

## Standard Ollama Endpoints

All standard Ollama API endpoints are proxied transparently. See [Ollama API docs](https://github.com/ollama/ollama/blob/main/docs/api.md) for full details.

### List Models
```http
GET /api/tags
```

Returns list of installed models. ohhhllama adds queued models with `[QUEUED]` suffix.

**Response:**
```json
{
  "models": [
    {
      "name": "llama3:8b",
      "size": 4661224676,
      "details": {
        "family": "llama",
        "parameter_size": "8B",
        "quantization_level": "Q4_K_M"
      }
    },
    {
      "name": "* mistral [QUEUED]",
      "model": "mistral",
      "size": 0,
      "digest": "pending"
    }
  ]
}
```

### Pull Model (Queued)
```http
POST /api/pull
Content-Type: application/json

{"name": "llama3:8b"}
```

**Note:** Unlike standard Ollama, this queues the download for off-peak processing.

**Response:**
```json
{
  "status": "queued",
  "message": "Model llama3:8b added to download queue",
  "queue_id": 5,
  "rate_limit": {
    "remaining": 4,
    "limit": 5
  }
}
```

### Delete Model
```http
DELETE /api/delete
Content-Type: application/json

{"name": "llama3:8b"}
```

Works for both installed models and queued models.

### Generate
```http
POST /api/generate
Content-Type: application/json

{
  "model": "llama3:8b",
  "prompt": "Hello, world!"
}
```

Proxied directly to Ollama.

### Chat
```http
POST /api/chat
Content-Type: application/json

{
  "model": "llama3:8b",
  "messages": [
    {"role": "user", "content": "Hello!"}
  ]
}
```

Proxied directly to Ollama.

---

## ohhhllama Extensions

### Queue Status
```http
GET /api/queue
```

Returns current queue status and pending downloads.

**Response:**
```json
{
  "counts": {
    "pending": 2,
    "downloading": 0,
    "completed": 10,
    "failed": 1
  },
  "queue": [
    {
      "id": 5,
      "model": "llama3:8b",
      "type": "ollama",
      "requester_ip": "127.0.0.1",
      "status": "pending",
      "created_at": "2024-01-15 10:30:00",
      "updated_at": "2024-01-15 10:30:00"
    },
    {
      "id": 6,
      "model": "{\"repo_id\": \"TheBloke/Mistral-7B-GGUF\", \"quant\": \"Q4_K_M\"}",
      "type": "huggingface",
      "requester_ip": "127.0.0.1",
      "status": "pending",
      "created_at": "2024-01-15 10:35:00",
      "updated_at": "2024-01-15 10:35:00"
    }
  ],
  "recent": [
    {
      "id": 4,
      "model": "phi3:mini",
      "status": "completed",
      "error": null,
      "updated_at": "2024-01-14 22:15:00"
    }
  ]
}
```

### Health Check
```http
GET /api/health
```

Returns system health status.

**Response:**
```json
{
  "status": "healthy",
  "checks": {
    "proxy": {"status": "ok"},
    "backend": {"status": "ok", "url": "http://127.0.0.1:11435"},
    "disk": {
      "status": "ok",
      "path": "/data/ollama",
      "used_percent": 45,
      "free_gb": 234.5
    },
    "database": {"status": "ok", "path": "/var/lib/ohhhllama/queue.db"}
  },
  "timestamp": "2024-01-15T10:30:00.000000"
}
```

**Status values:**
- `healthy` - All systems operational
- `degraded` - Some non-critical issues
- `unhealthy` - Critical issues (e.g., disk full)

### Remove from Queue
```http
DELETE /api/queue
Content-Type: application/json

{"name": "llama3:8b"}
```

Removes a pending model from the queue (cannot remove if already downloading).

**Response:**
```json
{
  "status": "deleted",
  "message": "Model llama3:8b removed from queue"
}
```

---

## HuggingFace Endpoints

### Queue HuggingFace Model
```http
POST /api/hf/queue
Content-Type: application/json

{
  "repo_id": "TheBloke/Llama-2-7B-GGUF",
  "quant": "Q4_K_M",
  "name": "my-llama"
}
```

**Parameters:**
| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `repo_id` | Yes | - | HuggingFace repository ID |
| `quant` | No | Q4_K_M | Quantization type |
| `name` | No | auto | Custom name for Ollama |

**Response:**
```json
{
  "status": "queued",
  "message": "HuggingFace model TheBloke/Llama-2-7B-GGUF added to download queue",
  "queue_id": 7,
  "type": "huggingface"
}
```

**Finding Models:**
- Browse GGUF models: https://huggingface.co/models?library=gguf
- Popular providers: TheBloke, bartowski, QuantFactory

**Quantization Options:**
| Type | Quality | Size | Recommended For |
|------|---------|------|-----------------|
| Q8_0 | Best | Large | Maximum quality |
| Q5_K_M | Better | Medium | Quality-focused |
| Q4_K_M | Good | Small | General use (default) |
| Q3_K_M | Lower | Smaller | Memory constrained |

---

## Error Responses

All endpoints return errors in this format:

```json
{
  "error": "Error type",
  "message": "Detailed error message",
  "detail": "Additional context (optional)"
}
```

### Common Error Codes

| Code | Meaning |
|------|---------|
| 400 | Bad request (invalid JSON, missing parameters) |
| 404 | Model or resource not found |
| 429 | Rate limit exceeded |
| 502 | Ollama backend unavailable |
| 507 | Insufficient storage |

### Rate Limiting

When rate limited:
```json
{
  "error": "Rate limit exceeded",
  "message": "Maximum 5 model requests per day",
  "remaining": 0
}
```

Rate limits reset daily at midnight.

---

## Examples

### Queue multiple models
```bash
# Ollama models
curl -X POST http://localhost:11434/api/pull -d '{"name": "llama3:8b"}'
curl -X POST http://localhost:11434/api/pull -d '{"name": "mistral"}'

# HuggingFace models
curl -X POST http://localhost:11434/api/hf/queue \
  -H "Content-Type: application/json" \
  -d '{"repo_id": "TheBloke/Mistral-7B-v0.1-GGUF"}'
```

### Check queue and health
```bash
# Queue status
curl http://localhost:11434/api/queue | jq

# Health check
curl http://localhost:11434/api/health | jq
```

### Use with OpenWebUI
OpenWebUI connects to `http://localhost:11434` - no configuration needed. Queued models appear with `[QUEUED]` suffix in the model list.
