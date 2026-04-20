#!/usr/bin/env bash
# setup.sh  -  HW9: web server on GKE, forbidden service + client on VMs
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null || echo "")"
: "${PROJECT_ID:?Project must be set via 'gcloud config set project' or edit this script.}"
ZONE="${ZONE:-us-central1-a}"
REGION="${REGION:-us-central1}"
FORB_VM_NAME="${FORB_VM_NAME:-forbidden}"
CLIENT_VM_NAME="${CLIENT_VM_NAME:-client}"
IMAGE_FAMILY="ubuntu-2404-lts-amd64"
IMAGE_PROJECT="ubuntu-os-cloud"
SCRIPTS_BUCKET="${SCRIPTS_BUCKET:-hche-cs528-hw9}"
DATA_BUCKET="${DATA_BUCKET:-hche-cs528-hw2}"
BUCKET_LOCATION="${BUCKET_LOCATION:-US}"
WEB_SA_NAME="${WEB_SA_NAME:-web-server-sa}"
FORB_SA_NAME="${FORB_SA_NAME:-forbidden-sa}"
FIREWALL_TAG_FORB="forbidden-service"
FORB_PORT="5000"
MACHINE_TYPE="${MACHINE_TYPE:-e2-micro}"
CLUSTER_NAME="${CLUSTER_NAME:-hw9-cluster}"
REPO_NAME="${REPO_NAME:-hw9-repo}"
IMAGE_NAME="webserver"
IMAGE_TAG="latest"
FULL_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:${IMAGE_TAG}"
KSA_NAME="web-server-ksa"
NAMESPACE="default"

ACTIVE_ACCOUNTS=$(gcloud auth list --format="value(account)" 2>/dev/null || true)
if [ -z "$ACTIVE_ACCOUNTS" ]; then
  echo "ERROR: no active gcloud account. run 'gcloud auth login' first."
  exit 1
fi

echo "Using project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID"

# -----------------------------------------------------------------------
# 1. Enable required APIs
# -----------------------------------------------------------------------
echo "[1] Enabling APIs..."
gcloud services enable \
  storage.googleapis.com \
  pubsub.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  logging.googleapis.com \
  --quiet || true

# -----------------------------------------------------------------------
# 2. Create scripts bucket and upload service files
# -----------------------------------------------------------------------
if ! gcloud storage buckets list --filter="name:$SCRIPTS_BUCKET" --format="value(name)" | grep -q . ; then
  echo "Creating bucket gs://$SCRIPTS_BUCKET"
  gcloud storage buckets create "gs://$SCRIPTS_BUCKET" \
    --project="$PROJECT_ID" --location="$BUCKET_LOCATION" --quiet
else
  echo "Bucket gs://$SCRIPTS_BUCKET already exists."
fi

echo "Uploading service files..."
gcloud storage cp --quiet ./service2.py "gs://$SCRIPTS_BUCKET/service2.py" || true
gcloud storage cp --quiet ./startup.sh  "gs://$SCRIPTS_BUCKET/startup.sh"  || true
if [ -f ./http-client ]; then
  gcloud storage cp --quiet ./http-client "gs://$SCRIPTS_BUCKET/http-client" || true
fi

# -----------------------------------------------------------------------
# 3. Create service accounts
# -----------------------------------------------------------------------
WEB_SA_EMAIL="${WEB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
FORB_SA_EMAIL="${FORB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if ! gcloud iam service-accounts list --filter="email:$WEB_SA_EMAIL" --format="value(email)" | grep -q . ; then
  gcloud iam service-accounts create "$WEB_SA_NAME" --display-name="Web Server SA"
  echo "Created $WEB_SA_EMAIL"
else
  echo "SA $WEB_SA_EMAIL exists"
fi

if ! gcloud iam service-accounts list --filter="email:$FORB_SA_EMAIL" --format="value(email)" | grep -q . ; then
  gcloud iam service-accounts create "$FORB_SA_NAME" --display-name="Forbidden Service SA"
  echo "Created $FORB_SA_EMAIL"
else
  echo "SA $FORB_SA_EMAIL exists"
fi

# -----------------------------------------------------------------------
# 4. Grant IAM roles
# -----------------------------------------------------------------------
echo "Granting roles to $WEB_SA_EMAIL..."
for ROLE in roles/storage.objectViewer roles/logging.logWriter roles/pubsub.publisher; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${WEB_SA_EMAIL}" --role="$ROLE" --quiet || true
done

echo "Granting roles to $FORB_SA_EMAIL..."
for ROLE in roles/logging.logWriter roles/pubsub.subscriber roles/storage.objectViewer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${FORB_SA_EMAIL}" --role="$ROLE" --quiet || true
done

# -----------------------------------------------------------------------
# 5. Firewall rule for forbidden VM
# -----------------------------------------------------------------------
if ! gcloud compute firewall-rules list --filter="name=allow-forb-5000" --format="value(name)" | grep -q . ; then
  gcloud compute firewall-rules create allow-forb-5000 \
    --allow tcp:$FORB_PORT --target-tags="$FIREWALL_TAG_FORB" \
    --description="Allow forbidden-service port $FORB_PORT"
  echo "Created firewall rule allow-forb-5000"
