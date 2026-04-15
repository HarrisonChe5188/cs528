#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null || echo "")"
: "${PROJECT_ID:?Project must be set via 'gcloud config set project' or edit this script.}"
ZONE1="us-south1-b"
ZONE2="us-south1-c"
ZONE="${ZONE:-us-south1-a}"
REGION="${REGION:-us-south1}"
WEB_VM_NAME_1="webserver-1"
WEB_VM_NAME_2="webserver-2"
FORB_VM_NAME="${FORB_VM_NAME:-forbidden}"
CLIENT_VM_NAME="${CLIENT_VM_NAME:-client}"
IMAGE_FAMILY="ubuntu-2404-lts-amd64"
IMAGE_PROJECT="ubuntu-os-cloud"
BUCKET="${BUCKET:-hche-cs528-hw4}"
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

ACTIVE_ACCOUNTS=$(gcloud auth list --format="value(account)" 2>/dev/null || true)
if [ -z "$ACTIVE_ACCOUNTS" ]; then
  echo "ERROR: no active gcloud account. please run 'gcloud auth login' first."
  exit 1
fi

echo "Using project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID"

# Enable required APIs 
gcloud services enable storage.googleapis.com pubsub.googleapis.com compute.googleapis.com iam.googleapis.com --quiet || true

# Create scripts bucket if it doesn't exist
if ! gcloud storage buckets list --filter="name:$BUCKET" --format="value(name)" | grep -q . ; then
  echo "Creating bucket gs://$BUCKET (location $BUCKET_LOCATION)"
  gcloud storage buckets create "gs://$BUCKET" \
    --project="$PROJECT_ID" \
    --location="$BUCKET_LOCATION" \
    --quiet
else
  echo "Bucket gs://$BUCKET already exists — reusing."
fi

# Always upload latest service files
echo "Uploading service files to gs://$BUCKET ..."
gcloud storage cp --quiet ./service1.py "gs://$BUCKET/service1.py" || true
gcloud storage cp --quiet ./service2.py "gs://$BUCKET/service2.py" || true
gcloud storage cp --quiet ./startup.sh  "gs://$BUCKET/startup.sh" || true
gcloud storage cp --quiet ./client.py   "gs://$BUCKET/client.py"   || true  
if [ -f ./http-client ]; then
  gcloud storage cp --quiet ./http-client "gs://$BUCKET/http-client" || true
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

# Grant roles to web server SA
echo "Granting roles to $WEB_SA_EMAIL"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WEB_SA_EMAIL}" --role="roles/storage.objectViewer" || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WEB_SA_EMAIL}" --role="roles/logging.logWriter" || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WEB_SA_EMAIL}" --role="roles/pubsub.publisher" || true

# Grant roles to forbidden SA
echo "Granting roles to $FORB_SA_EMAIL"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${FORB_SA_EMAIL}" --role="roles/logging.logWriter" || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${FORB_SA_EMAIL}" --role="roles/pubsub.subscriber" || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${FORB_SA_EMAIL}" --role="roles/storage.objectViewer" || true

# Reserve static IP
if ! gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" >/dev/null 2>&1; then
  gcloud compute addresses create "$STATIC_IP_NAME" --region="$REGION"
  echo "Reserved static IP: $STATIC_IP_NAME"
else
  echo "Static IP $STATIC_IP_NAME already reserved"
fi

