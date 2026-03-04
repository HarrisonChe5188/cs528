#!/usr/bin/env bash
set -euo pipefail

# ------------ CONFIG (edit only if needed) -------------
# fetch project id (allows running without hard‑coding)
PROJECT_ID="$(gcloud config get-value project 2>/dev/null || echo "")"
: "${PROJECT_ID:?Project must be set via 'gcloud config set project' or edit this script.}"
ZONE="${ZONE:-us-central1-a}"
REGION="${REGION:-us-central1}"
WEB_VM_NAME="${WEB_VM_NAME:-webserver}"
FORB_VM_NAME="${FORB_VM_NAME:-forbidden}"
CLIENT_VM_NAME="${CLIENT_VM_NAME:-client}"
# default image used for all VMs; choose Ubuntu 24.04 which has a modern libc
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2404-lts-amd64}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
BUCKET="${BUCKET:-hche-cs528-hw4}"    # bucket used for storing service scripts and startup file
# the actual bucket containing the 20k objects may be different; set DATA_BUCKET
# to your homework‑2 bucket so the webserver reads from the correct location.
DATA_BUCKET="${DATA_BUCKET:-hche-cs528-hw2}"
BUCKET_LOCATION="${BUCKET_LOCATION:-US}"
WEB_SA_NAME="${WEB_SA_NAME:-web-server-sa}"
FORB_SA_NAME="${FORB_SA_NAME:-forbidden-sa}"
STATIC_IP_NAME="${STATIC_IP_NAME:-webserver-ip}"
FIREWALL_TAG_WEB="webserver"
FIREWALL_TAG_FORB="forbidden-service"
WEB_PORT="8080"
FORB_PORT="5000"
MACHINE_TYPE="${MACHINE_TYPE:-e2-micro}"
# -------------------------------------------------------

# verify that gcloud is authenticated
# some Windows environments lack grep, so avoid external dependency.
ACTIVE_ACCOUNTS=$(gcloud auth list --format="value(account)" 2>/dev/null || true)
if [ -z "$ACTIVE_ACCOUNTS" ]; then
  echo "ERROR: no active gcloud account. please run 'gcloud auth login' before re‑running this script."
  exit 1
fi

echo "Using project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID"

# Create bucket if it doesn't exist (use gcloud storage to avoid gsutil/python errors)
if ! gcloud storage buckets list --filter="name:$BUCKET" --format="value(name)" | grep -q . ; then
  echo "Creating bucket gs://$BUCKET (location $BUCKET_LOCATION)"
  gcloud storage buckets create "gs://$BUCKET" \
    --project="$PROJECT_ID" \
    --location="$BUCKET_LOCATION" \
    --quiet
else
  echo "Bucket gs://$BUCKET already exists — reusing."
fi

# Create service accounts
WEB_SA_EMAIL="${WEB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
FORB_SA_EMAIL="${FORB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts list --filter="email:$WEB_SA_EMAIL" --format="value(email)" | grep -q . ; then
  gcloud iam service-accounts create "$WEB_SA_NAME" --display-name="Web Server SA"
  echo "Created service account $WEB_SA_EMAIL"
else
  echo "Service account $WEB_SA_EMAIL exists"
fi

if ! gcloud iam service-accounts list --filter="email:$FORB_SA_EMAIL" --format="value(email)" | grep -q . ; then
  gcloud iam service-accounts create "$FORB_SA_NAME" --display-name="Forbidden Service SA"
  echo "Created service account $FORB_SA_EMAIL"
else
  echo "Service account $FORB_SA_EMAIL exists"
fi

# Grant least-privilege roles
echo "Granting roles to $WEB_SA_EMAIL"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WEB_SA_EMAIL}" --role="roles/storage.objectViewer" || true

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WEB_SA_EMAIL}" --role="roles/logging.logWriter" || true
# allow web server to publish to pubsub

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WEB_SA_EMAIL}" --role="roles/pubsub.publisher" || true

echo "Granting roles to $FORB_SA_EMAIL"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${FORB_SA_EMAIL}" --role="roles/logging.logWriter" || true
# forbidden service only needs to pull (subscriber role)

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${FORB_SA_EMAIL}" --role="roles/pubsub.subscriber" || true

