#!/usr/bin/env bash
set -euo pipefail

# --- variables ---
TAG="v0.140.1"
ASSET_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/${TAG}/otelcol-contrib_0.140.1_linux_amd64.tar.gz"
TMP="/tmp/otel_install_$$"
BIN_DEST="/usr/local/bin/otelcol-contrib"
CONFIG_DIR="/etc/otel"
SERVICE_FILE="/etc/systemd/system/otelcol.service"

# --- prepare ---
mkdir -p "${TMP}"
cd "${TMP}"

echo "Downloading collector asset:"
echo "${ASSET_URL}"
curl -L -o ./otelcol.tar.gz "${ASSET_URL}"

echo "Listing tarball contents (first 50 lines):"
tar -tzf ./otelcol.tar.gz | head -n 50

echo "Extracting tarball..."
tar -xzf ./otelcol.tar.gz -C .

# Find the binary file (search for 'otelcol' or 'otelcol-contrib')
BIN_PATH=$(find . -type f \( -name "otelcol*" -o -name "otelcol-contrib*" \) -perm /111 -print -quit || true)

# If not found with exec bit, try any file named otelcol* or otelcol-contrib*
if [ -z "$BIN_PATH" ]; then
  BIN_PATH=$(find . -type f \( -name "otelcol*" -o -name "otelcol-contrib*" \) -print -quit || true)
fi

if [ -z "$BIN_PATH" ]; then
  echo "ERROR: Could not find otelcol binary in the extracted tarball. Showing extracted files:"
  find . -maxdepth 3 -type f -print
  exit 1
fi

echo "Found binary: $BIN_PATH"
sudo install -m 0755 "$BIN_PATH" "${BIN_DEST}"

# create config dir + default config if missing
sudo mkdir -p "${CONFIG_DIR}"
if [ ! -f "${CONFIG_DIR}/otel-collector-config.yaml" ]; then
  sudo tee /etc/otel/otel-collector-config.yaml > /dev/null <<'EOF'
receivers:
  otlp:
    protocols:
      grpc:
      http:

exporters:
  debug: {}                # replaces deprecated "logging" exporter
  zipkin:
    endpoint: "http://localhost:9411/api/v2/spans"

processors:
  batch:

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug, zipkin]
EOF
fi

# systemd unit
sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description=OpenTelemetry Collector Contrib
After=network.target

[Service]
ExecStart=${BIN_DEST} --config ${CONFIG_DIR}/otel-collector-config.yaml
User=root
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# enable & start
sudo systemctl daemon-reload
sudo systemctl enable --now otelcol.service

echo "Service status (short):"
sudo systemctl status otelcol.service --no-pager -n 20 || true

echo
echo "Last 200 journal lines from otelcol.service:"
sudo journalctl -u otelcol.service -n 200 --no-pager || true

# cleanup
cd /
rm -rf "${TMP}"
echo "Done."