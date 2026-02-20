import functions_framework
from google.cloud import storage
import logging
import requests

BUCKET_NAME = "hche-cs528-hw2"

# Forbidden export countries
FORBIDDEN = {
    "North Korea", "Iran", "Cuba", "Myanmar",
    "Iraq", "Libya", "Sudan", "Zimbabwe", "Syria"
}

SECOND_SERVICE_URL = "http://localhost:8081"

storage_client = storage.Client(project="superb-memory-485622-u3")


@functions_framework.http
def file_service(request):

    country = request.headers.get("X-country")

    if country in FORBIDDEN:
        message = f"Forbidden export attempt from {country}"

        logging.warning({
            "event": "forbidden_country",
            "country": country,
            "path": request.path
        })
        print(message)

        try:
            requests.post(SECOND_SERVICE_URL, json={"message": message})
        except Exception as e:
            logging.error(f"Failed to notify local service: {e}")

        return ("Permission denied", 400)

    if request.method != "GET":
        logging.warning({
            "event": "method_not_implemented",
            "method": request.method
        })
        print(f"{request.method} not implemented")
        return (f"{request.method} not implemented", 501)

    path = request.path.lstrip("/")

    if path.startswith(f"{BUCKET_NAME}/"):
        path = path[len(BUCKET_NAME) + 1:]
    blob = storage_client.bucket(BUCKET_NAME).blob(path)

    if not blob.exists():
        logging.error(f"File not found: {path}")
        return ("File not found", 404)

    return (blob.download_as_text(), 200)