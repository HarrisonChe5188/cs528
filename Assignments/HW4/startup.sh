#!/bin/bash
set -euo pipefail

LOCKFILE="/var/log/startup_already_done"
if [ -f "$LOCKFILE" ]; then
    echo "Startup already ran. Exiting."
    exit 0
fi

# -------------------
# Read metadata
# -------------------
ROLE=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/instance-role" || echo "")
BUCKET=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/BUCKET" || echo "")
PORT=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/PORT" || echo "")

# -------------------
# Ensure basic tools
# -------------------
apt-get update
apt-get install -y python3-venv python3-pip curl

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

# Activate venv and install Python dependencies
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install google-cloud-storage google-cloud-logging google-cloud-pubsub requests

# -------------------
# Fetch service script
# -------------------
mkdir -p "$HOME_DIR/service"
cd "$HOME_DIR/service"

if [ "$ROLE" = "webserver" ]; then
    gsutil -q cp "gs://$BUCKET/service1.py" ./service1.py || true
    SERVICE_FILE="$HOME_DIR/service/service1.py"
    SERVICE_NAME="webserver"
    SERVICE_PORT="${PORT:-8080}"
elif [ "$ROLE" = "forbidden" ]; then
    gsutil -q cp "gs://$BUCKET/service2.py" ./service2.py || true
    SERVICE_FILE="$HOME_DIR/service/service2.py"
    SERVICE_NAME="forbidden"
    SERVICE_PORT="${PORT:-5000}"
elif [ "$ROLE" = "client" ]; then
    # client VM: pull the http-client binary so tests can run
    gsutil -q cp "gs://$BUCKET/http-client" ./http-client || true
    chown "$USERNAME:$USERNAME" ./http-client
    chmod +x ./http-client
    echo "http-client downloaded"
    # no service to start, just exit after setup
    touch "$LOCKFILE"
    exit 0
else
    echo "No valid role metadata provided; exiting."
    touch "$LOCKFILE"
    exit 0
fi

chown -R "$USERNAME:$USERNAME" "$HOME_DIR/service"
chmod +x "$SERVICE_FILE"

# -------------------
# Create systemd service unit
# -------------------
SERVICE_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "$SERVICE_UNIT" <<EOF
[Unit]
Description=hw4 ${SERVICE_NAME} service
After=network.target

[Service]
User=${USERNAME}
WorkingDirectory=${HOME_DIR}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${VENV_DIR}/bin
ExecStart=${VENV_DIR}/bin/python ${SERVICE_FILE}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# -------------------
# Enable & start service
# -------------------
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl start "${SERVICE_NAME}.service"

# -------------------
# Mark startup done
# -------------------
touch "$LOCKFILE"
echo "Startup script completed for role=${ROLE}."