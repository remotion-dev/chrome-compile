#!/bin/bash
set -euo pipefail

# =============================================================================
# build-chromium.sh — Build Chromium 144.0.7559.97 headless_shell (x86_64)
#
# Runs INSIDE the Docker container (Amazon Linux 2023).
# Targets Amazon Linux x64 — system libs bundled for self-contained deployment.
#
# SIMPLIFIED vs ARM64: No LLVM bootstrap needed — uses pre-built toolchain.
# =============================================================================

CHROME_VERSION="144.0.7559.97"

echo "========================================="
echo "Building Chromium $CHROME_VERSION headless_shell (Amazon Linux x86_64)"
echo "========================================="

# =============================================================================
# 1. Install depot_tools
# =============================================================================
echo ">>> Step 1: Install depot_tools"
export DEPOT_TOOLS_BOOTSTRAP_PYTHON3=0
cd /root
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$PATH:/root/depot_tools"

# =============================================================================
# 2. Clone Chromium and checkout the target version
# =============================================================================
echo ">>> Step 2: Clone Chromium source and checkout $CHROME_VERSION"

# Configure git for large repos and identity for cherry-picks
git config --global http.postBuffer 524288000
git config --global user.email "build@localhost"
git config --global user.name "Build"

mkdir -p /root/chromium
cp /root/dot-gclient /root/chromium/.gclient
cd /root/chromium

# Direct shallow clone of the specific tag (most reliable method)
echo "Cloning Chromium $CHROME_VERSION (shallow)..."
git clone --depth 1 --branch "$CHROME_VERSION" \
  https://chromium.googlesource.com/chromium/src.git src

cd src
echo "Verifying checkout..."
git log -1 --oneline

# =============================================================================
# 3. Sync depot_tools to match the Chromium commit date
# =============================================================================
echo ">>> Step 3: Sync depot_tools to matching date"
COMMIT_DATE=$(git log -n 1 --pretty=format:%ci)
cd /root/depot_tools
git checkout $(git rev-list -n 1 --before="$COMMIT_DATE" main)
export DEPOT_TOOLS_UPDATE=0

# =============================================================================
# 4. Patch lastchange.py (same as ARM64)
# =============================================================================
echo ">>> Step 4: Patch lastchange.py"
cd /root/chromium/src

# Fix lastchange.py quoting for git log format
if [ -f build/util/lastchange.py ]; then
  sed -i "s/git_args = \['log', '-1', '--format=%H %ct'\]/git_args = ['log', '-1', '--format=\"%H %ct\"']/" build/util/lastchange.py
  echo "Patched lastchange.py"
fi

# =============================================================================
# 5. gclient sync and runhooks
# =============================================================================
echo ">>> Step 5: gclient sync"
cd /root/chromium/src
gclient sync -D --no-history --shallow --force --reset
gclient runhooks

# =============================================================================
# 5.5. Replace system Python 3.9 with Python 3.11 from vpython cache
# =============================================================================
echo ">>> Step 5.5: Fix Python version (AL2023 ships 3.9, Chrome 144 needs 3.10+)"
VPYTHON3=$(find /root/.cache/vpython-root.0/store -name python3.11 -path "*/bin/python3.11" 2>/dev/null | head -1)
if [ -n "$VPYTHON3" ] && [ -x "$VPYTHON3" ]; then
  ln -sf "$VPYTHON3" /usr/local/bin/python3
  ln -sf "$VPYTHON3" /usr/local/bin/python
  ln -sf "$VPYTHON3" /usr/bin/python3
  echo "Linked Python 3.11 from vpython cache: $VPYTHON3"
  python3 --version
else
  echo "WARNING: Python 3.11 not found in vpython cache — build may fail on type|type syntax"
fi

# =============================================================================
# 6. Download pre-built LLVM/Clang (SIMPLIFIED — no bootstrap needed!)
# =============================================================================
echo ">>> Step 6: Download pre-built LLVM/Clang toolchain"
cd /root/chromium/src
python3 tools/clang/scripts/update.py

# Verify clang is present
if [ ! -f "third_party/llvm-build/Release+Asserts/bin/clang" ]; then
  echo "ERROR: Pre-built clang not found!"
  exit 1
fi
echo "Pre-built clang installed successfully"

# Copy libclang.so into rust-toolchain lib for bindgen
LLVM_LIB=/root/chromium/src/third_party/llvm-build/Release+Asserts/lib
mkdir -p /root/chromium/src/third_party/rust-toolchain/lib
cp -P "$LLVM_LIB"/libclang.so* /root/chromium/src/third_party/rust-toolchain/lib/ 2>/dev/null || true
export LIBCLANG_PATH=/root/chromium/src/third_party/rust-toolchain/lib

# =============================================================================
# 7. Install Node.js x86_64 (if not already correct)
# =============================================================================
echo ">>> Step 7: Verify/Install Node.js x86_64"
cd /root/chromium/src

# Check if the bundled Node.js works
if third_party/node/linux/node-linux-x64/bin/node --version 2>/dev/null; then
  echo "Bundled Node.js works"
