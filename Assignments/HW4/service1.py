#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
from google.cloud import storage, logging as cloud_logging
from google.cloud import pubsub_v1
import logging
import json
import os
from datetime import datetime

# CONFIG
PROJECT = os.environ.get("GCP_PROJECT", "superb-memory-485622-u3")
BUCKET = os.environ.get("BUCKET", "hche-cs528-hw2")
FOLDER = os.environ.get("FOLDER", "20000")
PORT = int(os.environ.get("PORT", "8080"))
FORB_TOPIC = os.environ.get("FORB_TOPIC", f"projects/{PROJECT}/topics/hw4-forbidden-exports")

BANNED_COUNTRIES = {
    "North Korea","Iran","Cuba","Myanmar","Iraq","Libya","Sudan","Zimbabwe","Syria"
}

# Cloud Logging
cloud_client = cloud_logging.Client()
cloud_client.setup_logging()
logger = logging.getLogger("webserver")
logger.setLevel(logging.INFO)

# Clients
storage_client = storage.Client()
publisher = pubsub_v1.PublisherClient()  # uses application default credentials

def write_gcs_event(bucket_name, payload_dict):
    """Write a small JSON object to gs://<bucket>/logs/ for later reference.
       This will NOT touch your 20000/ objects.
    """
    ts = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    name = f"logs/forbidden-{ts}-{os.getpid()}.json"
    blob = storage_client.bucket(bucket_name).blob(name)
    try:
        blob.upload_from_string(json.dumps(payload_dict), content_type="application/json")
    except Exception as e:
        logger.error(f"Failed to write GCS event {name}: {e}")

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # silence default console logging
        return

    def do_GET(self):
        # filename and country header
        filename = self.path[1:].split("/")[-1]
        country = (self.headers.get("X-Country") or "").strip()

        # check banned
        if country and country in BANNED_COUNTRIES:
            payload = {
                "event": "forbidden_country_request",
                "country": country,
                "file": filename,
                "path": self.path,
                "timestamp": datetime.utcnow().isoformat()
            }

            # Cloud Logging CRITICAL
            logger.critical(json.dumps(payload))

            # Publish to Pub/Sub (best-effort)
            try:
                data = json.dumps(payload).encode("utf-8")
                # publisher.publish returns a future
                future = publisher.publish(FORB_TOPIC, data)
                future.result(timeout=5)
            except Exception as e:
                logger.error(f"Failed to publish forbidden event: {e}")

            # Also write small GCS object under logs/ so you have a copy in your bucket
            try:
                write_gcs_event(BUCKET, payload)
            except Exception as e:
                logger.error(f"GCS write failed: {e}")

            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"400 Bad Request\n")
            return

        # normal flow: file exists?
        if not filename:
            logger.warning("404 Not Found: empty path")
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"404 Not Found\n")
            return

        blob = storage_client.bucket(BUCKET).blob(f"{FOLDER}/{filename}")
        try:
            if not blob.exists():
                logger.warning(f"404 Not Found: {FOLDER}/{filename}")
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"404 Not Found\n")
                return

            data = blob.download_as_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            logger.info(f"200 OK: Served {FOLDER}/{filename}")
        except Exception as e:
            logger.error(f"Error serving {FOLDER}/{filename}: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"500 Internal Server Error\n")

    def handle_other_methods(self):
        logger.warning(f"501 Not Implemented: {self.command} {self.path}")
        self.send_response(501)
        self.end_headers()
        self.wfile.write(b"501 Not Implemented\n")

    do_POST = handle_other_methods
    do_PUT = handle_other_methods
    do_DELETE = handle_other_methods
    do_HEAD = handle_other_methods
    do_CONNECT = handle_other_methods
    do_OPTIONS = handle_other_methods
    do_TRACE = handle_other_methods
    do_PATCH = handle_other_methods

if __name__ == "__main__":
    HTTPServer(("", PORT), Handler).serve_forever() 