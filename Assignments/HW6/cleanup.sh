#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="superb-memory-485622-u3"

ZONE="${ZONE:-us-central1-a}"
REGION="${REGION:-us-central1}"

WEB_VM_NAME="${WEB_VM_NAME:-webserver}"
FORB_VM_NAME="${FORB_VM_NAME:-forbidden}"
CLIENT_VM_NAME="${CLIENT_VM_NAME:-client}"
ML_VM_NAME="${ML_VM_NAME:-ml-vm}"

STATIC_IP_NAME="${STATIC_IP_NAME:-webserver-ip}"
FIREWALL_TAG_WEB="${FIREWALL_TAG_WEB:-webserver}"
FIREWALL_TAG_FORB="${FIREWALL_TAG_FORB:-forbidden-service}"

SCRIPT_BUCKET="${SCRIPT_BUCKET:-hche-cs528-hw5-scripts}"

WEB_SA_NAME="${WEB_SA_NAME:-web-server-sa}"
FORB_SA_NAME="${FORB_SA_NAME:-forbidden-sa}"
CLIENT_SA_NAME="${CLIENT_SA_NAME:-client-sa}"

PUBSUB_TOPIC="${PUBSUB_TOPIC:-hw5-forbidden-exports}"
PUBSUB_SUB="${PUBSUB_SUB:-hw5-forbidden-exports-sub}"

CLOUDSQL_INSTANCE="${CLOUDSQL_INSTANCE:-hw5-mysql}"

WEB_SA_EMAIL="${WEB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
FORB_SA_EMAIL="${FORB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
CLIENT_SA_EMAIL="${CLIENT_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config set project "${PROJECT_ID}"

gcloud compute instances delete "${WEB_VM_NAME}" "${FORB_VM_NAME}" "${CLIENT_VM_NAME}" "${ML_VM_NAME}" \
  --zone="${ZONE}" --quiet || true

gcloud compute firewall-rules delete "${FIREWALL_TAG_WEB}" "${FIREWALL_TAG_FORB}" \
  --quiet || true

gcloud compute addresses delete "${STATIC_IP_NAME}" \
  --region="${REGION}" --quiet || true

gcloud pubsub subscriptions delete "${PUBSUB_SUB}" --quiet || true
gcloud pubsub topics delete "${PUBSUB_TOPIC}" --quiet || true

gcloud sql instances patch "${CLOUDSQL_INSTANCE}" \
  --activation-policy=NEVER \
  --quiet || true

gcloud iam service-accounts delete "${WEB_SA_EMAIL}" --quiet || true
gcloud iam service-accounts delete "${FORB_SA_EMAIL}" --quiet || true
gcloud iam service-accounts delete "${CLIENT_SA_EMAIL}" --quiet || true

gcloud scheduler jobs delete monitor-database-job \
  --location=us-central1 --quiet || true

gcloud functions delete monitor-database \
  --region=us-central1 --quiet || true

gcloud storage rm -r "gs://${SCRIPT_BUCKET}/**" --quiet || true
gcloud storage buckets delete "gs://${SCRIPT_BUCKET}" --quiet || true

gcloud auth application-default revoke --quiet || true

echo "Cleanup complete."