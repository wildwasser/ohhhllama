#!/usr/bin/env python3
"""
ohhhllama - Ollama Proxy with Download Queue

A transparent proxy for Ollama that intercepts model pull requests
and queues them for off-peak processing.

Features:
- Intercepts POST /api/pull requests and queues them
- Rate limiting per IP address
- Request deduplication
- All other requests pass through unchanged
- Custom /api/queue endpoint to view queue status
"""

import http.server
import json
import logging
import os
import re
import sqlite3
import socketserver
import urllib.request
import urllib.error
from datetime import datetime, date
from typing import Optional
from urllib.parse import urlparse

# Configuration from environment
OLLAMA_BACKEND = os.environ.get("OLLAMA_BACKEND", "http://127.0.0.1:11435")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "11434"))
DB_PATH = os.environ.get("DB_PATH", "/var/lib/ohhhllama/queue.db")
RATE_LIMIT = int(os.environ.get("RATE_LIMIT", "5"))

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format="[ohhhllama] %(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
logger = logging.getLogger(__name__)


def init_database() -> None:
    """Initialize the SQLite database with required tables."""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    # Queue table for model download requests
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            model TEXT NOT NULL,
            requester_ip TEXT NOT NULL,
            status TEXT DEFAULT 'pending',
            error TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    
    # Rate limiting table
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS rate_limits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ip_address TEXT NOT NULL,
            request_date DATE NOT NULL,
            request_count INTEGER DEFAULT 1,
            UNIQUE(ip_address, request_date)
        )
    """)
    
    # Index for faster lookups
    cursor.execute("""
        CREATE INDEX IF NOT EXISTS idx_queue_status ON queue(status)
    """)
    cursor.execute("""
        CREATE INDEX IF NOT EXISTS idx_queue_model ON queue(model)
    """)
    cursor.execute("""
        CREATE INDEX IF NOT EXISTS idx_rate_limits_ip_date ON rate_limits(ip_address, request_date)
    """)
    
    conn.commit()
    conn.close()
    logger.info(f"Database initialized at {DB_PATH}")


def check_rate_limit(ip_address: str) -> tuple[bool, int]:
    """
    Check if an IP address has exceeded the rate limit.
    
    Args:
        ip_address: The client's IP address
        
    Returns:
        Tuple of (is_allowed, remaining_requests)
    """
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    today = date.today().isoformat()
    
    cursor.execute("""
        SELECT request_count FROM rate_limits
        WHERE ip_address = ? AND request_date = ?
    """, (ip_address, today))
    
    row = cursor.fetchone()
    current_count = row[0] if row else 0
    
    conn.close()
    
    remaining = max(0, RATE_LIMIT - current_count)
    is_allowed = current_count < RATE_LIMIT
    
    return is_allowed, remaining


def increment_rate_limit(ip_address: str) -> None:
    """Increment the rate limit counter for an IP address."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    today = date.today().isoformat()
    
    cursor.execute("""
        INSERT INTO rate_limits (ip_address, request_date, request_count)
        VALUES (?, ?, 1)
        ON CONFLICT(ip_address, request_date)
        DO UPDATE SET request_count = request_count + 1
    """, (ip_address, today))
    
    conn.commit()
    conn.close()


