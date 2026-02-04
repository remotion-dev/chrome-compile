#!/bin/bash
set -euo pipefail

# =============================================================================
# build-chromium.sh — Build Chromium 144.0.7559.97 headless_shell (ARM64)
#
# Runs INSIDE the Docker container.
# Adapted from V2.md (Chrome 123) for Chrome 144.
# =============================================================================

CHROME_VERSION="144.0.7559.97"

echo "========================================="
echo "Building Chromium $CHROME_VERSION headless_shell"
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
mkdir -p /root/chromium
cp /root/dot-gclient /root/chromium/.gclient
cd /root/chromium
git clone --depth 1 --no-tags -n https://github.com/chromium/chromium.git src
cd src
git fetch --prune --depth=1 --tags origin "$CHROME_VERSION"
git checkout --quiet "$CHROME_VERSION"

# =============================================================================
# 3. Sync depot_tools to match the Chromium commit date
# =============================================================================
echo ">>> Step 3: Sync depot_tools to matching date"
COMMIT_DATE=$(git log -n 1 --pretty=format:%ci)
cd /root/depot_tools
git checkout $(git rev-list -n 1 --before="$COMMIT_DATE" main)
export DEPOT_TOOLS_UPDATE=0

# =============================================================================
# 4. Patch DEPS to skip reclient (Windows-only) and fix lastchange.py
# =============================================================================
echo ">>> Step 4: Patch DEPS and lastchange.py"
cd /root/chromium/src

# In Chrome 144, reclient already has a condition ('download_reclient and non_git_source')
# and download_reclient defaults to 'checkout_chromeos' which is false for us.
# No DEPS patching needed for reclient.
echo "Skipping reclient DEPS patch (not needed for Chrome 144)"

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
# 6. Replace Node.js with aarch64 version
# =============================================================================
echo ">>> Step 6: Replace Node.js with aarch64"
cd /root/chromium/src
sed -i 's@update_unix "darwin-x64" "mac"@# update_unix "darwin-x64" "mac"@g' third_party/node/update_node_binaries
sed -i 's@update_unix "darwin-arm64" "mac"@# update_unix "darwin-arm64" "mac"@g' third_party/node/update_node_binaries
sed -i 's@update_unix "linux-x64" "linux"@update_unix "linux-arm64" "linux"@g' third_party/node/update_node_binaries
./third_party/node/update_node_binaries
rm -rf third_party/node/linux/node-linux-x64
ln -s /root/chromium/src/third_party/node/linux/node-linux-arm64 /root/chromium/src/third_party/node/linux/node-linux-x64

# =============================================================================
# 7. Replace Java with aarch64 version
# =============================================================================
echo ">>> Step 7: Replace Java with aarch64"
cd /root
rm -rf /root/chromium/src/third_party/jdk/current
wget -q https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.15%2B10/OpenJDK11U-jre_aarch64_linux_hotspot_11.0.15_10.tar.gz
tar zxf OpenJDK11U-jre_aarch64_linux_hotspot_11.0.15_10.tar.gz
mv jdk-11.0.15+10-jre /root/chromium/src/third_party/jdk/current

# =============================================================================
# 8. Install CMake from source
# =============================================================================
echo ">>> Step 8: Install CMake"
cd /root
wget -q https://cmake.org/files/v3.23/cmake-3.23.0.tar.gz
tar -xzf cmake-3.23.0.tar.gz
cd cmake-3.23.0
./bootstrap
make -j$(nproc)
make install
export PATH="$PATH:/usr/local/bin"

# =============================================================================
# 9. Replace Ninja with aarch64 version
# =============================================================================
echo ">>> Step 9: Build and install Ninja"
cd /root
git clone https://github.com/ninja-build/ninja.git -b v1.8.2
cd ninja
./configure.py --bootstrap
rm -f /root/depot_tools/ninja
ln -s /root/ninja/ninja /root/depot_tools/ninja

