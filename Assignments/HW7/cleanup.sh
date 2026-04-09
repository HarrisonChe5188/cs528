#!/bin/bash
set -e

PROJECT_ID="superb-memory-485622-u3"
REGION="us-central1"
DF_BUCKET="${PROJECT_ID}-hw7-dataflow"

gcloud config set project $PROJECT_ID

echo "[1/3] Canceling active Dataflow jobs..."
JOBS=$(gcloud dataflow jobs list --region=$REGION --status=active --format="value(id)" 2>/dev/null)
if [ -z "$JOBS" ]; then
    echo "  No active jobs found."
else
    echo "$JOBS" | while read job; do
        echo "  Canceling job: $job"
        gcloud dataflow jobs cancel $job --region=$REGION || true
    done
fi

echo "[2/3] Deleting Dataflow bucket..."
gcloud storage rm --recursive gs://$DF_BUCKET 2>/dev/null || echo "  Bucket not found, skipping."

echo "[3/3] Revoking application default credentials..."
gcloud auth application-default revoke 2>/dev/null || true

echo ""
echo "Cleanup complete."