STATIC_IP=$(gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" --format="get(address)")
echo "Web server static IP: $STATIC_IP"

# Create firewall rules
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

# Create Pub/Sub topic and subscription
if ! gcloud pubsub topics describe hw4-forbidden-exports >/dev/null 2>&1; then
  gcloud pubsub topics create hw4-forbidden-exports
  echo "Created topic hw4-forbidden-exports"
else
  echo "Topic hw4-forbidden-exports already exists"
fi

if ! gcloud pubsub subscriptions describe hw4-forbidden-exports-sub >/dev/null 2>&1; then
  gcloud pubsub subscriptions create hw4-forbidden-exports-sub --topic=hw4-forbidden-exports
  echo "Created subscription hw4-forbidden-exports-sub"
else
  echo "Subscription hw4-forbidden-exports-sub already exists"
fi

# Create webserver VM 1
if ! gcloud compute instances describe "$WEB_VM_NAME_1" --zone "$ZONE1" >/dev/null 2>&1; then
  gcloud compute instances create "$WEB_VM_NAME_1" \
    --zone="$ZONE1" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --tags="$FIREWALL_TAG_WEB" \
    --service-account="$WEB_SA_EMAIL" \
    --metadata-from-file=startup-script=./startup.sh \
    --metadata=instance-role=webserver,BUCKET="$DATA_BUCKET",SCRIPTS_BUCKET="$BUCKET",FOLDER="20000",PORT="$WEB_PORT"
  echo "Created webserver VM: $WEB_VM_NAME_1"
else
  echo "Instance $WEB_VM_NAME_1 already exists"
fi
# Create webserver VM 2
if ! gcloud compute instances describe "$WEB_VM_NAME_2" --zone "$ZONE2" >/dev/null 2>&1; then
  gcloud compute instances create "$WEB_VM_NAME_2" \
    --zone="$ZONE2" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --tags="$FIREWALL_TAG_WEB" \
    --service-account="$WEB_SA_EMAIL" \
    --metadata-from-file=startup-script=./startup.sh \
    --metadata=instance-role=webserver,BUCKET="$DATA_BUCKET",SCRIPTS_BUCKET="$BUCKET",FOLDER="20000",PORT="$WEB_PORT"
  echo "Created webserver VM: $WEB_VM_NAME_2"
else
  echo "Instance $WEB_VM_NAME_2 already exists"
fi

# Create forbidden VM
if ! gcloud compute instances describe "$FORB_VM_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  gcloud compute instances create "$FORB_VM_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --tags="$FIREWALL_TAG_FORB" \
    --service-account="$FORB_SA_EMAIL" \
    --metadata-from-file=startup-script=./startup.sh \
    --metadata=instance-role=forbidden,BUCKET="$BUCKET",SCRIPTS_BUCKET="$BUCKET",PORT="$FORB_PORT"
  echo "Created forbidden VM: $FORB_VM_NAME"
else
  echo "Instance $FORB_VM_NAME already exists"
fi

# Create client VM (IMPORTANT: attach a service account so it can access GCS)
if ! gcloud compute instances describe "$CLIENT_VM_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  # Reuse web service account for the client VM so it has storage access
  gcloud compute instances create "$CLIENT_VM_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --service-account="$WEB_SA_EMAIL" \
    --metadata-from-file=startup-script=./startup.sh \
    --metadata=instance-role=client,BUCKET="$BUCKET",SCRIPTS_BUCKET="$BUCKET"
  echo "Created client VM: $CLIENT_VM_NAME (attached service account $WEB_SA_EMAIL)"
else
  echo "Instance $CLIENT_VM_NAME already exists"
fi

# Health check
if ! gcloud compute http-health-checks describe basic-check >/dev/null 2>&1; then
  gcloud compute http-health-checks create basic-check \
    --port=8080 \
    --request-path=/health \
    --check-interval=5 \
    --timeout=5 \
    --healthy-threshold=2 \
    --unhealthy-threshold=2
  echo "Created health check basic-check"
else
  echo "Health check basic-check exists"
fi

# Target pool
if ! gcloud compute target-pools describe www-pool --region=$REGION >/dev/null 2>&1; then
  gcloud compute target-pools create www-pool \
    --region=$REGION \
    --http-health-check=basic-check
  echo "Created target pool www-pool"
else
  echo "Target pool www-pool exists"
fi

# Add instances to pool (idempotent — add-instances is safe to re-run, it errors but || true handles it)
gcloud compute target-pools add-instances www-pool \
  --instances=$WEB_VM_NAME_1 \
  --instances-zone=$ZONE1 || true

gcloud compute target-pools add-instances www-pool \
  --instances=$WEB_VM_NAME_2 \
  --instances-zone=$ZONE2 || true

# Forwarding rule (port 8080 → webservers listening on 8080)
if ! gcloud compute forwarding-rules describe www-rule --region=$REGION >/dev/null 2>&1; then
  gcloud compute forwarding-rules create www-rule \
    --region=$REGION \
    --ports=8080 \
    --address=$STATIC_IP_NAME \
    --target-pool=www-pool
  echo "Created forwarding rule www-rule"
else
  echo "Forwarding rule www-rule exists"
fi

# Firewall: allow 8080 from anywhere to webservers
if ! gcloud compute firewall-rules list --filter="name=allow-lb-8080" --format="value(name)" | grep -q . ; then
  gcloud compute firewall-rules create allow-lb-8080 \
    --allow tcp:8080 \
    --target-tags=$FIREWALL_TAG_WEB
  echo "Created firewall rule allow-lb-8080"
else
  echo "Firewall rule allow-lb-8080 exists"
fi

LB_IP=$(gcloud compute forwarding-rules describe www-rule --region=$REGION --format="get(IPAddress)")
echo "Setup complete."
echo "Load balancer at: http://${LB_IP}:8080"
echo "Wait ~5 minutes for startup scripts to finish before testing."