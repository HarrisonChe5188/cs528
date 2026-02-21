import json
from datetime import datetime
from google.cloud import storage, pubsub_v1
from google.oauth2 import service_account

# Configuration
PROJECT = "superb-memory-485622-u3"
BUCKET_NAME = "hche-cs528-hw2"
LOG_DIR = "violations"
LOG_FILE = f"{LOG_DIR}/forbidden_requests_{datetime.utcnow().strftime('%Y%m%d')}.log"
SUBSCRIPTION = "projects/superb-memory-485622-u3/subscriptions/forbidden-exports-sub"

# Path to your service account key file
SERVICE_ACCOUNT_KEY = r"D:\cs528\Assignments\HW3\microservice-sa-key.json"  # Using raw string for Windows path

def create_authenticated_clients():
    """Create GCP clients using service account key file"""
    
    # Load credentials from service account key file
    credentials = service_account.Credentials.from_service_account_file(
        SERVICE_ACCOUNT_KEY,
        scopes=['https://www.googleapis.com/auth/cloud-platform']
    )
    
    # Create clients with the credentials
    storage_client = storage.Client(
        project=PROJECT,
        credentials=credentials
    )
    
    subscriber = pubsub_v1.SubscriberClient(
        credentials=credentials
    )
    
    return storage_client, subscriber

# Initialize clients with service account
storage_client, subscriber = create_authenticated_clients()
bucket = storage_client.bucket(BUCKET_NAME)


def callback(message):
    try:
        data = json.loads(message.data.decode("utf-8"))
    except Exception as e:
        print(f"Invalid message payload: {e}")
        message.ack()
        return

    if data.get("event") != "forbidden_country_request":
        message.ack()
        return

    country = data.get("country", "UNKNOWN")
    file = data.get("file", "")
    ts = data.get("timestamp") or datetime.utcnow().isoformat()

    log_msg = f"[{ts}] Forbidden request from '{country}' for file '{file}'"
    print(log_msg)

    try:
        blob = bucket.blob(LOG_FILE)
        existing = ""
        try:
            existing = blob.download_as_text()
        except Exception:
            existing = ""

        new_content = existing + log_msg + "\n"
        blob.upload_from_string(new_content, content_type="text/plain")
        print(f"Appended to gs://{BUCKET_NAME}/{LOG_FILE}")
        message.ack()
        
    except Exception as e:
        print(f"Failed to write log to bucket: {e}")
        message.nack()  # Requeue for retry


def main():
    print(f"Listening for messages on {SUBSCRIPTION}...")
    print(f"Using service account key: {SERVICE_ACCOUNT_KEY}")
    
    # Verify the key file exists
    import os
    if not os.path.exists(SERVICE_ACCOUNT_KEY):
        print(f"ERROR: Service account key not found at {SERVICE_ACCOUNT_KEY}")
        return
    
    future = subscriber.subscribe(SUBSCRIPTION, callback)
    
    try:
        future.result()
    except KeyboardInterrupt:
        future.cancel()
        print("Stopped subscriber")
    except Exception as e:
        print(f"Error in subscriber: {e}")
        future.cancel()


if __name__ == "__main__":
    main()