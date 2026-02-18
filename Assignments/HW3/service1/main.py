import functions_framework
from google.cloud import storage
import logging

BUCKET_NAME = "hche-cs528-hw2"
FOLDER_NAME = "20000"

storage_client = storage.Client(project="superb-memory-485622-u3")

@functions_framework.http
def file_service(request):
    if request.method != "GET":
        logging.error({"error": "Method not implemented", "method": request.method})
        return "Not implemented", 501

    filename = request.args.get("file")

    full_path = f"{FOLDER_NAME}/{filename}"
    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(full_path)

    if not blob.exists():
        logging.error({"error": "File not found", "filename": filename})
        return "File not found", 404

    return blob.download_as_text(), 200
