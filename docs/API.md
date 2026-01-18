# ohhhllama API Reference

This document describes all API endpoints provided by ohhhllama.

## Base URL

```
http://localhost:11434
```

## Custom Endpoints

These endpoints are specific to ohhhllama and not part of the standard Ollama API.

### GET /api/queue

Get the current download queue status.

**Request:**
```bash
curl http://localhost:11434/api/queue
```

**Response:**
```json
{
  "counts": {
    "pending": 3,
    "downloading": 1,
    "completed": 15,
    "failed": 2
  },
  "queue": [
    {
      "id": 42,
      "model": "llama2:70b",
      "requester_ip": "192.168.1.100",
      "status": "downloading",
      "created_at": "2024-01-15 14:30:00",
      "updated_at": "2024-01-16 03:00:05"
    },
    {
      "id": 43,
      "model": "codellama:34b",
      "requester_ip": "192.168.1.101",
      "status": "pending",
      "created_at": "2024-01-15 16:45:00",
      "updated_at": "2024-01-15 16:45:00"
    }
  ],
  "recent": [
    {
      "id": 41,
      "model": "mistral:7b",
      "status": "completed",
      "error": null,
      "updated_at": "2024-01-16 03:15:00"
    },
    {
      "id": 40,
      "model": "invalid-model",
      "status": "failed",
      "error": "Download failed after 3 attempts",
      "updated_at": "2024-01-16 03:10:00"
    }
  ]
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `counts` | object | Count of items by status |
| `counts.pending` | integer | Models waiting to download |
| `counts.downloading` | integer | Models currently downloading |
| `counts.completed` | integer | Successfully downloaded models |
| `counts.failed` | integer | Failed downloads |
| `queue` | array | Pending and downloading items (max 50) |
| `recent` | array | Recent completed/failed items (max 10) |

---

### DELETE /api/queue

Remove a model from the download queue. Only pending models can be removed (not models currently downloading).

**Request:**
```bash
curl -X DELETE http://localhost:11434/api/queue -d '{"name": "llama2:70b"}'
```

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Model name to remove |
| `model` | string | No | Alternative to `name` |

**Response (Success):**
```json
{
  "status": "deleted",
  "message": "Model llama2:70b removed from queue"
}
```

**Response (Not Found):**
```json
{
  "status": "not_found",
  "message": "Model llama2:70b not in queue (or already processing)"
}
```

**Status Codes:**

| Code | Description |
|------|-------------|
| 200 | Model removed successfully |
| 400 | Invalid request (missing model name or invalid JSON) |
| 404 | Model not found in queue (or already processing) |

---

## Modified Endpoints

These Ollama endpoints have modified behavior in ohhhllama.

### POST /api/pull

Request a model download. Instead of downloading immediately, the request is queued for off-peak processing.

**Request:**
```bash
curl http://localhost:11434/api/pull -d '{"name": "llama2:70b"}'
```

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Model name to download |
| `model` | string | No | Alternative to `name` |

**Response (Queued):**
```json
{
  "status": "queued",
  "message": "Model llama2:70b added to download queue",
  "queue_id": 42,
  "rate_limit": {
    "remaining": 4,
    "limit": 5
  }
}
```

**Response (Already Queued):**
```json
{
  "status": "already_queued",
  "message": "Model llama2:70b is already in the download queue"
}
```

**Response (Model Exists):**

If the model already exists in Ollama, the request passes through to Ollama and returns the standard Ollama response.

**Response (Rate Limited):**
```json
{
  "error": "Rate limit exceeded",
  "message": "Maximum 5 model requests per day",
  "remaining": 0
}
```

**Status Codes:**

| Code | Description |
|------|-------------|
| 202 | Request queued successfully |
| 200 | Model exists, passed through to Ollama |
| 400 | Invalid request (missing model name) |
| 429 | Rate limit exceeded |

---

## Pass-Through Endpoints

All other Ollama API endpoints pass through unchanged. Here's a summary:

### GET /api/tags

List available models.

```bash
curl http://localhost:11434/api/tags
```

### POST /api/generate

Generate a completion.

```bash
curl http://localhost:11434/api/generate -d '{
  "model": "llama2",
  "prompt": "Why is the sky blue?"
}'
```

### POST /api/chat

Chat with a model.

```bash
curl http://localhost:11434/api/chat -d '{
  "model": "llama2",
  "messages": [
    {"role": "user", "content": "Hello!"}
  ]
}'
```

### POST /api/embeddings

Generate embeddings.

```bash
curl http://localhost:11434/api/embeddings -d '{
  "model": "llama2",
  "prompt": "The quick brown fox"
}'
```

### GET /api/show

Show model information.

```bash
curl http://localhost:11434/api/show -d '{"name": "llama2"}'
```

### DELETE /api/delete

Delete a model.

```bash
curl -X DELETE http://localhost:11434/api/delete -d '{"name": "llama2"}'
```

### POST /api/copy

Copy a model.

```bash
curl http://localhost:11434/api/copy -d '{
  "source": "llama2",
  "destination": "llama2-backup"
}'
```

### POST /api/create

Create a model from a Modelfile.

```bash
curl http://localhost:11434/api/create -d '{
  "name": "my-model",
  "modelfile": "FROM llama2\nSYSTEM You are a helpful assistant."
}'
```

### GET /

Health check / version info.

```bash
curl http://localhost:11434/
```

---

## Error Responses

All error responses follow this format:

```json
{
  "error": "Error type",
  "detail": "Detailed error message"
}
```

### Common Errors

| Code | Error | Description |
|------|-------|-------------|
| 400 | Invalid JSON | Request body is not valid JSON |
| 400 | Model name required | Missing `name` or `model` field |
| 429 | Rate limit exceeded | Too many pull requests today |
| 502 | Backend unavailable | Cannot connect to Ollama |
| 500 | Internal proxy error | Unexpected proxy error |

---

## Rate Limiting

Pull requests are rate-limited per IP address:

- **Default limit**: 5 requests per day per IP
- **Reset time**: Midnight (server time)
- **Scope**: Only affects `/api/pull` for new models

Rate limit information is included in successful queue responses:

```json
{
  "rate_limit": {
    "remaining": 4,
    "limit": 5
  }
}
```

---

## Headers

### Request Headers

| Header | Description |
|--------|-------------|
| `Content-Type` | Should be `application/json` for POST requests |
| `X-Forwarded-For` | Used to determine client IP (for proxied requests) |

### Response Headers

| Header | Description |
|--------|-------------|
| `Content-Type` | `application/json` for JSON responses |
| `Content-Length` | Response body size |

---

## Examples

### Queue a model and check status

```bash
# Queue a large model
curl http://localhost:11434/api/pull -d '{"name": "llama2:70b"}'

# Check queue status
curl http://localhost:11434/api/queue | jq .

# Wait for 3 AM processing, then verify
curl http://localhost:11434/api/tags | jq '.models[].name'
```

### Use with ollama CLI

The ollama CLI works normally for most operations:

```bash
# These work immediately
ollama list
ollama run llama2  # if already downloaded
ollama show llama2

# This gets queued
ollama pull llama2:70b
# Note: CLI may show unexpected output since response format differs
```

### Integration with applications

```python
import requests

# Queue a model
response = requests.post(
    "http://localhost:11434/api/pull",
    json={"name": "codellama:34b"}
)
result = response.json()

if result.get("status") == "queued":
    print(f"Model queued, ID: {result['queue_id']}")
    print(f"Remaining requests today: {result['rate_limit']['remaining']}")
elif result.get("status") == "already_queued":
    print("Model already in queue")
else:
    print("Model exists or error occurred")

# Check queue
queue = requests.get("http://localhost:11434/api/queue").json()
print(f"Pending downloads: {queue['counts']['pending']}")
```
