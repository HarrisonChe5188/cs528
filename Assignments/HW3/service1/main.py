import functions_framework
from google.cloud import storage
import logging
import requests

BUCKET_NAME = "hche-cs528-hw2"

storage_client = storage.Client(project="superb-memory-485622-u3")

FORBIDDEN = {"North Korea","Iran","Cuba","Myanmar","Iraq","Libya","Sudan","Zimbabwe","Syria"}

SECOND_SERVICE_URL = "https://us-central1-superb-memory-485622-u3.cloudfunctions.net/foreign-violation-logger"

@functions_framework.http
def file_service(request):

    country = request.headers.get("X-country")

    if country in FORBIDDEN:
        message = f"Forbidden export attempt from {country}"
        
        print(message)
        logging.warning({"event":"forbidden_country","country":country})

        requests.post(SECOND_SERVICE_URL, json={"message": message})

        return ("Permission denied", 400)

    if request.method != "GET":
        print(f"{request.method} not implemented")
        return (f"{request.method} not implemented", 501)

    path = request.path.lstrip("/")

    if path.startswith(f"{BUCKET_NAME}/"):
        path = path[len(BUCKET_NAME) + 1:]
    blob = storage_client.bucket(BUCKET_NAME).blob(path)

    if not blob.exists():
        logging.error(f"File not found: {path}")
        return "File not found", 404

    return blob.download_as_text(), 200