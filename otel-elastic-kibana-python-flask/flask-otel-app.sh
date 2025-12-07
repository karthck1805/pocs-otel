#!/usr/bin/env bash
# flask-otel-app.sh
# Setup a simple Flask app that logs to /var/log/myapp/app.log
# OTEL Collector (already installed) will read those logs via filelog receiver.

set -euo pipefail

APP_USER="ec2-user"
APP_GROUP="ec2-user"
APP_DIR="/opt/flask-otel-app"
VENV_DIR="${APP_DIR}/venv"
LOG_DIR="/var/log/myapp"
LOG_FILE="${LOG_DIR}/app.log"
SERVICE_FILE="/etc/systemd/system/flask-otel-app.service"

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }

########################################
# 0. Basic checks
########################################
if [[ $EUID -ne 0 ]]; then
  err "Run as root (sudo su -)"; exit 1
fi

if ! id -u "${APP_USER}" >/dev/null 2>&1; then
  err "User ${APP_USER} does not exist. Adjust APP_USER or create the user."; exit 1
fi

########################################
# 1. Install Python + tools
########################################
log "Installing Python and tools (if needed)..."
dnf install -y python3 python3-pip

########################################
# 2. Create log directory for OTEL filelog
########################################
log "Creating log directory ${LOG_DIR}..."
mkdir -p "${LOG_DIR}"

# POC-friendly permissions: app + otel can write/read
chmod 777 "${LOG_DIR}"

# Create log file
touch "${LOG_FILE}"
chmod 666 "${LOG_FILE}"

log "Log file ready at ${LOG_FILE}"

########################################
# 3. Create app directory and virtualenv
########################################
log "Creating app directory ${APP_DIR}..."
mkdir -p "${APP_DIR}"
chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"

log "Creating Python virtualenv..."
sudo -u "${APP_USER}" python3 -m venv "${VENV_DIR}"

log "Installing Flask and Gunicorn in venv..."
sudo -u "${APP_USER}" bash -c "
  source '${VENV_DIR}/bin/activate' && \
  pip install --upgrade pip && \
  pip install flask gunicorn
"

########################################
# 4. Create simple Flask app with file logging
########################################
log "Writing Flask app to ${APP_DIR}/app.py..."

cat > "${APP_DIR}/app.py" <<EOF
import logging
from logging.handlers import RotatingFileHandler
from flask import Flask

LOG_FILE = "${LOG_FILE}"

app = Flask(__name__)

# Configure root logger
logger = logging.getLogger()
logger.setLevel(logging.INFO)

file_handler = RotatingFileHandler(LOG_FILE, maxBytes=5 * 1024 * 1024, backupCount=3)
formatter = logging.Formatter(
    "%(asctime)s %(levelname)s [%(name)s] %(message)s"
)
file_handler.setFormatter(formatter)
logger.addHandler(file_handler)


@app.route("/")
def index():
    app.logger.info("Index page hit")
    return "Hello from Flask with OTEL file logs!\\n"


@app.route("/error")
def error():
    app.logger.error("Simulated error endpoint hit")
    return "This is an error endpoint!\\n", 500


if __name__ == "__main__":
    # Dev-only run; we will normally run via gunicorn
    app.run(host="0.0.0.0", port=8000)
EOF

chown "${APP_USER}:${APP_GROUP}" "${APP_DIR}/app.py"

########################################
# 5. Create systemd service for Gunicorn
########################################
log "Creating systemd service ${SERVICE_FILE}..."

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Flask OTEL Demo App (Gunicorn)
After=network.target

[Service]
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_DIR}
Environment="PATH=${VENV_DIR}/bin"
ExecStart=${VENV_DIR}/bin/gunicorn -w 3 -b 0.0.0.0:8000 app:app

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

########################################
# 6. Start and enable service
########################################
log "Reloading systemd and starting flask-otel-app..."
systemctl daemon-reload
systemctl enable flask-otel-app
systemctl start flask-otel-app

sleep 3

systemctl status flask-otel-app --no-pager || true

log "====================================================="
log "Flask app is deployed."
log "URL (from this server): http://localhost:8000/"
log "Log file: ${LOG_FILE}"
log "OTEL Collector should already be tailing ${LOG_DIR} via filelog receiver."
log "Check in Kibana under 'otel-logs' index after hitting the endpoints:"
log "  curl http://localhost:8000/"
log "  curl http://localhost:8000/error"
log "====================================================="
