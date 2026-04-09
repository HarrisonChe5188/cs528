#!/usr/bin/env bash


set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration  –  edit these or override via environment variables
# ---------------------------------------------------------------------------
PROJECT_ID="superb-memory-485622-u3"      # ← hardcoded as required by spec

ZONE="${ZONE:-us-central1-f}"
REGION="${REGION:-us-central1}"

WEB_VM_NAME="${WEB_VM_NAME:-webserver}"
FORB_VM_NAME="${FORB_VM_NAME:-forbidden}"
CLIENT_VM_NAME="${CLIENT_VM_NAME:-client}"

IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2404-lts-amd64}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-micro}"

DATA_BUCKET="${DATA_BUCKET:-hche-cs528-hw2}"
SCRIPT_BUCKET="${SCRIPT_BUCKET:-hche-cs528-hw5-scripts}"
BUCKET_LOCATION="${BUCKET_LOCATION:-US}"

WEB_SA_NAME="${WEB_SA_NAME:-web-server-sa}"
FORB_SA_NAME="${FORB_SA_NAME:-forbidden-sa}"
CLIENT_SA_NAME="${CLIENT_SA_NAME:-client-sa}"

STATIC_IP_NAME="${STATIC_IP_NAME:-webserver-ip}"
FIREWALL_TAG_WEB="${FIREWALL_TAG_WEB:-webserver}"
FIREWALL_TAG_FORB="${FIREWALL_TAG_FORB:-forbidden-service}"

WEB_PORT="${WEB_PORT:-8080}"
FORB_PORT="${FORB_PORT:-5000}"

PUBSUB_TOPIC="${PUBSUB_TOPIC:-hw5-forbidden-exports}"
PUBSUB_SUB="${PUBSUB_SUB:-hw5-forbidden-exports-sub}"

CLOUDSQL_INSTANCE="${CLOUDSQL_INSTANCE:-hw5-mysql}"
DB_NAME="${DB_NAME:-hw5db}"
DB_USER="${DB_USER:-hw5user}"
DB_PASSWORD="${DB_PASSWORD:-hw5pass123}"
CLOUD_SQL_CONNECTION_NAME="${PROJECT_ID}:${REGION}:${CLOUDSQL_INSTANCE}"

PROXY_BIN="/tmp/cloud-sql-proxy-setup"
PROXY_PID_FILE="/tmp/cloud-sql-proxy-setup.pid"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[setup] $*"; }

cleanup_proxy() {
  if [ -f "${PROXY_PID_FILE}" ]; then
    local pid
    pid="$(cat "${PROXY_PID_FILE}")"
    log "Stopping local Cloud SQL proxy (pid ${pid})..."
    kill "${pid}" 2>/dev/null || true
    rm -f "${PROXY_PID_FILE}"
  fi
}
trap cleanup_proxy EXIT

start_local_proxy() {
  log "Downloading Cloud SQL Auth Proxy..."
  curl -fsSL \
    "https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.21.2/cloud-sql-proxy.linux.amd64" \
    -o "${PROXY_BIN}"
  chmod +x "${PROXY_BIN}"

  log "Starting local proxy for ${CLOUD_SQL_CONNECTION_NAME} on 127.0.0.1:3306..."
  "${PROXY_BIN}" \
    --address 127.0.0.1 \
    --port 3306 \
    "${CLOUD_SQL_CONNECTION_NAME}" &
  echo $! > "${PROXY_PID_FILE}"

  # Wait until the proxy port is open (up to 30 s)
  for i in $(seq 1 30); do
    if bash -c "echo >/dev/tcp/127.0.0.1/3306" 2>/dev/null; then
      log "Proxy is ready."
      return 0
    fi
    sleep 1
  done
  log "ERROR: proxy did not become ready in 30 s."
  exit 1
}

run_setup_schema() {
  log "Installing mysql-connector-python locally (if needed)..."
  pip3 install --quiet mysql-connector-python

  log "Running setup_schema.py..."
  DB_HOST=127.0.0.1 \
  DB_PORT=3306 \
  DB_NAME="${DB_NAME}" \
  DB_USER="${DB_USER}" \
  DB_PASSWORD="${DB_PASSWORD}" \
  python3 ./setup_schema.py
}