else
  echo "Firewall rule allow-forb-5000 exists"
fi

# -----------------------------------------------------------------------
# 6. Pub/Sub topic and subscription
# -----------------------------------------------------------------------
if ! gcloud pubsub topics describe hw4-forbidden-exports >/dev/null 2>&1; then
  gcloud pubsub topics create hw4-forbidden-exports
  echo "Created topic hw4-forbidden-exports"
else
  echo "Topic hw4-forbidden-exports exists"
fi

if ! gcloud pubsub subscriptions describe hw4-forbidden-exports-sub >/dev/null 2>&1; then
  gcloud pubsub subscriptions create hw4-forbidden-exports-sub --topic=hw4-forbidden-exports
  echo "Created subscription hw4-forbidden-exports-sub"
else
  echo "Subscription hw4-forbidden-exports-sub exists"
fi

# -----------------------------------------------------------------------
# 7. Forbidden VM
# -----------------------------------------------------------------------
if ! gcloud compute instances describe "$FORB_VM_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  gcloud compute instances create "$FORB_VM_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --tags="$FIREWALL_TAG_FORB" \
    --service-account="$FORB_SA_EMAIL" \
    --metadata-from-file=startup-script=./startup.sh \
    --metadata=instance-role=forbidden,BUCKET="$SCRIPTS_BUCKET",SCRIPTS_BUCKET="$SCRIPTS_BUCKET",PORT="$FORB_PORT"
  echo "Created forbidden VM: $FORB_VM_NAME"
else
  echo "Instance $FORB_VM_NAME already exists"
fi

# -----------------------------------------------------------------------
# 8. Client VM
# -----------------------------------------------------------------------
if ! gcloud compute instances describe "$CLIENT_VM_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  gcloud compute instances create "$CLIENT_VM_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --service-account="$WEB_SA_EMAIL" \
    --metadata-from-file=startup-script=./startup.sh \
    --metadata=instance-role=client,BUCKET="$SCRIPTS_BUCKET",SCRIPTS_BUCKET="$SCRIPTS_BUCKET"
  echo "Created client VM: $CLIENT_VM_NAME"
else
  echo "Instance $CLIENT_VM_NAME already exists"
fi

# -----------------------------------------------------------------------
# 9. Artifact Registry repo
# -----------------------------------------------------------------------
if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" --quiet >/dev/null 2>&1; then
  gcloud artifacts repositories create "$REPO_NAME" \
    --repository-format=docker \
    --location="$REGION" \
    --description="HW9 container images"
  echo "Created Artifact Registry repo: $REPO_NAME"
else
  echo "Artifact Registry repo $REPO_NAME exists"
fi

# -----------------------------------------------------------------------
# 10. Build and push Docker image
# -----------------------------------------------------------------------
echo "Building Docker image: $FULL_IMAGE"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker build -t "$FULL_IMAGE" .
echo "Pushing image..."
docker push "$FULL_IMAGE"

# -----------------------------------------------------------------------
# 11. GKE Autopilot cluster
# -----------------------------------------------------------------------
if ! gcloud container clusters describe "$CLUSTER_NAME" --region="$REGION" --quiet >/dev/null 2>&1; then
  echo "Creating GKE Autopilot cluster: $CLUSTER_NAME ..."
  gcloud container clusters create-auto "$CLUSTER_NAME" \
    --region="$REGION" \
    --quiet
  echo "Created cluster: $CLUSTER_NAME"
else
  echo "Cluster $CLUSTER_NAME exists"
fi

gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION" --quiet

# -----------------------------------------------------------------------
# 12. Workload Identity binding
# -----------------------------------------------------------------------
echo "Binding Workload Identity..."
gcloud iam service-accounts add-iam-policy-binding "$WEB_SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]" \
  --quiet || true

# -----------------------------------------------------------------------
# 13. Deploy to GKE
# -----------------------------------------------------------------------
echo "Deploying web server to GKE..."
sed \
  -e "s|us-central1-docker.pkg.dev/superb-memory-485622-u3/hw9-repo/webserver:latest|${FULL_IMAGE}|g" \
  -e "s|superb-memory-485622-u3|${PROJECT_ID}|g" \
  hw9-webserver.yaml | kubectl apply -f -

kubectl rollout status deployment/webserver --timeout=120s

# -----------------------------------------------------------------------
# 14. Print results
# -----------------------------------------------------------------------
echo ""
echo "Waiting for LoadBalancer IP..."
for i in $(seq 1 20); do
  EXTERNAL_IP=$(kubectl get svc webserver-svc \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "$EXTERNAL_IP" ]; then
    echo "========================================================"
    echo " HW9 setup complete!"
    echo " Web server (GKE):      http://${EXTERNAL_IP}:8080"
    echo " Forbidden VM:          $FORB_VM_NAME (zone: $ZONE)"
    echo " Client VM:             $CLIENT_VM_NAME (zone: $ZONE)"
    echo "========================================================"
    echo ""
    echo "NOTE: Forbidden VM and client VM may take ~10 min to finish startup."
    break
  fi
  echo "  Waiting for IP... ($i/20)"
  sleep 10
done