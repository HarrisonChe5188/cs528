from http.server import BaseHTTPRequestHandler, HTTPServer
from google.cloud import storage, logging as cloud_logging
import logging

# Configuration
BUCKET = "hche-cs528-hw2"
FOLDER = "20000"

# Cloud Logging setup
cloud_client = cloud_logging.Client()
cloud_client.setup_logging()  # routes logging to Cloud Logging

# Logger
logger = logging.getLogger("webserver")
logger.setLevel(logging.INFO)

# Storage client
storage_client = storage.Client()

class Handler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        # disable default logging to console
        return

    def do_GET(self):
        filename = self.path[1:]  # remove leading "/"
        if not filename:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"404 Not Found\n")
            logger.warning("404 Not Found: empty path")
            return

        bucket = storage_client.bucket(BUCKET)
        blob = bucket.blob(f"{FOLDER}/{filename}")

        if not blob.exists():
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"404 Not Found\n")
            logger.warning(f"404 Not Found: {FOLDER}/{filename}")
            return

        data = blob.download_as_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        logger.info(f"200 OK: Served {FOLDER}/{filename}")

    # catch-all for unsupported methods
    def handle_other_methods(self):
        self.send_response(501)
        self.end_headers()
        self.wfile.write(b"501 Not Implemented\n")
        logger.warning(f"501 Not Implemented: {self.command} {self.path}")

    # Override all other HTTP verbs to return 501
    do_POST = handle_other_methods
    do_PUT = handle_other_methods
    do_DELETE = handle_other_methods
    do_HEAD = handle_other_methods
    do_CONNECT = handle_other_methods
    do_OPTIONS = handle_other_methods
    do_TRACE = handle_other_methods
    do_PATCH = handle_other_methods

# Run the server
HTTPServer(("", 8080), Handler).serve_forever()