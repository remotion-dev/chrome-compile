#!/bin/bash
set -euo pipefail

# =============================================================================
# setup-ec2.sh — Run on the EC2 instance after SSH login (as root)
#
# Installs Docker, builds the Chromium build image, runs the build,
# and extracts chromium.zip.
# =============================================================================

echo "=== Installing Docker ==="
dnf install -y docker
systemctl start docker
systemctl enable docker

echo "=== Pulling Lambda base image ==="
docker pull public.ecr.aws/lambda/nodejs:24.2026.01.26.23

echo "=== Building Docker image ==="
# Copy build files to a build context directory
BUILD_DIR="/root/chrome-build"
mkdir -p "$BUILD_DIR"

# Copy all needed files into the build context
cp /root/setup-ec2.sh "$BUILD_DIR/" 2>/dev/null || true
cp /root/Dockerfile "$BUILD_DIR/"
cp /root/build-chromium.sh "$BUILD_DIR/"
cp /root/.gclient "$BUILD_DIR/dot-gclient"
cp /root/args.gn "$BUILD_DIR/"

cd "$BUILD_DIR"
docker build -t chrome-builder .

echo "=== Running build container ==="
# Run with enough memory and tmpfs for the build output directory
docker run --name chrome-build \
  --privileged \
  --memory=60g \
  --cpus=$(nproc) \
  chrome-builder \
  bash /root/build-chromium.sh

echo "=== Extracting chromium.zip ==="
docker cp chrome-build:/root/chromium/src/final/chromium.zip /root/chromium.zip

echo ""
echo "========================================="
echo "Build complete!"
echo "Output: /root/chromium.zip"
echo "========================================="
echo ""
echo "Copy it out with:"
echo "  scp -i chrome-build-key.pem ec2-user@<IP>:/root/chromium.zip ."
