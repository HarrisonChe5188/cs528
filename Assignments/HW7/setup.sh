#!/bin/bash
set -e

PROJECT_ID="superb-memory-485622-u3"
REGION="us-central1"
DF_BUCKET="${PROJECT_ID}-hw7-dataflow"

echo "============================="
echo "Project:         $PROJECT_ID"
echo "Region:          $REGION"
echo "Dataflow bucket: gs://$DF_BUCKET"
echo "============================="

# Clear any stale/placeholder GOOGLE_APPLICATION_CREDENTIALS so auth falls
# back to gcloud application-default credentials instead of crashing.
if [ -n "$GOOGLE_APPLICATION_CREDENTIALS" ] && [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    echo "WARNING: GOOGLE_APPLICATION_CREDENTIALS points to a missing file ($GOOGLE_APPLICATION_CREDENTIALS). Unsetting it."
    unset GOOGLE_APPLICATION_CREDENTIALS
fi

gcloud config set project $PROJECT_ID

echo "[1/5] Enabling APIs..."
gcloud services enable dataflow.googleapis.com compute.googleapis.com storage.googleapis.com

echo "[2/5] Creating Dataflow bucket..."
gcloud storage buckets create gs://$DF_BUCKET --location=$REGION 2>/dev/null || echo "  Bucket already exists, skipping."

echo "[3/5] Creating temp / staging / output prefixes..."
echo "" | gcloud storage cp - gs://$DF_BUCKET/temp/.keep    2>/dev/null || true
echo "" | gcloud storage cp - gs://$DF_BUCKET/staging/.keep 2>/dev/null || true
echo "" | gcloud storage cp - gs://$DF_BUCKET/output/.keep  2>/dev/null || true

echo "[4/5] Installing Python dependencies..."
pip install apache-beam[gcp] --quiet

# echo "[5/5] Setting up application-default credentials..."
# gcloud auth application-default login
# comment this out as grader wouldnt be able to run it
# grader should already be added as project owner

echo ""
echo "Setup complete. Run the pipeline with:"
echo "  python pipeline.py --runner=DirectRunner"
echo "  python pipeline.py --runner=DataflowRunner"