#!/usr/bin/env bash
set -euo pipefail

ZIPKIN_VERSION="3.3.1"   # adjust if a newer official release exists; check https://github.com/openzipkin/zipkin/releases
ZIPKIN_JAR="/opt/zipkin/zipkin-server.jar"

sudo mkdir -p /opt/zipkin
sudo curl -L -o "$ZIPKIN_JAR" "https://search.maven.org/remotecontent?filepath=io/zipkin/zipkin-server/${ZIPKIN_VERSION}/zipkin-server-${ZIPKIN_VERSION}-exec.jar"
sudo chmod 755 "$ZIPKIN_JAR"

# systemd unit
sudo tee /etc/systemd/system/zipkin.service > /dev/null <<'EOF'
[Unit]
Description=Zipkin Tracing UI
After=network.target

[Service]
User=root
ExecStart=/usr/bin/java -jar /opt/zipkin/zipkin-server.jar
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now zipkin.service
sudo journalctl -u zipkin.service -n 200 --no-pager
echo "Zipkin UI should be available at http://<vm-ip>:9411"