# Reserve static IP for webserver (region scope)
if ! gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" >/dev/null 2>&1; then
  gcloud compute addresses create "$STATIC_IP_NAME" --region="$REGION"
  echo "Reserved static IP: $STATIC_IP_NAME"
else
  echo "Static IP $STATIC_IP_NAME already reserved"
fi

STATIC_IP=$(gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" --format="get(address)")
echo "Web server static IP: $STATIC_IP"

# Create firewall rules if not present
if ! gcloud compute firewall-rules list --filter="name=allow-web-8080" --format="value(name)" | grep -q . ; then
  gcloud compute firewall-rules create allow-web-8080 \
    --allow tcp:$WEB_PORT --target-tags="$FIREWALL_TAG_WEB" --description="Allow webserver port $WEB_PORT"
  echo "Created firewall rule allow-web-8080"
else
  echo "Firewall rule allow-web-8080 exists"
fi

if ! gcloud compute firewall-rules list --filter="name=allow-forb-5000" --format="value(name)" | grep -q . ; then
  gcloud compute firewall-rules create allow-forb-5000 \
    --allow tcp:$FORB_PORT --target-tags="$FIREWALL_TAG_FORB" --description="Allow forbidden-service port $FORB_PORT"
  echo "Created firewall rule allow-forb-5000"
else
  echo "Firewall rule allow-forb-5000 exists"
fi

# Upload the service code and startup script to the bucket (so startup can pull them)
echo "Uploading service files to gs://$BUCKET ..."
gcloud storage cp --quiet ./service1.py "gs://$BUCKET/service1.py" || true
gcloud storage cp --quiet ./service2.py "gs://$BUCKET/service2.py" || true
gcloud storage cp --quiet ./startup.sh "gs://$BUCKET/startup.sh" || true
# upload http client binary so the client VM can fetch it
if [ -f ./http-client ]; then
  gcloud storage cp --quiet ./http-client "gs://$BUCKET/http-client" || true
fi

# create pubsub topic/subscription for forbidden alerts
if ! gcloud pubsub topics describe forbidden-exports >/dev/null 2>&1; then
  gcloud pubsub topics create forbidden-exports
  echo "Created topic forbidden-exports"
else
  echo "Topic forbidden-exports already exists"
fi

if ! gcloud pubsub subscriptions describe forbidden-exports-sub >/dev/null 2>&1; then
  gcloud pubsub subscriptions create forbidden-exports-sub --topic=forbidden-exports
  echo "Created subscription forbidden-exports-sub"
else
  echo "Subscription forbidden-exports-sub already exists"
fi

# Create the webserver VM
if ! gcloud compute instances describe "$WEB_VM_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  gcloud compute instances create "$WEB_VM_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --address="$STATIC_IP" \
    --tags="$FIREWALL_TAG_WEB" \
    --service-account="$WEB_SA_EMAIL" \
    --metadata-from-file=startup-script=./startup.sh \
    --metadata=instance-role=webserver,BUCKET="$DATA_BUCKET",FOLDER="20000",PORT="$WEB_PORT"
  echo "Created webserver VM: $WEB_VM_NAME"
else
  echo "Instance $WEB_VM_NAME already exists"
fi

# Create the forbidden VM
if ! gcloud compute instances describe "$FORB_VM_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  gcloud compute instances create "$FORB_VM_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --tags="$FIREWALL_TAG_FORB" \
    --service-account="$FORB_SA_EMAIL" \
    --metadata-from-file=startup-script=./startup.sh \
    --metadata=instance-role=forbidden,BUCKET="$BUCKET",PORT="$FORB_PORT"
  echo "Created forbidden VM: $FORB_VM_NAME"
else
  echo "Instance $FORB_VM_NAME already exists"
fi

# (Optional) create a client VM (Linux) for manual tests
# we give it a role=client so startup.sh will download the http-client
if ! gcloud compute instances describe "$CLIENT_VM_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  gcloud compute instances create "$CLIENT_VM_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --metadata-from-file=startup-script=./startup.sh \
    --metadata=instance-role=client,BUCKET="$BUCKET"
  echo "Created client VM: $CLIENT_VM_NAME"
else
  echo "Instance $CLIENT_VM_NAME already exists"
fi

echo "Setup complete."
echo "Webserver should be at: http://${STATIC_IP}:${WEB_PORT}"