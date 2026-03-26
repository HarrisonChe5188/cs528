#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null || echo "")"
: "${PROJECT_ID:?Set your project first with: gcloud config set project YOUR_PROJECT_ID}"

ZONE="${ZONE:-us-central1-a}"
REGION="${REGION:-us-central1}"

WEB_VM_NAME="${WEB_VM_NAME:-webserver}"
FORB_VM_NAME="${FORB_VM_NAME:-forbidden}"
CLIENT_VM_NAME="${CLIENT_VM_NAME:-client}"
CLOUDSQL_INSTANCE="${CLOUDSQL_INSTANCE:-hw5-mysql}"

gcloud compute instances stop "${WEB_VM_NAME}" "${FORB_VM_NAME}" "${CLIENT_VM_NAME}" \
  --zone="${ZONE}" \
  --quiet || true

gcloud sql instances patch "${CLOUDSQL_INSTANCE}" \
  --activation-policy=NEVER \
  --quiet || true


echo "Stopped VMs, Cloud Functions, and Cloud SQL."