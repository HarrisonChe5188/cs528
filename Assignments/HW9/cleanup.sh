#!/usr/bin/env bash
# cleanup.sh  -  HW9: tear down all infrastructure
set -euo pipefail

PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
: "${PROJECT_ID:?Project must be set via gcloud config set project}"

ZONE="${ZONE:-us-central1-a}"
REGION="${REGION:-us-central1}"
FORB_VM_NAME="${FORB_VM_NAME:-forbidden}"
CLIENT_VM_NAME="${CLIENT_VM_NAME:-client}"
FIREWALL_FORB_RULE="allow-forb-5000"
SCRIPTS_BUCKET="${SCRIPTS_BUCKET:-hche-cs528-hw9}"
WEB_SA_NAME="${WEB_SA_NAME:-web-server-sa}"
FORB_SA_NAME="${FORB_SA_NAME:-forbidden-sa}"
WEB_SA_EMAIL="${WEB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
FORB_SA_EMAIL="${FORB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
CLUSTER_NAME="${CLUSTER_NAME:-hw9-cluster}"
REPO_NAME="${REPO_NAME:-hw9-repo}"

echo "Using project: $PROJECT_ID"

# -------------------------------------------------
# Delete Kubernetes resources
# -------------------------------------------------
echo "Deleting Kubernetes resources..."
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --region="$REGION" --quiet 2>/dev/null || true
kubectl delete -f hw9-webserver.yaml --ignore-not-found 2>/dev/null || true

# -------------------------------------------------
# Delete GKE cluster
# -------------------------------------------------
echo "Deleting GKE cluster: $CLUSTER_NAME ..."
gcloud container clusters delete "$CLUSTER_NAME" \
  --region="$REGION" --quiet || true

# -------------------------------------------------
# Delete Artifact Registry repo
# -------------------------------------------------
echo "Deleting Artifact Registry repo: $REPO_NAME ..."
gcloud artifacts repositories delete "$REPO_NAME" \
  --location="$REGION" --quiet || true

# -------------------------------------------------
# Delete Compute Instances (forbidden + client only)
# -------------------------------------------------
echo "Deleting compute instances..."
gcloud compute instances delete \
  --zone "$ZONE" --quiet \
  "$FORB_VM_NAME" "$CLIENT_VM_NAME" || true

# -------------------------------------------------
# Delete Firewall Rule
# -------------------------------------------------
echo "Removing firewall rules..."
gcloud compute firewall-rules delete --quiet "$FIREWALL_FORB_RULE" || true

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
# Delete Scripts Bucket
# -------------------------------------------------
if gcloud storage buckets describe "gs://$SCRIPTS_BUCKET" >/dev/null 2>&1; then
  echo "Emptying bucket gs://$SCRIPTS_BUCKET ..."
  gcloud storage rm --recursive --quiet "gs://$SCRIPTS_BUCKET/**" || true
  echo "Deleting bucket gs://$SCRIPTS_BUCKET ..."
  gcloud storage buckets delete --quiet "gs://$SCRIPTS_BUCKET" || true
else
  echo "Bucket gs://$SCRIPTS_BUCKET does not exist."
fi

# -------------------------------------------------
# Revoke Application Default Credentials
# -------------------------------------------------
if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "Revoking application-default credentials..."
  gcloud auth application-default revoke || true
fi

echo "Cleanup complete. All HW9 infrastructure removed."