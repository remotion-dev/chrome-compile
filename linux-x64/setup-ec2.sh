#!/bin/bash
set -euo pipefail

# =============================================================================
# setup-ec2-x86.sh — Run on the x86_64 EC2 instance after SSH login (as root)
#
# Installs Docker, builds the Chromium build image, runs the build,
# and extracts chromium-headless-shell-linux64.zip.
# =============================================================================

echo "=== Installing Docker ==="
dnf install -y docker
systemctl start docker
systemctl enable docker

echo "=== Pulling Ubuntu base image ==="
docker pull ubuntu:22.04

echo "=== Building Docker image ==="
BUILD_DIR="/root/chrome-build"
mkdir -p "$BUILD_DIR"

# Copy all needed files into the build context
cp /root/setup-ec2-x86.sh "$BUILD_DIR/" 2>/dev/null || true
cp /root/Dockerfile-x86 "$BUILD_DIR/Dockerfile"
cp /root/build-chromium-x86.sh "$BUILD_DIR/"
cp /root/.gclient "$BUILD_DIR/dot-gclient"
cp /root/args-x86.gn "$BUILD_DIR/"

cd "$BUILD_DIR"
docker build -t chrome-builder-x86 .

echo "=== Running build container ==="
# Run with enough memory and all CPUs
docker run --name chrome-build-x86 \
  --privileged \
  --memory=60g \
  --cpus=$(nproc) \
  chrome-builder-x86 \
  bash /root/build-chromium-x86.sh

echo "=== Extracting chromium-headless-shell-linux64.zip ==="
docker cp chrome-build-x86:/root/chromium/src/final/chromium-headless-shell-linux64.zip /root/chromium-headless-shell-linux64.zip

echo ""
echo "========================================="
echo "Build complete!"
echo "Output: /root/chromium-headless-shell-linux64.zip"
echo "========================================="
echo ""
echo "Copy it out with:"
echo "  scp -i chrome-build-key-x86.pem ec2-user@<IP>:/root/chromium-headless-shell-linux64.zip ."
