#!/usr/bin/env bash
set -euo pipefail

# Install Amazon Corretto 17 (OpenJDK 17) on Amazon Linux 2023
# Source / verification: AWS Corretto docs
# https://docs.aws.amazon.com/corretto/latest/corretto-17-ug/amazon-linux-install.html

sudo tee /etc/yum.repos.d/corretto.repo > /dev/null <<'EOF'
[corretto]
name=Amazon Corretto
baseurl=https://corretto.aws/downloads/17/amazon-linux/2023/x86_64/
enabled=1
gpgcheck=0
EOF

sudo dnf makecache
sudo dnf install -y java-17-amazon-corretto-headless

# verify
java -version
echo "Java installed."