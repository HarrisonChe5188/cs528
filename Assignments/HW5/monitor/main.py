import os
from datetime import datetime
from zoneinfo import ZoneInfo

from google.auth import default
from googleapiclient import discovery

PROJECT_ID = os.environ["GCP_PROJECT"]
INSTANCE = os.environ["CLOUDSQL_INSTANCE"]
TIMEZONE = os.environ.get("MONITOR_TIMEZONE", "America/New_York")

ALLOW_START_HOUR = int(os.environ.get("ALLOW_START_HOUR", "12"))
ALLOW_END_HOUR = int(os.environ.get("ALLOW_END_HOUR", "22"))


def monitor_database(request):
    now = datetime.now(ZoneInfo(TIMEZONE))

    creds, _ = default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    service = discovery.build("sqladmin", "v1beta4", credentials=creds, cache_discovery=False)

    try:
        instance = service.instances().get(
            project=PROJECT_ID,
            instance=INSTANCE
        ).execute()
    except Exception as e:
        return (f"Error fetching instance: {e}", 500)

    state = instance.get("state", "UNKNOWN")

    # -------------------------
    # Allowed hours → ensure RUNNING
    # -------------------------
    if ALLOW_START_HOUR <= now.hour < ALLOW_END_HOUR:
        if state != "RUNNABLE":
            body = {"settings": {"activationPolicy": "ALWAYS"}}
            op = service.instances().patch(
                project=PROJECT_ID,
                instance=INSTANCE,
                body=body
            ).execute()
            return (f"Started {INSTANCE}; op={op.get('name')}", 200)

        return (f"Already running at {now.isoformat()}", 200)

    # -------------------------
    # Outside allowed hours → STOP
    # -------------------------
    if state == "RUNNABLE":
        body = {"settings": {"activationPolicy": "NEVER"}}
        op = service.instances().patch(
            project=PROJECT_ID,
            instance=INSTANCE,
            body=body
        ).execute()
        return (f"Stopped {INSTANCE}; op={op.get('name')}", 200)

    return (f"No action; state={state}", 200)