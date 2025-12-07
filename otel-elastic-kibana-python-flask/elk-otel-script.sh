#!/usr/bin/env bash
# elk_otel_amazon_linux2023.sh
# POC / LAB ONLY – disables Elasticsearch security.

set -euo pipefail

############################
# Configurable versions
############################
ES_REPO_BRANCH="8.x"
OTEL_VERSION="v0.137.0"  # change to latest if you want
OTEL_USER="otel"
OTEL_GROUP="otel"
OTEL_DIR="/opt/otelcol-contrib"
OTEL_CONFIG_DIR="/etc/otelcol-contrib"
OTEL_CONFIG_FILE="${OTEL_CONFIG_DIR}/config.yaml"

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }

########################################
# 0. Basic checks
########################################
if [[ $EUID -ne 0 ]]; then
  err "Run as root (sudo su -)"; exit 1
fi

if ! grep -q "Amazon Linux" /etc/os-release || ! grep -q "2023" /etc/os-release; then
  err "This script expects Amazon Linux 2023."; exit 1
fi

log "Running on Amazon Linux 2023"

########################################
# 1. System update + prerequisites
########################################
log "Updating system and installing tools..."
dnf -y update
#dnf -y install curl wget tar gnupg2 jq
dnf -y install wget tar jq


########################################
# 2. Install Elasticsearch + Kibana
########################################
log "Importing Elastic GPG key..."
rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch

log "Creating /etc/yum.repos.d/elasticsearch.repo..."
cat >/etc/yum.repos.d/elasticsearch.repo <<EOF
[elasticsearch]
name=Elastic repository for ${ES_REPO_BRANCH} packages
baseurl=https://artifacts.elastic.co/packages/${ES_REPO_BRANCH}/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
EOF

log "Installing Elasticsearch and Kibana..."
dnf clean all
dnf makecache

dnf -y install elasticsearch kibana

########################################
# 3. Configure Elasticsearch (single node, security disabled – DEV ONLY)
########################################
log "Configuring Elasticsearch..."

ES_YML="/etc/elasticsearch/elasticsearch.yml"
cp -a "${ES_YML}" "${ES_YML}.bak.$(date +%s)" || true

cat >"${ES_YML}" <<'EOF'
cluster.name: otel-es-cluster
node.name: ${HOSTNAME}
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

network.host: 0.0.0.0
http.port: 9200

discovery.type: single-node

# --- DEV ONLY: disable security (no TLS, no auth) ---
xpack.security.enabled: false
xpack.security.transport.ssl.enabled: false
xpack.security.http.ssl.enabled: false
EOF

# Fix node.name placeholder
sed -i "s/\${HOSTNAME}/$(hostname)/" "${ES_YML}"

log "Enabling and starting Elasticsearch service..."
systemctl daemon-reload
systemctl enable elasticsearch
systemctl start elasticsearch

log "Waiting for Elasticsearch (60s)..."
sleep 60 || true

if curl -s http://localhost:9200 >/dev/null 2>&1; then
  log "Elasticsearch is up on http://localhost:9200"
else
  err "Elasticsearch did not respond on port 9200. Check: journalctl -u elasticsearch"
fi

########################################
# 4. Configure Kibana
########################################
log "Configuring Kibana..."

KIB_YML="/etc/kibana/kibana.yml"
cp -a "${KIB_YML}" "${KIB_YML}.bak.$(date +%s)" || true

cat >"${KIB_YML}" <<'EOF'
server.host: "0.0.0.0"
server.port: 5601

# Elasticsearch URL (no TLS / no auth in this POC)
elasticsearch.hosts: ["http://localhost:9200"]

# Optional: give Kibana a nice name
server.name: "kibana-otel-lab"
EOF

log "Enabling and starting Kibana..."
systemctl enable kibana
systemctl start kibana

########################################
# 5. Install OpenTelemetry Collector (contrib)
########################################
log "Installing OpenTelemetry Collector Contrib..."