else
  # Replace with known working Node.js v24.11.1 x64
  echo "Installing Node.js v24.11.1 x64..."
  cd /root/chromium/src/third_party/node/linux
  rm -rf node-linux-x64
  NODE_VERSION="v24.11.1"
  wget -q "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.gz" -O node-x64.tar.gz
  tar xzf node-x64.tar.gz
  mv "node-${NODE_VERSION}-linux-x64" node-linux-x64
  rm -f node-x64.tar.gz
fi

# =============================================================================
# 8. Install Java (same as ARM64 but x64 version)
# =============================================================================
echo ">>> Step 8: Install Java x86_64"
cd /root
if [ ! -d "/root/chromium/src/third_party/jdk/current/bin" ]; then
  rm -rf /root/chromium/src/third_party/jdk/current
  wget -q https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.15%2B10/OpenJDK11U-jre_x64_linux_hotspot_11.0.15_10.tar.gz
  tar zxf OpenJDK11U-jre_x64_linux_hotspot_11.0.15_10.tar.gz
  mv jdk-11.0.15+10-jre /root/chromium/src/third_party/jdk/current
  echo "Java installed"
else
  echo "Java already present"
fi

# =============================================================================
# 9. Build Ninja from source
# =============================================================================
echo ">>> Step 9: Build and install Ninja"

cd /root
git clone https://github.com/ninja-build/ninja.git -b v1.8.2
cd ninja
./configure.py --bootstrap
rm -f /root/depot_tools/ninja
ln -s /root/ninja/ninja /root/depot_tools/ninja

# =============================================================================
# 10. Set up build output directory
# =============================================================================
echo ">>> Step 10: Set up build directory"
mkdir -p /root/chromium/src/out/Headless
cp /root/args.gn /root/chromium/src/out/Headless/args.gn

# =============================================================================
# 11. Apply compatibility patches (same as ARM64)
# =============================================================================
echo ">>> Step 11: Apply compatibility patches"
cd /root/chromium/src

# fcntl.h seals — check if already defined
if ! grep -q 'F_LINUX_SPECIFIC_BASE' /usr/include/fcntl.h 2>/dev/null; then
  echo '#ifndef F_LINUX_SPECIFIC_BASE' >> /usr/include/fcntl.h
  echo '#define F_LINUX_SPECIFIC_BASE 1024' >> /usr/include/fcntl.h
  echo '#endif' >> /usr/include/fcntl.h
  echo '#define F_ADD_SEALS (F_LINUX_SPECIFIC_BASE + 9)' >> /usr/include/fcntl.h
  echo '#define F_GET_SEALS (F_LINUX_SPECIFIC_BASE + 10)' >> /usr/include/fcntl.h
  echo '#define F_SEAL_SEAL 0x0001' >> /usr/include/fcntl.h
  echo '#define F_SEAL_SHRINK 0x0002' >> /usr/include/fcntl.h
  echo '#define F_SEAL_GROW 0x0004' >> /usr/include/fcntl.h
  echo '#define F_SEAL_FUTURE_WRITE 0x0010' >> /usr/include/fcntl.h
  echo "Patched fcntl.h"
else
  echo "fcntl.h already has F_LINUX_SPECIFIC_BASE — no patch needed"
fi

# MFD_CLOEXEC for V8 — check if already defined
if [ -f /root/chromium/src/v8/src/base/platform/platform-posix.cc ]; then
  if ! grep -q 'MFD_CLOEXEC' /root/chromium/src/v8/src/base/platform/platform-posix.cc; then
    sed -i '1i#define MFD_CLOEXEC 0x0001U' /root/chromium/src/v8/src/base/platform/platform-posix.cc
    echo "Patched platform-posix.cc with MFD_CLOEXEC"
  else
    echo "MFD_CLOEXEC already defined — no patch needed"
  fi
fi

# Disable GPU DRI config references
for gn_file in content/gpu/BUILD.gn media/gpu/sandbox/BUILD.gn; do
  if [ -f "$gn_file" ] && grep -q '//build/config/linux/dri' "$gn_file"; then
    sed -i 's/configs += \[ "\/\/build\/config\/linux\/dri" \]/    configs += []/g' "$gn_file"
    echo "Patched DRI config in $gn_file"
  fi
done

# =============================================================================
# 12. Install Rust nightly matching Chromium's expected version
# =============================================================================
echo ">>> Step 12: Install Rust"
cd /root/chromium/src

RUST_VERSION_FILE="third_party/rust-toolchain/VERSION"
if [ -f "$RUST_VERSION_FILE" ]; then
  RUST_HASH=$(cat "$RUST_VERSION_FILE" | head -1)
  echo "Chromium expects Rust toolchain: $RUST_HASH"
fi

rm -f ./third_party/rust-toolchain/bin/rustc 2>/dev/null || true
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# Use nightly-2025-11-12 — matches Chromium 144's custom rustc (Nov 11, 2025 commit)
RUST_NIGHTLY="nightly-2025-11-12"
echo "Using Rust $RUST_NIGHTLY"
rustup install "$RUST_NIGHTLY"
rustup default "$RUST_NIGHTLY"

