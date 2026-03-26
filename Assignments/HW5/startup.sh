#!/bin/bash

set -euo pipefail
set -x

LOG="/var/log/startup-debug.log"
exec > >(tee -a "$LOG") 2>&1

LOCKFILE="/var/log/startup_already_done"
if [ -f "$LOCKFILE" ]; then
    echo "Startup already ran. Exiting."
    exit 0
fi

# ---------------------------------------------------------------------------
# Read instance metadata
# ---------------------------------------------------------------------------
METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
_meta() { curl -sf -H "Metadata-Flavor: Google" "${METADATA_URL}/$1" 2>/dev/null || echo ""; }
_project() { curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/project-id" 2>/dev/null || echo ""; }

ROLE="$(_meta instance-role)"
BUCKET="$(_meta BUCKET)"
SCRIPTS_BUCKET="$(_meta SCRIPTS_BUCKET)"
[ -z "$SCRIPTS_BUCKET" ] && SCRIPTS_BUCKET="$BUCKET"
PORT="$(_meta PORT)"
[ -z "$PORT" ] && PORT="8080"
FOLDER="$(_meta FOLDER)"
[ -z "$FOLDER" ] && FOLDER="20000"
GCP_PROJECT="$(_project)"

CLOUD_SQL_CONNECTION_NAME="$(_meta CLOUD_SQL_CONNECTION_NAME)"
DB_NAME="$(_meta DB_NAME)"
DB_USER="$(_meta DB_USER)"
DB_PASSWORD="$(_meta DB_PASSWORD)"

echo "=== startup.sh ==="
echo "role=${ROLE}  bucket=${BUCKET}  scripts_bucket=${SCRIPTS_BUCKET}  project=${GCP_PROJECT}"

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    python3-venv python3-pip curl ca-certificates

# ---------------------------------------------------------------------------
# App user + venv
# ---------------------------------------------------------------------------
APP_USER="hw5app"
APP_HOME="/home/${APP_USER}"

if ! id "${APP_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${APP_USER}"
fi

VENV_DIR="/opt/hw5-venv"
if [ ! -d "${VENV_DIR}" ]; then
    python3 -m venv "${VENV_DIR}"
fi

source "${VENV_DIR}/bin/activate"
pip install --upgrade pip --quiet
pip install --quiet \
    google-cloud-storage \
    google-cloud-logging \
    google-cloud-pubsub \
    mysql-connector-python

# ---------------------------------------------------------------------------
# Download helper
# ---------------------------------------------------------------------------
download_from_gcs() {
    local bucket="$1"
    local object="$2"
    local dest="$3"
    echo "Downloading gs://${bucket}/${object} -> ${dest}"
    gcloud storage cp "gs://${bucket}/${object}" "${dest}" --quiet
}

mkdir -p "${APP_HOME}/service"
cd "${APP_HOME}/service"

# ---------------------------------------------------------------------------
# Role: webserver
# ---------------------------------------------------------------------------
if [ "$ROLE" = "webserver" ]; then

    download_from_gcs "$SCRIPTS_BUCKET" "service1.py" "./service1.py"
    chown "${APP_USER}:${APP_USER}" service1.py
    chmod +x service1.py

    # Install Cloud SQL Auth Proxy
    curl -fsSL \
        "https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.21.2/cloud-sql-proxy.linux.amd64" \
        -o /usr/local/bin/cloud-sql-proxy
    chmod +x /usr/local/bin/cloud-sql-proxy

    # Proxy systemd unit
    cat > /etc/systemd/system/cloud-sql-proxy.service <<UNIT
[Unit]
Description=Cloud SQL Auth Proxy
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/cloud-sql-proxy --address 127.0.0.1 --port 3306 ${CLOUD_SQL_CONNECTION_NAME}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    # Web server systemd unit
    cat > /etc/systemd/system/webserver.service <<UNIT
[Unit]
Description=HW5 Web Server
After=network-online.target cloud-sql-proxy.service
Requires=cloud-sql-proxy.service

[Service]
User=${APP_USER}
WorkingDirectory=${APP_HOME}/service
Environment=PATH=${VENV_DIR}/bin:/usr/bin:/bin
Environment=GCP_PROJECT=${GCP_PROJECT}
Environment=BUCKET=${BUCKET}
Environment=FOLDER=${FOLDER}
Environment=PORT=${PORT}
Environment=DB_HOST=127.0.0.1
Environment=DB_PORT=3306
Environment=DB_NAME=${DB_NAME}
Environment=DB_USER=${DB_USER}
Environment=DB_PASSWORD=${DB_PASSWORD}
ExecStart=${VENV_DIR}/bin/python ${APP_HOME}/service/service1.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable cloud-sql-proxy webserver
    systemctl start cloud-sql-proxy
    # Give the proxy a moment before starting the web server
    sleep 5
    systemctl start webserver

# ---------------------------------------------------------------------------
# Role: forbidden
# ---------------------------------------------------------------------------
elif [ "$ROLE" = "forbidden" ]; then

    download_from_gcs "$SCRIPTS_BUCKET" "service2.py" "./service2.py"
    chown "${APP_USER}:${APP_USER}" service2.py
    chmod +x service2.py

    cat > /etc/systemd/system/forbidden.service <<UNIT
[Unit]
Description=HW5 Forbidden Country Reporting Service
After=network-online.target
Wants=network-online.target

[Service]
User=${APP_USER}
WorkingDirectory=${APP_HOME}/service
Environment=PATH=${VENV_DIR}/bin:/usr/bin:/bin
Environment=GCP_PROJECT=${GCP_PROJECT}
Environment=BUCKET=${BUCKET}
Environment=PORT=${PORT}
ExecStart=${VENV_DIR}/bin/python ${APP_HOME}/service/service2.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable forbidden
    systemctl start forbidden

# ---------------------------------------------------------------------------
# Role: client
# ---------------------------------------------------------------------------
elif [ "$ROLE" = "client" ]; then

    download_from_gcs "$SCRIPTS_BUCKET" "http-client" "./http-client"
    chown "${APP_USER}:${APP_USER}" http-client
    chmod +x http-client

else
    echo "WARNING: unknown instance-role '${ROLE}' – nothing to start."
fi

touch "$LOCKFILE"
echo "=== startup.sh completed. ==="