# Create user & dirs
id -u "${OTEL_USER}" >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin "${OTEL_USER}"
getent group "${OTEL_GROUP}" >/dev/null 2>&1 || groupadd --system "${OTEL_GROUP}" || true
usermod -a -G "${OTEL_GROUP}" "${OTEL_USER}" || true

mkdir -p "${OTEL_DIR}" "${OTEL_CONFIG_DIR}"
chown -R "${OTEL_USER}:${OTEL_GROUP}" "${OTEL_DIR}" "${OTEL_CONFIG_DIR}"

# Derive tarball name from version
OTEL_VERSION_NUM="${OTEL_VERSION#v}"
TARBALL="otelcol-contrib_${OTEL_VERSION_NUM}_linux_amd64.tar.gz"
OTEL_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/${OTEL_VERSION}/${TARBALL}"

log "Downloading OTEL Collector from ${OTEL_URL}"
curl -fSL "${OTEL_URL}" -o "/tmp/${TARBALL}"

log "Extracting OTEL Collector..."
tar -xzf "/tmp/${TARBALL}" -C "${OTEL_DIR}"
rm -f "/tmp/${TARBALL}"

# Copy binary to /usr/local/bin
if [[ -f "${OTEL_DIR}/otelcol-contrib" ]]; then
  cp "${OTEL_DIR}/otelcol-contrib" /usr/local/bin/otelcol-contrib
else
  err "otelcol-contrib binary not found after extraction."; exit 1
fi

chmod 755 /usr/local/bin/otelcol-contrib
chown "${OTEL_USER}:${OTEL_GROUP}" /usr/local/bin/otelcol-contrib

########################################
# 6. OTEL Collector config (logs -> Elasticsearch)
########################################
log "Writing OTEL Collector config to ${OTEL_CONFIG_FILE}..."

cat > "${OTEL_CONFIG_FILE}" <<'EOF'
receivers:
  # Accept OTLP from applications (traces, metrics, logs)
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

  # (Optional) Tail log files on this server
  filelog:
    include:
      - /var/log/myapp/*.log
    start_at: beginning
    include_file_path: true
    poll_interval: 5s

processors:
  batch: {}

exporters:
  # Debug exporter (prints to collector logs)
  debug:
    verbosity: basic

  # Elasticsearch exporter (sends logs/metrics/traces to Elasticsearch)
  # Using HTTP (no TLS, no auth) in this POC.
  elasticsearch/logs:
    endpoints: ["http://localhost:9200"]
    logs_index: "otel-logs"
    mapping:
      mode: "ecs"
    flush:
      bytes: 10485760
    retry:
      max_requests: 5
    sending_queue:
      enabled: true

service:
  pipelines:
    logs:
      receivers: [otlp, filelog]
      processors: [batch]
      exporters: [debug, elasticsearch/logs]
EOF

chown -R "${OTEL_USER}:${OTEL_GROUP}" "${OTEL_CONFIG_DIR}"
chmod 640 "${OTEL_CONFIG_FILE}"

########################################
# 7. systemd unit for OTEL Collector
########################################
log "Creating systemd service for otelcol-contrib..."

cat >/etc/systemd/system/otelcol-contrib.service <<EOF
[Unit]
Description=OpenTelemetry Collector Contrib
After=network-online.target
Wants=network-online.target

[Service]
User=${OTEL_USER}
Group=${OTEL_GROUP}
ExecStart=/usr/local/bin/otelcol-contrib --config ${OTEL_CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable otelcol-contrib
systemctl start otelcol-contrib

########################################
# 8. Summary
########################################
log "====================================================="
log "SETUP COMPLETE (POC / DEV)"
log "Elasticsearch: http://<SERVER-A-PUBLIC-OR-PRIVATE-IP>:9200"
log "Kibana:       http://<SERVER-A-PUBLIC-OR-PRIVATE-IP>:5601"
log "OTLP gRPC:    <SERVER-A-IP>:4317"
log "OTLP HTTP:    <SERVER-A-IP>:4318"
log "Logs index:   otel-logs"
log "Remember: security is DISABLED on Elasticsearch (dev use only)."
log "====================================================="