# IMPORTANT: Use actual binary path, not rustup proxy
RUSTC_ACTUAL=$(rustup which rustc)
ln -sf "$RUSTC_ACTUAL" ./third_party/rust-toolchain/bin/rustc

# Install bindgen and rustfmt
cargo install bindgen-cli 2>/dev/null || cargo install bindgen-cli --version 0.71.1
RUSTFMT_ACTUAL=$(rustup which rustfmt 2>/dev/null || which rustfmt)
ln -sf "$(which bindgen)" ./third_party/rust-toolchain/bin/bindgen
ln -sf "$RUSTFMT_ACTUAL" ./third_party/rust-toolchain/bin/rustfmt

# =============================================================================
# 13. Fix GCC paths (Amazon Linux x64)
# =============================================================================
echo ">>> Step 13: Fix GCC paths"

# Amazon Linux uses x86_64-amazon-linux triplet; fallback to x86_64-redhat-linux
GCC_DIR=""
for triplet in x86_64-amazon-linux x86_64-redhat-linux; do
  if [ -d "/usr/lib/gcc/${triplet}" ]; then
    GCC_DIR=$(find /usr/lib/gcc/${triplet}/ -maxdepth 1 -type d | tail -1)
    break
  fi
done

if [ -n "$GCC_DIR" ] && [ -d "$GCC_DIR" ]; then
  export LIBRARY_PATH="${GCC_DIR}:${LIBRARY_PATH:-}"
  # Amazon Linux puts CRT objects in /usr/lib64/ (not /usr/lib/)
  ln -sf "${GCC_DIR}/crtbeginS.o" /usr/lib64/crtbeginS.o
  ln -sf "${GCC_DIR}/crtendS.o" /usr/lib64/crtendS.o
  echo "Linked GCC CRT objects from $GCC_DIR to /usr/lib64/"
else
  echo "WARNING: Could not find GCC directory"
fi

# =============================================================================
# 14. Generate build files and compile
# =============================================================================
echo ">>> Step 14: gn gen + autoninja"
cd /root/chromium/src

# depot_tools Python path fix — point to vpython3 Python 3.11
mkdir -p /root/depot_tools/.cipd_bin
ln -sf /usr/local/bin/python3 /root/depot_tools/.cipd_bin/python3
echo ".cipd_bin" > /root/depot_tools/python3_bin_reldir.txt

export LIBCLANG_PATH=/root/chromium/src/third_party/rust-toolchain/lib
export LD_LIBRARY_PATH="${LIBCLANG_PATH}:${LD_LIBRARY_PATH:-}"

gn gen out/Headless
autoninja -C out/Headless headless_shell

# =============================================================================
# 15. Strip binaries and create chromium.zip
# =============================================================================
echo ">>> Step 15: Strip and package"
cd /root/chromium/src

# Strip build-output binaries
for bin in out/Headless/headless_shell out/Headless/libEGL.so out/Headless/libGLESv2.so \
           out/Headless/libvk_swiftshader.so out/Headless/libvulkan.so.1; do
  if [ -f "$bin" ]; then
    strip "$bin"
  fi
done

# Package into a self-contained directory with system libs bundled
OUTPUT_DIR="chromium-headless-shell-amazon-linux2023-x64"
mkdir -p "final/${OUTPUT_DIR}"
cp out/Headless/headless_shell "final/${OUTPUT_DIR}/"
cp out/Headless/libEGL.so "final/${OUTPUT_DIR}/"
cp out/Headless/libGLESv2.so "final/${OUTPUT_DIR}/"
cp out/Headless/libvk_swiftshader.so "final/${OUTPUT_DIR}/"
cp out/Headless/libvulkan.so.1 "final/${OUTPUT_DIR}/"
cp out/Headless/vk_swiftshader_icd.json "final/${OUTPUT_DIR}/"

# Bundle system shared libraries needed at runtime on Amazon Linux
for lib in libnss3.so libnssutil3.so libsoftokn3.so libnspr4.so libexpat.so.1 \
           libplc4.so libplds4.so libfreebl3.so libfreeblpriv3.so \
           libdbus-1.so.3 libsystemd.so.0; do
  if [ -f "/lib64/$lib" ]; then
    cp "/lib64/$lib" "final/${OUTPUT_DIR}/$lib"
  elif [ -f "/usr/lib64/$lib" ]; then
    cp "/usr/lib64/$lib" "final/${OUTPUT_DIR}/$lib"
  else
    echo "WARNING: $lib not found in /lib64/ or /usr/lib64/, skipping"
  fi
done

# Bundle libgcc_s (filename includes version, use glob)
for lib in /lib64/libgcc_s*.so.1 /usr/lib64/libgcc_s*.so.1; do
  if [ -f "$lib" ]; then
    cp "$lib" "final/${OUTPUT_DIR}/"
    echo "Bundled $(basename "$lib")"
    break
  fi
done

cd final
zip -r chromium-headless-shell-amazon-linux2023-x64.zip "${OUTPUT_DIR}"

echo ""
echo "========================================="
echo "BUILD COMPLETE!"
echo "Output: /root/chromium/src/final/chromium-headless-shell-amazon-linux2023-x64.zip"
echo "========================================="
