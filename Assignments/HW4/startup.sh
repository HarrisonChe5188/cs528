#!/bin/bash
set -euo pipefail
set -x

# Redirect all output to a startup debug log so we can inspect what happened.
LOG="/var/log/startup-debug.log"
exec > >(tee -a "$LOG") 2>&1

LOCKFILE="/var/log/startup_already_done"
if [ -f "$LOCKFILE" ]; then
    echo "Startup already ran. Exiting."
    exit 0
fi

echo "=== startup.sh beginning ==="
date

# -------------------
# Read metadata
# -------------------
METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
ROLE="$(curl -s -H "Metadata-Flavor: Google" "${METADATA_URL}/instance-role" || echo "")"
BUCKET="$(curl -s -H "Metadata-Flavor: Google" "${METADATA_URL}/BUCKET" || echo "")"
SCRIPTS_BUCKET="$(curl -s -H "Metadata-Flavor: Google" "${METADATA_URL}/SCRIPTS_BUCKET" || echo "$BUCKET")"
PORT="$(curl -s -H "Metadata-Flavor: Google" "${METADATA_URL}/PORT" || echo "")"
FOLDER="$(curl -s -H "Metadata-Flavor: Google" "${METADATA_URL}/FOLDER" || echo "20000")"
GCP_PROJECT="$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/project-id" || echo "")"

echo "role=${ROLE} bucket=${BUCKET} scripts_bucket=${SCRIPTS_BUCKET} port=${PORT} folder=${FOLDER} project=${GCP_PROJECT}"

# -------------------
# Ensure basic tools
# -------------------
apt-get update -y
apt-get install -y python3-venv python3-pip curl ca-certificates || true

# -------------------
# Determine user
# -------------------
USERNAME="0979h"
HOME_DIR="/home/${USERNAME}"
if [ ! -d "$HOME_DIR" ]; then
    echo "User ${USERNAME} does not exist; creating..."
    useradd -m "$USERNAME"
fi

# -------------------
# Create Python venv
# -------------------
VENV_DIR="$HOME_DIR/venv"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi
chown -R "$USERNAME:$USERNAME" "$VENV_DIR"

# Activate venv and install Python dependencies (non-root install to avoid messing system Python)
# Install with pip from inside the venv
source "$VENV_DIR/bin/activate" || true
pip install --upgrade pip || true
pip install google-cloud-storage google-cloud-logging google-cloud-pubsub requests || true

# -------------------
# Helper: download from GCS (try gcloud first, fallback to direct HTTP with token)
# -------------------
download_from_gcs() {
    local bucket="$1"
    local object="$2"
    local dest="$3"

    echo "Attempting to download gs://${bucket}/${object} -> ${dest}"

    # Try using gcloud/gsutil first (if available)
    if command -v gcloud >/dev/null 2>&1; then
        if gcloud storage cp "gs://${bucket}/${object}" "${dest}" --quiet 2>/tmp/gcloud_download.err; then
            echo "Downloaded using gcloud storage cp"
            return 0
        else
            echo "gcloud storage cp failed; see /tmp/gcloud_download.err"
            cat /tmp/gcloud_download.err || true
        fi
    fi

    # Fallback: use metadata token + curl to download via Storage JSON API
    # Get access token
    TOKEN="$(curl -s -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")" || true
    if [ -z "$TOKEN" ]; then
        echo "Failed to get access token from metadata server; cannot download."
        return 2
    fi

    # URL-encode object name
    ENCODED_OBJECT="$(python3 - <<PY
import urllib.parse, sys
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
"$object")"

    URL="https://storage.googleapis.com/storage/v1/b/${bucket}/o/${ENCODED_OBJECT}?alt=media"
    echo "Using URL: ${URL}"
    if curl -f -H "Authorization: Bearer ${TOKEN}" -o "${dest}" "${URL}"; then
        echo "Downloaded ${object} using HTTP+token"
        return 0
    else
        echo "HTTP download failed for ${object}"
        return 3
    fi
}

# -------------------
# Fetch service script
# -------------------
mkdir -p "$HOME_DIR/service"
cd "$HOME_DIR/service"

if [ "$ROLE" = "webserver" ]; then
    if ! download_from_gcs "${SCRIPTS_BUCKET}" "service1.py" "./service1.py"; then
        echo "Failed to fetch service1.py"
        touch "$LOCKFILE"
        exit 1
    fi
    SERVICE_FILE="$HOME_DIR/service/service1.py"
    SERVICE_NAME="webserver"
    SERVICE_PORT="${PORT:-8080}"
elif [ "$ROLE" = "forbidden" ]; then
    if ! download_from_gcs "${SCRIPTS_BUCKET}" "service2.py" "./service2.py"; then
        echo "Failed to fetch service2.py"
        touch "$LOCKFILE"
        exit 1
    fi
    SERVICE_FILE="$HOME_DIR/service/service2.py"
    SERVICE_NAME="forbidden"
    SERVICE_PORT="${PORT:-5000}"
elif [ "$ROLE" = "client" ]; then
    if ! download_from_gcs "${SCRIPTS_BUCKET}" "http-client" "./http-client"; then
        echo "Failed to fetch http-client"
        touch "$LOCKFILE"
        exit 1
    fi
    chown "$USERNAME:$USERNAME" ./http-client || true
    chmod +x ./http-client || true
    echo "http-client downloaded and made executable"
    touch "$LOCKFILE"
    exit 0
else
    echo "No valid role metadata provided; exiting."
    touch "$LOCKFILE"
    exit 0
fi

chown -R "$USERNAME:$USERNAME" "$HOME_DIR/service"
chmod +x "$SERVICE_FILE" || true

# -------------------
# Create systemd service unit
# -------------------
SERVICE_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "$SERVICE_UNIT" <<UNIT
[Unit]
Description=hw4 ${SERVICE_NAME} service
After=network.target

[Service]
User=${USERNAME}
WorkingDirectory=${HOME_DIR}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${VENV_DIR}/bin
Environment=GCP_PROJECT=${GCP_PROJECT}
Environment=BUCKET=${BUCKET}
Environment=FOLDER=${FOLDER}
Environment=PORT=${SERVICE_PORT}
ExecStart=${VENV_DIR}/bin/python ${SERVICE_FILE}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

# -------------------
# Enable & start service
# -------------------
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl start "${SERVICE_NAME}.service" || {
    echo "systemctl start failed; showing journal for ${SERVICE_NAME}.service"
    journalctl -u "${SERVICE_NAME}.service" -n 200 || true
    touch "$LOCKFILE"
    exit 1
}

# -------------------
# Mark startup done
# -------------------
touch "$LOCKFILE"
echo "Startup script completed for role=${ROLE}."
date