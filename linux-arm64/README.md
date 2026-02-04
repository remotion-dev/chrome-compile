# Building Chromium 144 headless_shell for ARM64 Linux

This guide documents how to build Chromium 144.0.7559.97 `headless_shell` for ARM64 targeting Debian/Ubuntu Linux, with proprietary codecs enabled.

## Overview

- **Target**: ARM64 Linux (Debian 12 / Ubuntu 22.04+)
- **Output**: `chromium-headless-shell-linux-arm64.zip` (~84MB) containing `headless_shell` and supporting libraries
- **Build time**: ~1h46m on c7g.8xlarge (32 ARM64 vCPUs)
- **Build environment**: Ubuntu 22.04 in Docker on AWS Graviton3

## Prerequisites

### AWS Infrastructure
- **Instance**: c7g.8xlarge (32 ARM64 vCPU, 64 GiB RAM, Graviton3)
- **Storage**: 200 GiB gp3
- **Region**: eu-central-1 (or any region with Graviton3)
- **OS**: Amazon Linux 2023 (host) with Docker

### Required Files

1. **`.env`** - AWS credentials
2. **`.gclient`** - gclient configuration
3. **`args.gn`** - GN build configuration
4. **`Dockerfile`** - Ubuntu 22.04 build environment
5. **Build scripts** (phase1.sh, phase2-llvm-v2.sh, phase3-build.sh, etc.)

## Build Configuration

### args.gn

```gn
import("//build/args/headless.gn")
dcheck_always_on = false
is_official_build = true
symbol_level = 0
blink_symbol_level = 0
v8_symbol_level = 0
enable_keystone_registration_framework = false
enable_linux_installer = false
enable_media_remoting = false

enable_swiftshader_vulkan = false

ffmpeg_branding = "Chrome"
headless_use_embedded_resources = true
icu_use_data_file = false

is_debug = false
proprietary_codecs = true
target_cpu = "arm64"
target_os = "linux"
use_cups = false
use_pulseaudio = false
v8_target_cpu = "arm64"

chrome_pgo_phase = 0
enable_background_mode = false
enable_captive_portal_detection = false
enable_chrome_notifications = false

use_sysroot = false
use_qt = false

use_on_device_model_service = false
enable_print_preview = false
enable_lens_desktop = false
use_dawn = false
skia_use_dawn = false
enable_pdf = false
enable_printing = false
enable_compose = false
enable_glic = false
enable_mdns = false
enable_service_discovery = false
enable_click_to_call = false
enable_bound_session_credentials = false
enable_device_bound_sessions = false
clang_use_chrome_plugins = false
```

**Key flags explained:**
- `proprietary_codecs = true` + `ffmpeg_branding = "Chrome"` — Enable H.264/AAC
- `headless_use_embedded_resources = true` — Embed .pak resources into binary
- `icu_use_data_file = false` — Embed ICU data into binary
- `use_sysroot = false` — Use system libraries instead of Chromium's sysroot
- `use_dawn = false` + `skia_use_dawn = false` — Disable Dawn/WebGPU (causes build errors otherwise)
- `clang_use_chrome_plugins = false` — Bootstrap clang doesn't have Chrome plugins

**Flags that MUST NOT be set:**
- `enable_extensions = false` — Breaks build graph (headless_shell needs controlled_frame)
- `enable_platform_apps = false` — Same issue

### .gclient

```python
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git@144.0.7559.97",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {
      "checkout_nacl": False,
      "checkout_configuration": "small",
    },
  },
]
```

## Build Process (3 Phases)

The build is split into phases with Docker commits between each to preserve state and allow recovery from failures.

### Phase 1: Setup and Sync (~2-3 hours)

