import functions_framework
from google.cloud import storage
import logging

BUCKET_NAME = "hche-cs528-hw2"

storage_client = storage.Client(project="superb-memory-485622-u3")

@functions_framework.http
def file_service(request):
    if request.method != "GET":
        return "Not implemented", 501

    path = request.path.lstrip("/")  

    if path.startswith(f"{BUCKET_NAME}/"):
        path = path[len(BUCKET_NAME) + 1:]
    blob = storage_client.bucket(BUCKET_NAME).blob(path)

    if not blob.exists():
        logging.error(f"File not found: {path}")
        return "File not found", 404

    return blob.download_as_text(), 200