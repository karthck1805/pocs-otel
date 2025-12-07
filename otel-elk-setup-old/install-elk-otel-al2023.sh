#!/usr/bin/env bash
set -euo pipefail

# ---------- VARIABLES (edit) ----------
ES_VERSION="8.11.1"                # example - change to the version you want
OTEL_COLLECTOR_VERSION="0.81.0"    # example contrib collector version (edit if needed)
ENABLE_KIBANA=true                 # change to false to skip Kibana
ES_BIND_HOST="0.0.0.0"             # for single-node test; restrict in production
ES_CLUSTER_NAME="es-single-node"
ES_PASSWORD="ChangeMeStrongPassword123!"   # set a strong password or integrate with secrets
OTEL_USER="otel"                   # user to run collector
# ---------------------------------------

echo "Running install script for Elasticsearch ${ES_VERSION} + OTEL Collector ${OTEL_COLLECTOR_VERSION} on Amazon Linux 2023"

# Update OS and install basic packages
dnf -y update
dnf -y install wget curl tar gzip policycoreutils-python-utils bash-completion vim

# Install Java (Elasticsearch 8 bundles its Java, but having openjdk is safe)
dnf -y install java-17-openjdk

# Create a working dir
WORKDIR="/tmp/elk-otel-setup"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# -----------------------
# Install Elasticsearch (RPM)
# -----------------------
echo "Downloading Elasticsearch RPM..."
ES_RPM="elasticsearch-${ES_VERSION}-x86_64.rpm"
ES_BASE="https://artifacts.elastic.co/downloads/elasticsearch"
curl -fLO "${ES_BASE}/${ES_RPM}"
echo "Installing Elasticsearch..."
dnf -y localinstall "./${ES_RPM}"

# Configure elasticsearch.yml minimally for single-node
ES_YML="/etc/elasticsearch/elasticsearch.yml"
cat > "${ES_YML}" <<EOF
cluster.name: ${ES_CLUSTER_NAME}
network.host: ${ES_BIND_HOST}
http.port: 9200
discovery.type: single-node
xpack.security.enabled: true
EOF

# Set file ownership and enable service
chown -R elasticsearch:elasticsearch /etc/elasticsearch /var/lib/elasticsearch /var/log/elasticsearch || true
systemctl daemon-reload
systemctl enable --now elasticsearch

# Wait for ES to be reachable
echo "Waiting for Elasticsearch to respond on localhost:9200..."
for i in {1..30}; do
  if curl -s -u "elastic:${ES_PASSWORD}" "http://localhost:9200/" >/dev/null 2>&1; then
    break
  fi
  # if ES not yet set password, skip auth check
  if curl -s "http://localhost:9200/" | grep -q "You Know, for Search"; then
    break
  fi
  sleep 3
done

echo "Elasticsearch installed. NOTE: Elasticsearch may require initial password setup if this is a brand new installation."

# Configure built-in elastic user password if we can (unsafe to store in plaintext scripts).
# We skip automated secure setup here because it requires interactive 'elasticsearch-reset-password' or API keys.
# For a quick test you can set a built-in password by running:
#   /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b
# Or use the API with the bootstrap password in /var/lib/elasticsearch/config/bootstrap* (see docs).

# -----------------------
# Optional: Install Kibana (if requested)
# -----------------------
if [ "${ENABLE_KIBANA}" = true ]; then
  echo "Installing Kibana..."
  KIBANA_RPM="kibana-${ES_VERSION}-x86_64.rpm"
  KIBANA_BASE="https://artifacts.elastic.co/downloads/kibana"
  curl -fLO "${KIBANA_BASE}/${KIBANA_RPM}"
  dnf -y localinstall "./${KIBANA_RPM}"
  # minimal kibana config
  cat > /etc/kibana/kibana.yml <<EOF
server.host: "0.0.0.0"
elasticsearch.hosts: ["http://localhost:9200"]
EOF
  systemctl enable --now kibana
fi

# -----------------------
# Install OpenTelemetry Collector (contrib) as binary + systemd
# -----------------------
echo "Installing OpenTelemetry Collector (contrib) ..."

USER_HOME="/opt/otel"
mkdir -p "${USER_HOME}"
useradd --system --no-create-home --shell /sbin/nologin "${OTEL_USER}" || true

# NOTE: download URL patterns differ across releases. The official collector install doc recommends
# grabbing the binary from the OpenTelemetry releases page. Update the URL below to match the release you want.
OTEL_TGZ="otelcol-contrib_${OTEL_COLLECTOR_VERSION}_linux_amd64.tar.gz"
OTEL_BASE="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_COLLECTOR_VERSION}"
curl -fL -o "${WORKDIR}/${OTEL_TGZ}" "${OTEL_BASE}/${OTEL_TGZ}"
tar -xzf "${WORKDIR}/${OTEL_TGZ}" -C "${WORKDIR}"
# extracted binary should be named 'otelcol-contrib' or similar
if [ -f "${WORKDIR}/otelcol-contrib" ]; then
  mv "${WORKDIR}/otelcol-contrib" /usr/local/bin/otelcol-contrib
  chmod +x /usr/local/bin/otelcol-contrib
else
  echo "ERROR: expected otelcol-contrib binary in ${WORKDIR}. Please verify release name."
  exit 1
fi

# Create config directory and sample config (we'll write a full sample later)
mkdir -p /etc/otel
cat > /etc/otel/collector-config.yaml <<'EOF'
# placeholder - replace with the full otel-collector config provided separately
receivers:
  otlp:
    protocols:
      grpc:
      http:

processors:
  batch:

exporters:
  logging:

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [logging]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [logging]
EOF
chown -R "${OTEL_USER}:${OTEL_USER}" /etc/otel

# Create systemd unit
cat > /etc/systemd/system/otelcol.service <<'SYSTEMD'
[Unit]
Description=OpenTelemetry Collector (contrib)
After=network.target

[Service]
User=otel
Group=otel
ExecStart=/usr/local/bin/otelcol-contrib --config /etc/otel/collector-config.yaml
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable --now otelcol.service

# -----------------------
# Final notes and cleanup
# -----------------------
echo "Setup attempted. Please check services:"
systemctl status elasticsearch --no-pager || true
if [ "${ENABLE_KIBANA}" = true ]; then
  systemctl status kibana --no-pager || true
fi
systemctl status otelcol --no-pager || true

echo "Installation finished. Edit /etc/otel/collector-config.yaml with the sample configuration (I provided separately)."
echo "Remember to set the elastic 'elastic' user password manually or configure secure credentials for production."

# cleanup
rm -rf "${WORKDIR}"