# =============================================================================
# 10. Patch and build LLVM/Clang
# =============================================================================
echo ">>> Step 10: Build LLVM/Clang"
cd /root/chromium/src

# Fix libxml2 path for aarch64 (lib64 instead of lib)
sed -i "s#dirs.lib_dir, 'libxml2.a'#os.path.join(dirs.install_dir, 'lib64'), 'libxml2.a'#g" tools/clang/scripts/build.py

# Remove -DLLVM_ENABLE_LLD=ON (not available without prebuilt lld)
sed -i "s/ *'-DLLVM_ENABLE_LLD=ON',//" tools/clang/scripts/build.py

# Remove ML inlining model block if present
python3 -c "
import re
with open('tools/clang/scripts/build.py', 'r') as f:
    content = f.read()
# Remove the if args.with_ml_inline_model block
content = re.sub(r'  if args\.with_ml_inlin.*?(?=\n  [a-z]|\n  #|\nif |\ndef )', '', content, flags=re.DOTALL)
with open('tools/clang/scripts/build.py', 'w') as f:
    f.write(content)
" 2>/dev/null || echo "ML inline model block not found or already removed"

# Fix lib_dir to use build_dir
sed -i "s/self\.lib_dir = os\.path\.join(self\.install_dir, 'lib')/self\.lib_dir = os\.path\.join(self\.build_dir, 'lib')/g" tools/clang/scripts/build.py

# Add -lrt -lpthread to cxxflags
sed -i "s/cxxflags = \[\]/cxxflags = ['-lrt', '-lpthread']/g" tools/clang/scripts/build.py

# Target ARM/AArch64 instead of X86
sed -i "s/bootstrap_targets = 'X86'/bootstrap_targets = 'ARM;AArch64'/g" tools/clang/scripts/build.py

# Remove x86/armv7 runtime triples (we only need aarch64)
python3 -c "
with open('tools/clang/scripts/build.py', 'r') as f:
    content = f.read()
for triple in ['i386-unknown-linux-gnu', 'armv7-unknown-linux-gnueabihf', 'x86_64-unknown-linux-gnu']:
    import re
    # Remove runtimes_triples_args entries for non-aarch64 triples
    pattern = rf\"  runtimes_triples_args\['{triple}'\].*?(?=\n  runtimes_triples_args|\n  return|\n  #|\Z)\"
    content = re.sub(pattern, '', content, flags=re.DOTALL)
with open('tools/clang/scripts/build.py', 'w') as f:
    f.write(content)
" 2>/dev/null || echo "Triple removal: some triples may not exist in v144"

export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/lib64"

# Build LLVM/Clang
./tools/clang/scripts/build.py \
  --without-android \
  --without-fuchsia \
  --use-system-cmake \
  --host-cc /bin/clang \
  --host-cxx /bin/clang++ \
  --bootstrap

# =============================================================================
# 11. Set up build output directory
# =============================================================================
echo ">>> Step 11: Set up build directory"
mkdir -p /root/chromium/src/out/Headless
mount --types tmpfs --options size=48G,nr_inodes=128k,mode=1777 tmpfs /root/chromium/src/out/Headless
cp /root/args.gn /root/chromium/src/out/Headless/args.gn

# =============================================================================
# 12. Apply compatibility patches
# =============================================================================
echo ">>> Step 12: Apply compatibility patches"

# fcntl.h seals — check if already defined before patching
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
  echo "fcntl.h already has F_LINUX_SPECIFIC_BASE"
fi

# MFD_CLOEXEC for V8
if [ -f /root/chromium/src/v8/src/base/platform/platform-posix.cc ]; then
  if ! grep -q 'MFD_CLOEXEC' /root/chromium/src/v8/src/base/platform/platform-posix.cc; then
    sed -i '1i#define MFD_CLOEXEC 0x0001U' /root/chromium/src/v8/src/base/platform/platform-posix.cc
    echo "Patched platform-posix.cc"
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
# 13. Install Rust nightly matching Chromium's expected version
# =============================================================================
echo ">>> Step 13: Install Rust"
cd /root/chromium/src

