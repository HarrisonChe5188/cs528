import functions_framework
import json
import logging
from datetime import datetime
from google.cloud import storage, pubsub_v1
from google.cloud import logging as cloud_logging
import os

# Configuration (safe at top level - just strings and simple data)
PROJECT = os.getenv("GCP_PROJECT", "superb-memory-485622-u3")
BUCKET_NAME = "hche-cs528-hw2"
FILES_PREFIX = "20000"
TOPIC_PATH = f"projects/{PROJECT}/topics/forbidden-exports"

FORBIDDEN = {
    "north korea", "iran", "cuba", "myanmar",
    "iraq", "libya", "sudan", "zimbabwe", "syria"
}

# Lazy-loaded clients - initialized to None, created on first request
_storage_client = None
_publisher = None
_logger = None
_cloud_logging_client = None


def get_clients():
    """Initialize and return GCP clients lazily."""
    global _storage_client, _publisher, _logger, _cloud_logging_client
    
    # Only initialize once
    if _storage_client is None:
        # Set up Cloud Logging first
        _cloud_logging_client = cloud_logging.Client()
        _cloud_logging_client.setup_logging()
        
        # Create logger
        _logger = logging.getLogger("file-service")
        
        # Create other clients
        _storage_client = storage.Client(project=PROJECT)
        _publisher = pubsub_v1.PublisherClient()
        
        _logger.info("GCP clients initialized successfully")
    
    return _storage_client, _publisher, _logger


@functions_framework.http
def file_service(request):
    # Get or initialize clients on first request
    storage_client, publisher, logger = get_clients()
    
    # Extract X-country header
    country_raw = request.headers.get("X-country", "")
    country = country_raw.strip()
    country_norm = country.lower()

    # Reject non-GET methods
    if request.method != "GET":
        logger.warning(json.dumps({
            "event": "method_not_implemented",
            "method": request.method
        }))
        return ("Not implemented", 501)

    # If country header is present and forbidden -> publish and return 400
    if country_norm in FORBIDDEN:
        payload = {
            "event": "forbidden_country_request",
            "country": country,
            "country_norm": country_norm,
            "path": request.path,
            "file": request.path.strip("/").split("/")[-1],
            "method": request.method,
            "timestamp": datetime.utcnow().isoformat()
        }

        logger.warning(json.dumps({
            "severity": "WARNING",
            "reason": "forbidden_country",
            "country": country,
            "path": request.path
        }))
        print(f"Forbidden request from country: {country}")

        # Publish with timeout to prevent hanging
        try:
            future = publisher.publish(
                TOPIC_PATH,
                json.dumps(payload).encode("utf-8")
            )
            # Add timeout to prevent hanging
            msg_id = future.result(timeout=5)
            print(f"Published message: {msg_id}")
        except Exception as e:
            print(f"Publish error (continuing anyway): {e}")
            # Continue even if publish fails

        return ("Permission denied", 400)

    # Serve file logic
    # Extract filename from path (e.g., /file-service/20000/0.html -> 0.html)
    path_parts = request.path.strip("/").split("/")
    filename = path_parts[-1] if path_parts else ""
    
    if not filename:
        return ("File not specified", 400)
    
    # Construct full blob path: 20000/filename
    blob_path = f"{FILES_PREFIX}/{filename}"
    
    try:
        bucket = storage_client.bucket(BUCKET_NAME)
        blob = bucket.blob(blob_path)
        
        if not blob.exists():
            logger.error(json.dumps({"event": "file_not_found", "file": blob_path}))
            print(f"File not found: {blob_path}")
            return ("File not found", 404)
    
        content = blob.download_as_text()
        logger.info(json.dumps({"event": "file_served", "file": blob_path, "country": country}))
        print(f"Served file {blob_path} to country {country}")
        return (content, 200)
        
    except Exception as e:
        logger.error(json.dumps({"event": "file_error", "error": str(e)}))
        print(f"Error serving file: {e}")
        return ("Internal server error", 500)