# ---------------------------------------------------------------------------
# Cloud SQL: create or start
# ---------------------------------------------------------------------------
handle_cloud_sql() {
  if gcloud sql instances describe "${CLOUDSQL_INSTANCE}" \
       --project="${PROJECT_ID}" >/dev/null 2>&1; then
    log "Cloud SQL instance '${CLOUDSQL_INSTANCE}' already exists – starting it..."
    gcloud sql instances patch "${CLOUDSQL_INSTANCE}" \
      --activation-policy=ALWAYS \
      --project="${PROJECT_ID}" \
      --quiet
    log "Skipping schema creation (instance already exists)."
  else
    log "Creating Cloud SQL instance '${CLOUDSQL_INSTANCE}'..."
    gcloud sql instances create "${CLOUDSQL_INSTANCE}" \
      --region="${REGION}" \
      --database-version=MYSQL_8_0 \
      --cpu=4 \
      --memory=16GB \
      --storage-size=100GB \
      --project="${PROJECT_ID}" \
      --quiet

    gcloud sql databases create "${DB_NAME}" \
      --instance="${CLOUDSQL_INSTANCE}" \
      --project="${PROJECT_ID}" \
      --quiet || true

    if gcloud sql users list \
         --instance="${CLOUDSQL_INSTANCE}" \
         --project="${PROJECT_ID}" \
         --format="value(name)" | grep -qx "${DB_USER}"; then
      gcloud sql users set-password "${DB_USER}" \
        --instance="${CLOUDSQL_INSTANCE}" \
        --password="${DB_PASSWORD}" \
        --project="${PROJECT_ID}" \
        --quiet
    else
      gcloud sql users create "${DB_USER}" \
        --instance="${CLOUDSQL_INSTANCE}" \
        --password="${DB_PASSWORD}" \
        --project="${PROJECT_ID}" \
        --quiet
    fi

    # Run schema setup via local proxy
    start_local_proxy
    run_setup_schema
    cleanup_proxy
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "Project: ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null

log "Enabling required APIs..."
gcloud services enable \
  compute.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com \
  pubsub.googleapis.com \
  sqladmin.googleapis.com \
  cloudfunctions.googleapis.com \
  cloudscheduler.googleapis.com \
  --project="${PROJECT_ID}" \
  --quiet

# ---- Buckets ---------------------------------------------------------------
if ! gcloud storage buckets describe "gs://${DATA_BUCKET}" \
       --project="${PROJECT_ID}" >/dev/null 2>&1; then
  log "ERROR: data bucket gs://${DATA_BUCKET} does not exist."
  exit 1
fi

if ! gcloud storage buckets describe "gs://${SCRIPT_BUCKET}" \
       --project="${PROJECT_ID}" >/dev/null 2>&1; then
  log "Creating script bucket gs://${SCRIPT_BUCKET}..."
  gcloud storage buckets create "gs://${SCRIPT_BUCKET}" \
    --location="${BUCKET_LOCATION}" \
    --project="${PROJECT_ID}" \
    --quiet
fi

log "Uploading scripts to gs://${SCRIPT_BUCKET}..."
gcloud storage cp --quiet ./service1.py       "gs://${SCRIPT_BUCKET}/service1.py"
gcloud storage cp --quiet ./service2.py       "gs://${SCRIPT_BUCKET}/service2.py"
gcloud storage cp --quiet ./startup.sh        "gs://${SCRIPT_BUCKET}/startup.sh"
gcloud storage cp --quiet ./setup_schema.py   "gs://${SCRIPT_BUCKET}/setup_schema.py"
gcloud storage cp --quiet ./http-client "gs://${SCRIPT_BUCKET}/http-client"

# ---- Service accounts ------------------------------------------------------
WEB_SA_EMAIL="${WEB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
FORB_SA_EMAIL="${FORB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
CLIENT_SA_EMAIL="${CLIENT_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

for sa_name in "${WEB_SA_NAME}" "${FORB_SA_NAME}" "${CLIENT_SA_NAME}"; do
  sa_email="${sa_name}@${PROJECT_ID}.iam.gserviceaccount.com"
  if ! gcloud iam service-accounts list \
       --filter="email:${sa_email}" \
       --project="${PROJECT_ID}" \
       --format="value(email)" | grep -q .; then
    gcloud iam service-accounts create "${sa_name}" \
      --display-name="${sa_name}" \
      --project="${PROJECT_ID}" \
      --quiet
    log "Created service account ${sa_email}."
  else
    log "Service account ${sa_email} already exists."
  fi
done

# Web SA roles
for role in roles/storage.objectViewer roles/logging.logWriter \
            roles/pubsub.publisher roles/cloudsql.client; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${WEB_SA_EMAIL}" \
    --role="${role}" --quiet || true
done

# Forbidden SA roles
for role in roles/storage.objectAdmin roles/logging.logWriter \
            roles/pubsub.subscriber; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${FORB_SA_EMAIL}" \
    --role="${role}" --quiet || true
done

# Client SA roles
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${CLIENT_SA_EMAIL}" \
  --role="roles/storage.objectViewer" --quiet || true

# ---- Static IP -------------------------------------------------------------
if ! gcloud compute addresses describe "${STATIC_IP_NAME}" \
       --region="${REGION}" \
       --project="${PROJECT_ID}" >/dev/null 2>&1; then
  log "Reserving static IP '${STATIC_IP_NAME}'..."
  gcloud compute addresses create "${STATIC_IP_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet
fi

# ---- Firewall rules --------------------------------------------------------
if ! gcloud compute firewall-rules list \
       --filter="name=${FIREWALL_TAG_WEB}" \
       --project="${PROJECT_ID}" \
       --format="value(name)" | grep -q .; then
  gcloud compute firewall-rules create "${FIREWALL_TAG_WEB}" \
    --allow="tcp:${WEB_PORT}" \
    --target-tags="${FIREWALL_TAG_WEB}" \
    --project="${PROJECT_ID}" \
    --quiet
fi

if ! gcloud compute firewall-rules list \
       --filter="name=${FIREWALL_TAG_FORB}" \
       --project="${PROJECT_ID}" \
       --format="value(name)" | grep -q .; then
  gcloud compute firewall-rules create "${FIREWALL_TAG_FORB}" \
    --allow="tcp:${FORB_PORT}" \
    --target-tags="${FIREWALL_TAG_FORB}" \
    --project="${PROJECT_ID}" \
    --quiet
fi

# ---- Pub/Sub ---------------------------------------------------------------
if ! gcloud pubsub topics describe "${PUBSUB_TOPIC}" \
       --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud pubsub topics create "${PUBSUB_TOPIC}" \
    --project="${PROJECT_ID}" --quiet
fi
if ! gcloud pubsub subscriptions describe "${PUBSUB_SUB}" \
       --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud pubsub subscriptions create "${PUBSUB_SUB}" \
    --topic="${PUBSUB_TOPIC}" \
    --project="${PROJECT_ID}" --quiet
fi

# ---- Cloud SQL (create or start) + schema ----------------------------------
handle_cloud_sql

# ---- Resolve static IP (after handle_cloud_sql in case it took a while) ---
STATIC_IP="$(gcloud compute addresses describe "${STATIC_IP_NAME}" \
               --region="${REGION}" \
               --project="${PROJECT_ID}" \
               --format="get(address)")"
log "Web server static IP: ${STATIC_IP}"

# ---- Cloud Function (database monitor) -------------------------------------
if [ -d ./monitor ]; then
  gcloud functions deploy monitor-database \
    --runtime=python311 \
    --trigger-http \
    --entry-point=monitor_database \
    --source=./monitor \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --set-env-vars="GCP_PROJECT=${PROJECT_ID},CLOUDSQL_INSTANCE=${CLOUDSQL_INSTANCE},ALLOW_START_HOUR=0,ALLOW_END_HOUR=24" \
    --no-allow-unauthenticated \
    --quiet

  FUNC_URL="$(gcloud functions describe monitor-database \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="value(serviceConfig.uri)")"

  FUNC_SA="$(gcloud functions describe monitor-database \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="value(serviceConfig.serviceAccountEmail)")"

  if ! gcloud scheduler jobs describe monitor-database-job \
         --location="${REGION}" \
         --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud scheduler jobs create http monitor-database-job \
      --schedule="0 * * * *" \
      --uri="${FUNC_URL}" \
      --oidc-service-account-email="${FUNC_SA}" \
      --location="${REGION}" \
      --project="${PROJECT_ID}" \
      --quiet
  fi
else
  log "WARNING: ./monitor directory not found – skipping Cloud Function deploy."
fi

# ---- VMs -------------------------------------------------------------------
COMMON_METADATA=(
  "BUCKET=${DATA_BUCKET}"
  "SCRIPTS_BUCKET=${SCRIPT_BUCKET}"
  "FOLDER=20000"
)

if ! gcloud compute instances describe "${WEB_VM_NAME}" \
       --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  log "Creating web server VM '${WEB_VM_NAME}'..."
  gcloud compute instances create "${WEB_VM_NAME}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --image-family="${IMAGE_FAMILY}" \
    --image-project="${IMAGE_PROJECT}" \
    --address="${STATIC_IP_NAME}" \
    --scopes=cloud-platform \
    --tags="${FIREWALL_TAG_WEB}" \
    --service-account="${WEB_SA_EMAIL}" \
    --metadata-from-file=startup-script=./startup.sh \
    --metadata="instance-role=webserver,$(IFS=,; echo "${COMMON_METADATA[*]}"),PORT=${WEB_PORT},CLOUD_SQL_CONNECTION_NAME=${CLOUD_SQL_CONNECTION_NAME},DB_NAME=${DB_NAME},DB_USER=${DB_USER},DB_PASSWORD=${DB_PASSWORD}" \
    --project="${PROJECT_ID}" \
    --quiet
else
  log "VM '${WEB_VM_NAME}' already exists – starting if stopped..."
  gcloud compute instances start "${WEB_VM_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet || true
fi

if ! gcloud compute instances describe "${FORB_VM_NAME}" \
       --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  log "Creating forbidden service VM '${FORB_VM_NAME}'..."
  gcloud compute instances create "${FORB_VM_NAME}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --image-family="${IMAGE_FAMILY}" \
    --image-project="${IMAGE_PROJECT}" \
    --tags="${FIREWALL_TAG_FORB}" \
    --scopes=cloud-platform \
    --service-account="${FORB_SA_EMAIL}" \
    --metadata-from-file=startup-script=./startup.sh \
    --metadata="instance-role=forbidden,$(IFS=,; echo "${COMMON_METADATA[*]}"),PORT=${FORB_PORT}" \
    --project="${PROJECT_ID}" \
    --quiet
else
  log "VM '${FORB_VM_NAME}' already exists – starting if stopped..."
  gcloud compute instances start "${FORB_VM_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet || true
fi

if ! gcloud compute instances describe "${CLIENT_VM_NAME}" \
       --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  log "Creating client VM '${CLIENT_VM_NAME}'..."
  gcloud compute instances create "${CLIENT_VM_NAME}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --image-family="${IMAGE_FAMILY}" \
    --image-project="${IMAGE_PROJECT}" \
    --scopes=cloud-platform \
    --service-account="${CLIENT_SA_EMAIL}" \
    --metadata-from-file=startup-script=./startup.sh \
    --metadata="instance-role=client,SCRIPTS_BUCKET=${SCRIPT_BUCKET}" \
    --project="${PROJECT_ID}" \
    --quiet
else
  log "VM '${CLIENT_VM_NAME}' already exists – starting if stopped..."
  gcloud compute instances start "${CLIENT_VM_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet || true
fi

log "================================================================"
log "Setup complete."
log "Web server : http://${STATIC_IP}:${WEB_PORT}"
log "Cloud SQL  : ${CLOUD_SQL_CONNECTION_NAME}"
log "DB name    : ${DB_NAME}   DB user: ${DB_USER}"
log "================================================================"