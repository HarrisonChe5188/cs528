#!/usr/bin/env python3
"""
HW9 Web Server - runs in a GKE container.
Serves files from GCS, logs to Cloud Logging, publishes forbidden-country
requests to Pub/Sub (picked up by the forbidden-service VM).
"""

from http.server import BaseHTTPRequestHandler, HTTPServer
from google.cloud import storage, logging as cloud_logging
from google.cloud import pubsub_v1
import logging
import json
import os
from datetime import datetime

# ---------------------------------------------------------------------------
# CONFIG  (all overridable via env vars / K8s ConfigMap)
# ---------------------------------------------------------------------------
PROJECT    = os.environ.get("GCP_PROJECT", "superb-memory-485622-u3")
BUCKET     = os.environ.get("BUCKET",      "hche-cs528-hw2")
FOLDER     = os.environ.get("FOLDER",      "20000")
PORT       = int(os.environ.get("PORT",    "8080"))
FORB_TOPIC = os.environ.get("FORB_TOPIC",
             f"projects/{PROJECT}/topics/hw4-forbidden-exports")

BANNED_COUNTRIES = {
    "North Korea", "Iran", "Cuba", "Myanmar",
    "Iraq", "Libya", "Sudan", "Zimbabwe", "Syria"
}

# ---------------------------------------------------------------------------
# Cloud Logging
# ---------------------------------------------------------------------------
cloud_client = cloud_logging.Client()
cloud_client.setup_logging()
logger = logging.getLogger("webserver")
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# GCP clients
# ---------------------------------------------------------------------------
storage_client = storage.Client()
publisher      = pubsub_v1.PublisherClient()


def write_gcs_event(bucket_name: str, payload_dict: dict) -> None:
    """Persist a small JSON record under gs://<bucket>/logs/ for audit."""
    ts   = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    name = f"logs/forbidden-{ts}-{os.getpid()}.json"
    blob = storage_client.bucket(bucket_name).blob(name)
    try:
        blob.upload_from_string(
            json.dumps(payload_dict), content_type="application/json"
        )
    except Exception as exc:
        logger.error(f"GCS event write failed for {name}: {exc}")


# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):  # noqa: A002
        return  # silence default per-request console line

    # ------------------------------------------------------------------
    # GET
    # ------------------------------------------------------------------
    def do_GET(self):
        filename = self.path.lstrip("/").split("/")[-1]
        country  = (self.headers.get("X-Country") or "").strip()

        # ---- banned-country check ----
        if country and country in BANNED_COUNTRIES:
            payload = {
                "event":     "forbidden_country_request",
                "country":   country,
                "file":      filename,
                "path":      self.path,
                "timestamp": datetime.utcnow().isoformat(),
            }

            # 1. Cloud Logging
            logger.critical(json.dumps(payload))

            # 2. Pub/Sub (best-effort)
            try:
                future = publisher.publish(FORB_TOPIC,
                                           json.dumps(payload).encode())
                future.result(timeout=5)
            except Exception as exc:
                logger.error(f"Pub/Sub publish failed: {exc}")

            # 3. GCS audit log
            try:
                write_gcs_event(BUCKET, payload)
            except Exception as exc:
                logger.error(f"GCS write failed: {exc}")

            self._send(400, b"400 Bad Request\n")
            return

        # ---- empty path ----
        if not filename:
            logger.warning("404 Not Found: empty path")
            self._send(404, b"404 Not Found\n")
            return

        # ---- serve from GCS ----
        blob = storage_client.bucket(BUCKET).blob(f"{FOLDER}/{filename}")
        try:
            if not blob.exists():
                logger.warning(f"404 Not Found: {FOLDER}/{filename}")
                self._send(404, b"404 Not Found\n")
                return

            data = blob.download_as_bytes()
            self.send_response(200)
            self.send_header("Content-Type",   "text/html")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            logger.info(f"200 OK: {FOLDER}/{filename}")

        except Exception as exc:
            logger.error(f"Error serving {FOLDER}/{filename}: {exc}")
            self._send(500, b"500 Internal Server Error\n")

    # ------------------------------------------------------------------
    # All other HTTP methods -> 501
    # ------------------------------------------------------------------
    def _handle_unimplemented(self):
        logger.warning(f"501 Not Implemented: {self.command} {self.path}")
        self._send(501, b"501 Not Implemented\n")

    do_POST    = _handle_unimplemented
    do_PUT     = _handle_unimplemented
    do_DELETE  = _handle_unimplemented
    do_HEAD    = _handle_unimplemented
    do_CONNECT = _handle_unimplemented
    do_OPTIONS = _handle_unimplemented
    do_TRACE   = _handle_unimplemented
    do_PATCH   = _handle_unimplemented

    # ------------------------------------------------------------------
    # Helper
    # ------------------------------------------------------------------
    def _send(self, code: int, body: bytes) -> None:
        self.send_response(code)
        self.end_headers()
        self.wfile.write(body)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    server = HTTPServer(("", PORT), Handler)
    logger.info(f"Web server listening on port {PORT}")
    server.serve_forever()