def is_model_in_queue(model: str) -> bool:
    """Check if a model is already in the pending queue."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    cursor.execute("""
        SELECT COUNT(*) FROM queue
        WHERE model = ? AND status = 'pending'
    """, (model,))
    
    count = cursor.fetchone()[0]
    conn.close()
    
    return count > 0


def add_to_queue(model: str, ip_address: str) -> dict:
    """
    Add a model to the download queue.
    
    Args:
        model: The model name to queue
        ip_address: The requester's IP address
        
    Returns:
        Dict with queue status information
    """
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    # Check if already queued (deduplication)
    if is_model_in_queue(model):
        conn.close()
        return {
            "status": "already_queued",
            "message": f"Model {model} is already in the download queue"
        }
    
    # Add to queue
    cursor.execute("""
        INSERT INTO queue (model, requester_ip, status)
        VALUES (?, ?, 'pending')
    """, (model, ip_address))
    
    queue_id = cursor.lastrowid
    conn.commit()
    conn.close()
    
    # Increment rate limit
    increment_rate_limit(ip_address)
    
    logger.info(f"Queued model {model} (id={queue_id}) from {ip_address}")
    
    return {
        "status": "queued",
        "message": f"Model {model} added to download queue",
        "queue_id": queue_id
    }


def get_queue_status() -> dict:
    """Get the current queue status."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    # Get counts by status
    cursor.execute("""
        SELECT status, COUNT(*) FROM queue
        GROUP BY status
    """)
    status_counts = dict(cursor.fetchall())
    
    # Get pending items
    cursor.execute("""
        SELECT id, model, requester_ip, status, created_at, updated_at
        FROM queue
        WHERE status IN ('pending', 'downloading')
        ORDER BY created_at ASC
        LIMIT 50
    """)
    
    pending = []
    for row in cursor.fetchall():
        pending.append({
            "id": row[0],
            "model": row[1],
            "requester_ip": row[2],
            "status": row[3],
            "created_at": row[4],
            "updated_at": row[5]
        })
    
    # Get recent completed/failed
    cursor.execute("""
        SELECT id, model, status, error, updated_at
        FROM queue
        WHERE status IN ('completed', 'failed')
        ORDER BY updated_at DESC
        LIMIT 10
    """)
    
    recent = []
    for row in cursor.fetchall():
        recent.append({
            "id": row[0],
            "model": row[1],
            "status": row[2],
            "error": row[3],
            "updated_at": row[4]
        })
    
    conn.close()
    
    return {
        "counts": {
            "pending": status_counts.get("pending", 0),
            "downloading": status_counts.get("downloading", 0),
            "completed": status_counts.get("completed", 0),
            "failed": status_counts.get("failed", 0)
        },
        "queue": pending,
        "recent": recent
    }


def check_model_exists(model: str) -> bool:
    """Check if a model already exists in Ollama."""
    try:
        url = f"{OLLAMA_BACKEND}/api/tags"
        req = urllib.request.Request(url)
        
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.loads(response.read().decode())
            models = data.get("models", [])
            
            # Normalize model name for comparison
            model_base = model.split(":")[0]
            
            for m in models:
                m_name = m.get("name", "")
                m_base = m_name.split(":")[0]
                
                # Check exact match or base name match
                if m_name == model or m_base == model_base:
                    return True
                    
    except Exception as e:
        logger.warning(f"Error checking model existence: {e}")
    
    return False