1. Install depot_tools
2. Clone Chromium source
3. Run gclient sync
4. Install Node.js v24.11.1 arm64 (required for DevTools build)
5. Install Java (required for some build steps)
6. Build Ninja from source (Ubuntu's version is too old)

```bash
# Key commands
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git /root/depot_tools
export PATH="$PATH:/root/depot_tools"
export DEPOT_TOOLS_UPDATE=0

cd /root/chromium
cp /root/.gclient .gclient
gclient sync --no-history --shallow

# Node.js - must be v24+ for arm64
curl -fsSL https://nodejs.org/dist/v24.11.1/node-v24.11.1-linux-arm64.tar.gz | tar -xz -C /usr/local --strip-components=1

# Ninja from source
git clone https://github.com/nickvidal/nickninja.git /root/nickninja
cd /root/nickninja && ./configure.py --bootstrap && cp ninja /root/ninja/
```

**Docker commit:** `docker commit <container> chrome-builder-phase1`

### Phase 2: Build LLVM/Clang (~1-2 hours)

Chromium requires a specific LLVM/Clang version. The build script needs patches:

#### LLVM Build Patches (apply to tools/clang/scripts/build.py)

```python
# 1. Remove -DLLVM_ENABLE_LLD=ON (bootstrap can't use lld before it's built)
content = re.sub(r"\s*'-DLLVM_ENABLE_LLD=ON',", '', content)

# 2. Remove ML inlining model block
content = re.sub(r'  if args\.with_ml_inlin.*?(?=\n  [a-z]|\n  #|\nif |\ndef )', '', content, flags=re.DOTALL)

# 3. Add -lrt -lpthread to cxxflags
content = content.replace("cxxflags = []", "cxxflags = ['-lrt', '-lpthread']")

# 4. Target ARM/AArch64 for bootstrap (not X86)
content = content.replace("bootstrap_targets = 'X86'", "bootstrap_targets = 'ARM;AArch64'")

# 5. Enable PIC everywhere (required for shared libs)
content = content.replace("pic_default = sys.platform == 'win32'", "pic_default = True")

# 6. Add explicit PIC flags to final cmake
content = content.replace(
    "'-DCMAKE_INSTALL_PREFIX=' + final_install_dir,",
    "'-DCMAKE_INSTALL_PREFIX=' + final_install_dir,\n      '-DLLVM_ENABLE_PIC=ON',\n      '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',",
    1
)

# 7. Remove non-aarch64 runtime triples (i386, x86_64, armv7, riscv64)
# (Line-by-line processing to remove these from runtimes_triples_args)
```

```bash
# Git identity required for cherry-picks during LLVM checkout
git config --global user.email "build@localhost"
git config --global user.name "Build"

# Build LLVM
./tools/clang/scripts/build.py \
  --without-android \
  --without-fuchsia \
  --use-system-cmake \
  --host-cc /usr/bin/clang \
  --host-cxx /usr/bin/clang++ \
  --bootstrap || echo "Partial failure expected"
```

The LLVM build will partially fail (libclang-cpp.so linking fails) but produces usable clang, lld, and libclang.so.

#### Post-LLVM Setup

```bash
# Install bootstrap clang to expected location
BOOTSTRAP=/root/chromium/src/third_party/llvm-bootstrap
TARGET=/root/chromium/src/third_party/llvm-build/Release+Asserts

mkdir -p "$TARGET/bin" "$TARGET/lib" "$TARGET/lib/clang"

# Copy binaries
for bin in clang-22 lld llvm-ar llvm-objcopy llvm-objdump; do
  [ -f "$BOOTSTRAP/bin/$bin" ] && cp "$BOOTSTRAP/bin/$bin" "$TARGET/bin/"
done

# Create symlinks
cd "$TARGET/bin"
ln -sf clang-22 clang
ln -sf clang-22 clang++
ln -sf clang-22 clang-cl
ln -sf lld ld.lld
ln -sf lld ld64.lld
ln -sf lld lld-link
ln -sf lld wasm-ld
ln -sf llvm-ar llvm-ranlib
ln -sf llvm-objcopy llvm-strip

# IMPORTANT: Use system LLVM tools for readelf/nm (llvm-objcopy multicall doesn't support -d flag)
ln -sf /usr/bin/llvm-readelf-14 llvm-readelf
ln -sf /usr/bin/llvm-readobj-14 llvm-readobj
ln -sf /usr/bin/llvm-nm-14 llvm-nm
ln -sf /usr/bin/llvm-size-14 llvm-size

# Copy libraries
cp -P "$BOOTSTRAP/lib"/libclang.so* "$TARGET/lib/"
cp -P "$BOOTSTRAP/lib"/libLTO.so* "$TARGET/lib/"
cp -r "$BOOTSTRAP/lib/clang/"* "$TARGET/lib/clang/"

# libclang.so for bindgen
mkdir -p third_party/rust-toolchain/lib
cp -P "$TARGET/lib"/libclang.so* third_party/rust-toolchain/lib/

# cr_build_revision (must match expected format)
echo "llvmorg-22-init-14273-gea10026b-2" > "$TARGET/cr_build_revision"
```

#### Build compiler-rt builtins separately

```bash
cd /root/chromium/src/third_party/llvm/compiler-rt
mkdir -p build && cd build
cmake .. \
  -DCMAKE_C_COMPILER=/root/chromium/src/third_party/llvm-bootstrap/bin/clang \
  -DCMAKE_CXX_COMPILER=/root/chromium/src/third_party/llvm-bootstrap/bin/clang++ \
  -DCMAKE_BUILD_TYPE=Release \
  -DCOMPILER_RT_BUILD_BUILTINS=ON \
  -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
  -DCOMPILER_RT_BUILD_XRAY=OFF \
  -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
  -DCOMPILER_RT_BUILD_PROFILE=OFF \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  -DLLVM_CONFIG_PATH=/root/chromium/src/third_party/llvm-bootstrap/bin/llvm-config

ninja builtins
cp lib/linux/libclang_rt.builtins-aarch64.a \
   /root/chromium/src/third_party/llvm-build/Release+Asserts/lib/clang/22/lib/aarch64-unknown-linux-gnu/
```

**Docker commit:** `docker commit <container> chrome-builder-llvm-complete`

### Phase 3: Build Chromium (~1h46m)

```bash
# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
RUST_NIGHTLY="nightly-2025-11-12"
rustup install "$RUST_NIGHTLY"
rustup default "$RUST_NIGHTLY"

# Link rustc to expected location (use actual binary, not rustup proxy)
RUSTC_ACTUAL=$(rustup which rustc)
ln -sf "$RUSTC_ACTUAL" ./third_party/rust-toolchain/bin/rustc

# Install bindgen
cargo install bindgen-cli
ln -sf "$(which bindgen)" ./third_party/rust-toolchain/bin/bindgen
ln -sf "$(rustup which rustfmt)" ./third_party/rust-toolchain/bin/rustfmt

# depot_tools Python path fix
mkdir -p /root/depot_tools/.cipd_bin
ln -sf /usr/bin/python3 /root/depot_tools/.cipd_bin/python3
echo ".cipd_bin" > /root/depot_tools/python3_bin_reldir.txt

# Environment
export LIBCLANG_PATH=/root/chromium/src/third_party/rust-toolchain/lib
export LD_LIBRARY_PATH="${LIBCLANG_PATH}:${LD_LIBRARY_PATH:-}"

# Copy args.gn
mkdir -p out/Headless
cp /root/args.gn out/Headless/args.gn

# Generate build files and compile
gn gen out/Headless
autoninja -C out/Headless headless_shell

# Strip and package
for bin in out/Headless/headless_shell out/Headless/libEGL.so out/Headless/libGLESv2.so \
           out/Headless/libvk_swiftshader.so out/Headless/libvulkan.so.1; do
  [ -f "$bin" ] && strip "$bin"
done

mkdir -p final/chrome-linux
for f in headless_shell libEGL.so libGLESv2.so libvk_swiftshader.so libvulkan.so.1 vk_swiftshader_icd.json; do
  [ -f "out/Headless/$f" ] && cp "out/Headless/$f" final/chrome-linux/
done
cd final && zip -r chromium-headless-shell-linux-arm64.zip chrome-linux
```

## Output

`chromium-headless-shell-linux-arm64.zip` containing:
```
chrome-linux/
├── headless_shell        (174MB stripped)
├── libEGL.so             (256KB)
├── libGLESv2.so          (5.1MB)
├── libvk_swiftshader.so  (16MB)
├── libvulkan.so.1        (633KB)
└── vk_swiftshader_icd.json
```

## Target System Runtime Dependencies

```bash
sudo apt install -y libnss3 libnspr4 libexpat1 libdbus-1-3 libgbm1 \
  libasound2 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
  libxkbcommon0 libx11-6 libxcomposite1 libxdamage1 libxext6 \
  libxfixes3 libxrandr2 libpango-1.0-0 libcairo2 fonts-liberation
```

## Testing

```bash
unzip chromium-headless-shell-linux-arm64.zip
./chrome-linux/headless_shell --no-sandbox --headless --dump-dom https://example.com
```

## Common Build Errors and Fixes

### 1. `llvm-readelf: error: unknown argument '-d'`
**Cause**: `llvm-objcopy` multicall binary doesn't support readelf flags.
**Fix**: Use system LLVM tools:
```bash
ln -sf /usr/bin/llvm-readelf-14 third_party/llvm-build/Release+Asserts/bin/llvm-readelf
ln -sf /usr/bin/llvm-nm-14 third_party/llvm-build/Release+Asserts/bin/llvm-nm
```

### 2. `SKIA_USE_DAWN used without USE_DAWN`
**Cause**: `use_dawn = false` but Skia Dawn not disabled.
**Fix**: Add `skia_use_dawn = false` to args.gn.

### 3. `enable_extensions = false` causes GN errors
**Cause**: headless_shell depends on controlled_frame which requires extensions.
**Fix**: Do NOT set `enable_extensions = false` or `enable_platform_apps = false`.

### 4. Missing clang plugins (find-bad-constructs, raw-ptr-plugin)
**Cause**: Bootstrap clang doesn't include Chrome-specific plugins.
**Fix**: Add `clang_use_chrome_plugins = false` to args.gn.

### 5. `cr_build_revision` mismatch
**Cause**: Wrong LLVM version string.
**Fix**: Use exact format: `llvmorg-22-init-14273-gea10026b-2`

### 6. Git cherry-pick fails during LLVM checkout
**Cause**: No git identity configured.
**Fix**:
```bash
git config --global user.email "build@localhost"
git config --global user.name "Build"
```

### 7. `python` not found
**Cause**: Ubuntu 22.04 has `python3` but not `python`.
**Fix**: `ln -sf /usr/bin/python3 /usr/bin/python`

## Differences from Lambda Build

| Aspect | Lambda (AL2023) | Linux (Ubuntu 22.04) |
|--------|-----------------|----------------------|
| Base image | `public.ecr.aws/lambda/nodejs:24` | `ubuntu:22.04` |
| Package manager | dnf | apt |
| System libs in zip | Yes (libnss3, etc.) | No (apt install on target) |
| GCC triplet | `aarch64-amazon-linux` | `aarch64-linux-gnu` |
| Python fix | vpython 3.11 workaround | Not needed |
| CMake | Build from source | apt (3.22 sufficient) |

## Files in This Directory

- `args.gn` — GN build configuration
- `.gclient` — gclient configuration
- `Dockerfile` — Ubuntu 22.04 build environment
- `launch-ec2.sh` — Launch EC2 instance
- `setup-ec2.sh` — Setup script for EC2 host
- `build-chromium.sh` — Main build script (16 steps)
- `phase2-llvm-v2.sh` — LLVM build with all patches
- `phase2-llvm-install.sh` — Install bootstrap clang
- `phase3-build.sh` — Final build script
- `chromium-headless-shell-linux-arm64.zip` — Built output
