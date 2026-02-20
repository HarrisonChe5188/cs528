import functions_framework
from google.cloud import storage

BUCKET_NAME = "hche-cs528-hw2"
LOG_FOLDER = "forbidden_logs/"

storage_client = storage.Client()


@functions_framework.http
def violation_logger(request):

    data = request.get_json()
    message = data.get("message")

    print(message)

    blob = storage_client.bucket(BUCKET_NAME).blob(
        LOG_FOLDER + "forbidden_requests.log"
    )

    existing = ""
    if blob.exists():
        existing = blob.download_as_text()

    blob.upload_from_string(existing + message + "\n")

    return ("Logged", 200)