class OhhhllamaHandler(http.server.BaseHTTPRequestHandler):
    """HTTP request handler for the ohhhllama proxy."""
    
    def log_message(self, format: str, *args) -> None:
        """Override to use our logger."""
        logger.info(f"{self.address_string()} - {format % args}")
    
    def get_client_ip(self) -> str:
        """Get the client's IP address, considering X-Forwarded-For."""
        forwarded = self.headers.get("X-Forwarded-For")
        if forwarded:
            return forwarded.split(",")[0].strip()
        return self.client_address[0]
    
    def send_json_response(self, status_code: int, data: dict) -> None:
        """Send a JSON response."""
        body = json.dumps(data).encode()
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    
    def proxy_request(self, method: str, body: Optional[bytes] = None) -> None:
        """Proxy a request to the Ollama backend."""
        url = f"{OLLAMA_BACKEND}{self.path}"
        
        try:
            req = urllib.request.Request(url, data=body, method=method)
            
            # Copy headers (except Host)
            for header, value in self.headers.items():
                if header.lower() not in ("host", "content-length"):
                    req.add_header(header, value)
            
            with urllib.request.urlopen(req, timeout=300) as response:
                # Send response status
                self.send_response(response.status)
                
                # Copy response headers
                for header, value in response.getheaders():
                    if header.lower() not in ("transfer-encoding",):
                        self.send_header(header, value)
                self.end_headers()
                
                # Stream response body
                while True:
                    chunk = response.read(8192)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            for header, value in e.headers.items():
                if header.lower() not in ("transfer-encoding",):
                    self.send_header(header, value)
            self.end_headers()
            self.wfile.write(e.read())
            
        except urllib.error.URLError as e:
            logger.error(f"Backend connection error: {e}")
            self.send_json_response(502, {
                "error": "Backend unavailable",
                "detail": str(e.reason)
            })
            
        except Exception as e:
            logger.error(f"Proxy error: {e}")
            self.send_json_response(500, {
                "error": "Internal proxy error",
                "detail": str(e)
            })
    
    def handle_pull_request(self, body: bytes) -> None:
        """Handle POST /api/pull requests by queuing them."""
        client_ip = self.get_client_ip()
        
        try:
            data = json.loads(body.decode())
        except json.JSONDecodeError:
            self.send_json_response(400, {"error": "Invalid JSON"})
            return
        
        model = data.get("name") or data.get("model")
        if not model:
            self.send_json_response(400, {"error": "Model name required"})
            return
        
        # Check if model already exists
        if check_model_exists(model):
            logger.info(f"Model {model} already exists, passing through")
            self.proxy_request("POST", body)
            return
        
        # Check rate limit
        is_allowed, remaining = check_rate_limit(client_ip)
        if not is_allowed:
            logger.warning(f"Rate limit exceeded for {client_ip}")
            self.send_json_response(429, {
                "error": "Rate limit exceeded",
                "message": f"Maximum {RATE_LIMIT} model requests per day",
                "remaining": 0
            })
            return
        
        # Add to queue
        result = add_to_queue(model, client_ip)
        
        # Add rate limit info to response
        result["rate_limit"] = {
            "remaining": remaining - 1,
            "limit": RATE_LIMIT
        }
        
        self.send_json_response(202, result)
    
    def handle_queue_request(self) -> None:
        """Handle GET /api/queue requests."""
        status = get_queue_status()
        self.send_json_response(200, status)
    
    def do_GET(self) -> None:
        """Handle GET requests."""
        if self.path == "/api/queue":
            self.handle_queue_request()
        else:
            self.proxy_request("GET")
    
    def do_POST(self) -> None:
        """Handle POST requests."""
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""
        
        if self.path == "/api/pull":
            self.handle_pull_request(body)
        else:
            self.proxy_request("POST", body)
    
    def do_DELETE(self) -> None:
        """Handle DELETE requests."""
        self.proxy_request("DELETE")
    
    def do_PUT(self) -> None:
        """Handle PUT requests."""
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""
        self.proxy_request("PUT", body)
    
    def do_HEAD(self) -> None:
        """Handle HEAD requests."""
        self.proxy_request("HEAD")


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """Threaded HTTP server for handling concurrent requests."""
    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    """Main entry point."""
    logger.info("=" * 50)
    logger.info("ohhhllama - Ollama Proxy with Download Queue")
    logger.info("=" * 50)
    logger.info(f"Backend: {OLLAMA_BACKEND}")
    logger.info(f"Listen port: {LISTEN_PORT}")
    logger.info(f"Database: {DB_PATH}")
    logger.info(f"Rate limit: {RATE_LIMIT} requests/day/IP")
    
    # Initialize database
    init_database()
    
    # Test backend connectivity
    try:
        req = urllib.request.Request(f"{OLLAMA_BACKEND}/api/tags")
        with urllib.request.urlopen(req, timeout=5) as response:
            logger.info("Backend connectivity: OK")
    except Exception as e:
        logger.warning(f"Backend connectivity: FAILED ({e})")
        logger.warning("Proxy will start anyway, but requests may fail")
    
    # Start server
    server = ThreadedHTTPServer(("0.0.0.0", LISTEN_PORT), OhhhllamaHandler)
    logger.info(f"Proxy listening on 0.0.0.0:{LISTEN_PORT}")
    logger.info("Press Ctrl+C to stop")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        server.shutdown()


if __name__ == "__main__":
    main()