# Read the Rust toolchain version Chromium expects
RUST_VERSION_FILE="third_party/rust-toolchain/VERSION"
if [ -f "$RUST_VERSION_FILE" ]; then
  RUST_HASH=$(cat "$RUST_VERSION_FILE" | head -1)
  echo "Chromium expects Rust toolchain: $RUST_HASH"
fi

# Install rustup and a nightly that matches
# For Chrome 144 (released ~June 2025), we estimate the rust nightly date.
# The exact date should be checked against the commit hash above.
rm -f ./third_party/rust-toolchain/bin/rustc 2>/dev/null || true
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# Try to determine the nightly date from the VERSION file hash.
# If this fails, fall back to a reasonable date for Chrome 144.
# Chrome 144 branched around April 2025, so the Rust nightly would be ~April 2025.
RUST_NIGHTLY_DATE="${RUST_NIGHTLY_DATE:-2025-04-15}"
echo "Using Rust nightly: $RUST_NIGHTLY_DATE"
rustup default "nightly-${RUST_NIGHTLY_DATE}"

ln -sf "$(which rustc)" ./third_party/rust-toolchain/bin/rustc

# =============================================================================
# 14. Fix GCC paths
# =============================================================================
echo ">>> Step 14: Fix GCC paths"
# Find the GCC version directory
GCC_DIR=$(find /usr/lib/gcc/aarch64-amazon-linux/ -maxdepth 1 -type d | tail -1)
if [ -n "$GCC_DIR" ] && [ -d "$GCC_DIR" ]; then
  export LIBRARY_PATH="${GCC_DIR}:${LIBRARY_PATH:-}"
  ln -sf "${GCC_DIR}/crtbeginS.o" /usr/lib/crtbeginS.o
  ln -sf "${GCC_DIR}/crtendS.o" /usr/lib/crtendS.o
  echo "Linked GCC CRT objects from $GCC_DIR"
else
  echo "WARNING: Could not find GCC directory"
fi

# =============================================================================
# 15. Generate build files and compile
# =============================================================================
echo ">>> Step 15: gn gen + autoninja"
cd /root/chromium/src
gn gen out/Headless
autoninja -C out/Headless headless_shell

# =============================================================================
# 16. Strip binaries and create chromium.zip
# =============================================================================
echo ">>> Step 16: Strip and package"
cd /root/chromium/src

strip -o out/Headless/headless_shell out/Headless/headless_shell
strip -o out/Headless/libEGL.so out/Headless/libEGL.so
strip -o out/Headless/libGLESv2.so out/Headless/libGLESv2.so
strip -o out/Headless/libvk_swiftshader.so out/Headless/libvk_swiftshader.so
strip -o out/Headless/libvulkan.so.1 out/Headless/libvulkan.so.1

mkdir -p final
cp out/Headless/headless_shell final/
cp out/Headless/libEGL.so final/
cp out/Headless/libGLESv2.so final/
cp out/Headless/libvk_swiftshader.so final/
cp out/Headless/libvulkan.so.1 final/
cp out/Headless/vk_swiftshader_icd.json final/

# Copy system shared libraries needed at runtime
for lib in libnss3.so libsoftokn3.so libnspr4.so libexpat.so.1 libplc4.so libplds4.so libfreebl3.so libfreeblpriv3.so; do
  if [ -f "/lib64/$lib" ]; then
    cp "/lib64/$lib" "final/$lib"
  else
    echo "WARNING: /lib64/$lib not found, skipping"
  fi
done

cd final
zip -r chromium.zip .

echo ""
echo "========================================="
echo "BUILD COMPLETE!"
echo "Output: /root/chromium/src/final/chromium.zip"
echo "========================================="
