#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
: "${PROJECT_ID:?Project must be set via gcloud config set project}"

ZONE1="us-south1-b"
ZONE2="us-south1-c"
ZONE="${ZONE:-us-south1-a}"
REGION="${REGION:-us-south1}"

WEB_VM_NAME_1="webserver-1"
WEB_VM_NAME_2="webserver-2"
FORB_VM_NAME="forbidden"
CLIENT_VM_NAME="client"

STATIC_IP_NAME="webserver-ip"

FIREWALL_WEB_RULE="allow-web-8080"
FIREWALL_FORB_RULE="allow-forb-5000"
FIREWALL_LB_RULE="allow-lb"

BUCKET="hche-cs528-hw4"

WEB_SA_NAME="web-server-sa"
FORB_SA_NAME="forbidden-sa"

WEB_SA_EMAIL="${WEB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
FORB_SA_EMAIL="${FORB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Using project: $PROJECT_ID"

echo "Deleting load balancer resources..."
gcloud compute forwarding-rules delete www-rule --region=$REGION --quiet || true
gcloud compute target-pools delete www-pool --region=$REGION --quiet || true
gcloud compute http-health-checks delete basic-check --quiet || true

echo "Removing firewall rules..."
gcloud compute firewall-rules delete allow-web-8080 --quiet || true
gcloud compute firewall-rules delete allow-forb-5000 --quiet || true
gcloud compute firewall-rules delete allow-lb-8080 --quiet || true
# -------------------------------------------------
# Delete Compute Instances
# -------------------------------------------------
echo "Deleting compute instances..."

gcloud compute instances delete "$WEB_VM_NAME_1" --zone "$ZONE1" --quiet || true
gcloud compute instances delete "$WEB_VM_NAME_2" --zone "$ZONE2" --quiet || true
gcloud compute instances delete "$FORB_VM_NAME" --zone "$ZONE" --quiet || true
gcloud compute instances delete "$CLIENT_VM_NAME" --zone "$ZONE" --quiet || true



# -------------------------------------------------
# Release Static IP
# -------------------------------------------------
echo "Releasing static IP..."

gcloud compute addresses delete \
  "$STATIC_IP_NAME" \
  --region "$REGION" \
  --quiet || true

# -------------------------------------------------
# Delete Pub/Sub
# -------------------------------------------------
echo "Deleting Pub/Sub..."

gcloud pubsub subscriptions delete hw4-forbidden-exports-sub --quiet || true
gcloud pubsub topics delete hw4-forbidden-exports --quiet || true

# -------------------------------------------------
# Delete Service Accounts
# -------------------------------------------------
echo "Deleting service accounts..."

gcloud iam service-accounts delete "$WEB_SA_EMAIL" --quiet || true
gcloud iam service-accounts delete "$FORB_SA_EMAIL" --quiet || true

# -------------------------------------------------
# Delete Storage Bucket
# -------------------------------------------------
echo "Deleting bucket..."

if gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
  gcloud storage rm --recursive "gs://$BUCKET/**" --quiet || true
  gcloud storage buckets delete "gs://$BUCKET" --quiet || true
else
  echo "Bucket does not exist."
fi

# -------------------------------------------------
# Revoke ADC
# -------------------------------------------------
if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "Revoking application-default credentials..."
  gcloud auth application-default revoke || true
fi

echo "Cleanup complete."