#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
: "${PROJECT_ID:?Project must be set via gcloud config set project}"

ZONE="${ZONE:-us-central1-a}"
REGION="${REGION:-us-central1}"
WEB_VM_NAME="${WEB_VM_NAME:-webserver}"
FORB_VM_NAME="${FORB_VM_NAME:-forbidden}"
CLIENT_VM_NAME="${CLIENT_VM_NAME:-client}"
STATIC_IP_NAME="${STATIC_IP_NAME:-webserver-ip}"
FIREWALL_WEB_RULE="allow-web-8080"
FIREWALL_FORB_RULE="allow-forb-5000"
BUCKET="${BUCKET:-hche-cs528-hw4}"
WEB_SA_NAME="${WEB_SA_NAME:-web-server-sa}"
FORB_SA_NAME="${FORB_SA_NAME:-forbidden-sa}"
WEB_SA_EMAIL="${WEB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
FORB_SA_EMAIL="${FORB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Using project: $PROJECT_ID"

# -------------------------------------------------
# Delete Compute Instances
# -------------------------------------------------
echo "Deleting compute instances..."
gcloud compute instances delete \
  --zone "$ZONE" \
  --quiet \
  "$WEB_VM_NAME" "$FORB_VM_NAME" "$CLIENT_VM_NAME" || true

# -------------------------------------------------
# Delete Firewall Rules
# -------------------------------------------------
echo "Removing firewall rules..."
gcloud compute firewall-rules delete \
  --quiet \
  "$FIREWALL_WEB_RULE" "$FIREWALL_FORB_RULE" || true

# -------------------------------------------------
# Release Static IP
# -------------------------------------------------
echo "Releasing static IP..."
gcloud compute addresses delete \
  --region "$REGION" \
  --quiet \
  "$STATIC_IP_NAME" || true

# -------------------------------------------------
# Delete Pub/Sub
# -------------------------------------------------
echo "Deleting Pub/Sub subscription and topic..."
gcloud pubsub subscriptions delete hw4-forbidden-exports-sub --quiet || true
gcloud pubsub topics delete hw4-forbidden-exports --quiet || true

# -------------------------------------------------
# Delete Service Accounts
# -------------------------------------------------
echo "Deleting service accounts..."
gcloud iam service-accounts delete --quiet "$WEB_SA_EMAIL" || true
gcloud iam service-accounts delete --quiet "$FORB_SA_EMAIL" || true

# -------------------------------------------------
# Delete Bucket (FULLY)
# -------------------------------------------------
if gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
  echo "Emptying bucket gs://$BUCKET ..."
  gcloud storage rm --recursive --quiet "gs://$BUCKET/**" || true

  echo "Deleting bucket gs://$BUCKET ..."
  gcloud storage buckets delete --quiet "gs://$BUCKET" || true
else
  echo "Bucket gs://$BUCKET does not exist."
fi

# -------------------------------------------------
# Revoke Application Default Credentials
# -------------------------------------------------
if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "Revoking application-default credentials..."
  gcloud auth application-default revoke || true
fi

echo "Cleanup complete. All infrastructure removed."