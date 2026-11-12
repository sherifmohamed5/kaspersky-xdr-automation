#!/bin/bash
set -e

TARGET_DIR="/root/XDR"
REPO_RAW="https://raw.githubusercontent.com/sherifmohamed5/kaspersky-xdr-automation/main"

echo "==> Setting up Kaspersky XDR deployment environment..."
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

echo "==> Fetching installer and configuration from GitHub..."
curl -sSL -O "$REPO_RAW/xdr_all_in_one.sh"
curl -sSL -O "$REPO_RAW/config.env"
curl -L "https://box.kaspersky.com/f/0159e844f0d946ec93f8/?dl=1" -o XDR_Amin.sh

chmod +x xdr_all_in_one.sh
sed -i 's/\r$//' xdr_all_in_one.sh config.env

echo "==> Launching installer..."
exec ./xdr_all_in_one.sh
