#!/usr/bin/env python3
import json
import logging
import os
import sys
import urllib.request
from google.cloud import pubsub_v1

def _metadata(path):
    try:
        req = urllib.request.Request(
            f"http://metadata.google.internal/computeMetadata/v1/{path}",
            headers={"Metadata-Flavor": "Google"}
        )
        return urllib.request.urlopen(req, timeout=3).read().decode()
    except Exception:
        return None

PROJECT = os.environ.get("GCP_PROJECT") or _metadata("project/project-id") or "superb-memory-485622-u3"
SUBSCRIPTION_NAME = "hw5-forbidden-exports-sub"
SUBSCRIPTION_PATH = f"projects/{PROJECT}/subscriptions/{SUBSCRIPTION_NAME}"

# Simple stdout logger — no cloud logging hijacking
logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s"
)
logger = logging.getLogger("forbidden-service")

def callback(message: pubsub_v1.subscriber.message.Message) -> None:
    try:
        payload = json.loads(message.data.decode("utf-8"))
    except Exception:
        payload = {"raw": message.data.decode("utf-8")}
    text = f"RECEIVED FORBIDDEN ALERT: {payload}"
    # flush=True ensures it appears immediately in journalctl / log file
    print(text, flush=True)
    logger.critical(text)
    message.ack()

def run():
    subscriber = pubsub_v1.SubscriberClient()
    streaming_pull_future = subscriber.subscribe(SUBSCRIPTION_PATH, callback=callback)
    print(f"Listening for messages on {SUBSCRIPTION_PATH} ...", flush=True)
    try:
        streaming_pull_future.result()  # blocks forever
    except Exception as e:
        print(f"Subscriber error: {e}", flush=True)
        try:
            streaming_pull_future.cancel()
        except Exception:
            pass

if __name__ == "__main__":
    run()