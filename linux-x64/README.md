# Building Chromium 144 headless_shell for x86_64 Linux

This guide documents how to build Chromium 144.0.7559.97 `headless_shell` for x86_64 targeting Debian/Ubuntu Linux, with proprietary codecs enabled.

## Overview

- **Target**: x86_64 Linux (Debian 12 / Ubuntu 22.04+)
- **Output**: `chromium-headless-shell-linux64.zip` containing `headless_shell` and supporting libraries
- **Build time**: ~1 hour on c6i.8xlarge (32 x86_64 vCPUs)
- **Build environment**: Ubuntu 22.04 in Docker on AWS Intel

## Why x86_64 is Simpler than ARM64

| Aspect | ARM64 Build | x86_64 Build |
|--------|-------------|--------------|
| LLVM toolchain | Must bootstrap from source (~2 hours) | Pre-built available via `update.py` |
| Bootstrap targets patch | Required (`ARM;AArch64` instead of `X86`) | Not needed |
| PIC patches | Required for shared libs | Not needed |
| System llvm-readelf | Required (multicall workaround) | Not needed |
| compiler-rt builtins | Must build separately | Included in pre-built |
| Build time | ~1h46m | ~1 hour |

## Prerequisites

### AWS Infrastructure
- **Instance**: c6i.8xlarge (32 x86_64 vCPU, 64 GiB RAM, Intel)
- **Storage**: 200 GiB gp3
- **Region**: eu-central-1 (or any region with Intel instances)
- **OS**: Amazon Linux 2023 (host) with Docker

### Required Files

1. **`.env`** - AWS credentials
2. **`.gclient`** - gclient configuration
3. **`args-x86.gn`** - GN build configuration for x86_64
4. **`Dockerfile-x86`** - Ubuntu 22.04 build environment
5. **`build-chromium-x86.sh`** - Main build script (simplified)

## Build Configuration

### args-x86.gn

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
target_cpu = "x64"
target_os = "linux"
use_cups = false
use_pulseaudio = false
v8_target_cpu = "x64"

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

**Key differences from ARM64:**
- `target_cpu = "x64"` (instead of `arm64`)
- `v8_target_cpu = "x64"` (instead of `arm64`)

### .gclient

```python
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "deps_file": "DEPS",
    "custom_deps": {},
    "custom_vars": {
      "checkout_nacl": False,
      "checkout_configuration": "small",
      "checkout_js_coverage_modules": False,
      "checkout_fuchsia_boot_images": ""
    },
  }
]
```

## Build Process (Single Phase)

Unlike ARM64 (which requires multi-phase builds with LLVM bootstrap), x86_64 can be built in a single phase since pre-built LLVM/Clang is available.

### Quick Start

```bash
# 1. Launch EC2 instance
./launch-ec2-x86.sh

# 2. SSH to instance
ssh -i chrome-build-key-x86.pem ec2-user@<PUBLIC_IP>
sudo -i

# 3. Upload files
# (from local machine)
scp -i chrome-build-key-x86.pem setup-ec2-x86.sh Dockerfile-x86 build-chromium-x86.sh .gclient args-x86.gn ec2-user@<IP>:/home/ec2-user/
# Then on EC2: sudo mv /home/ec2-user/* /root/

# 4. Run build
bash setup-ec2-x86.sh

# 5. Download result
# (from local machine)
scp -i chrome-build-key-x86.pem ec2-user@<IP>:/root/chromium-headless-shell-linux64.zip .
```

### Build Steps (Detailed)

The `build-chromium-x86.sh` script performs these steps:

1. **Install depot_tools** — Chromium's build tooling
2. **Clone Chromium** — Shallow clone of version 144.0.7559.97
3. **Sync depot_tools** — Match depot_tools to Chromium commit date
4. **Patch lastchange.py** — Fix git log format quoting
5. **gclient sync** — Download all dependencies
6. **Download pre-built LLVM/Clang** — `python3 tools/clang/scripts/update.py` (NO bootstrap needed!)
7. **Verify Node.js** — Use bundled x64 Node.js or install if needed
8. **Install Java** — x86_64 JRE for build tools
9. **Build Ninja** — From source for reliability
10. **Set up build directory** — Copy args-x86.gn
11. **Apply compatibility patches** — fcntl.h, MFD_CLOEXEC, DRI config
12. **Install Rust** — nightly-2025-11-12 with bindgen
13. **Fix GCC paths** — Link CRT objects
14. **gn gen + autoninja** — Generate and build (~1 hour)
15. **Strip and package** — Create chromium-headless-shell-linux64.zip

### Key Simplifications vs ARM64

The x86_64 build skips these ARM64-specific steps:

- **No LLVM bootstrap** — Pre-built clang available via `update.py`
- **No PIC patches** — x86_64 doesn't need position-independent code workarounds
- **No compiler-rt build** — Builtins included in pre-built toolchain
- **No llvm-readelf workaround** — Pre-built has all required tools
- **No ARM triplet removal** — Default targets are x86_64
- **No bootstrap_targets patch** — Default is already X86

## Output

`chromium-headless-shell-linux64.zip` containing:
```
chrome-linux/
├── headless_shell        (~174MB stripped)
├── libEGL.so             (~256KB)
├── libGLESv2.so          (~5.1MB)
├── libvk_swiftshader.so  (~16MB)
├── libvulkan.so.1        (~633KB)
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
unzip chromium-headless-shell-linux64.zip
./chrome-linux/headless_shell --no-sandbox --headless --dump-dom https://example.com
```

Expected output: HTML content of example.com

## Common Build Errors and Fixes

### 1. `update.py` fails to download clang

**Cause**: Network issues or Google storage access.
**Fix**: Retry, or check if corporate firewall blocks `commondatastorage.googleapis.com`.

### 2. `SKIA_USE_DAWN used without USE_DAWN`

**Cause**: `use_dawn = false` but Skia Dawn not disabled.
**Fix**: Ensure `skia_use_dawn = false` is in args-x86.gn.

### 3. `enable_extensions = false` causes GN errors

**Cause**: headless_shell depends on controlled_frame which requires extensions.
**Fix**: Do NOT set `enable_extensions = false` or `enable_platform_apps = false`.

### 4. Missing clang plugins (find-bad-constructs, raw-ptr-plugin)

**Cause**: Pre-built clang doesn't include Chrome-specific plugins.
**Fix**: Ensure `clang_use_chrome_plugins = false` is in args-x86.gn.

### 5. `python` not found

**Cause**: Ubuntu 22.04 has `python3` but not `python`.
**Fix**: The build script handles this via depot_tools Python path fix.

### 6. Git cherry-pick fails during dependency checkout

**Cause**: No git identity configured.
**Fix**: The gclient sync should handle this, but if not:
```bash
git config --global user.email "build@localhost"
git config --global user.name "Build"
```

## Files in This Directory

### x86_64 Build Files
- `args-x86.gn` — GN build configuration for x86_64
- `Dockerfile-x86` — Ubuntu 22.04 build environment (x86_64)
- `launch-ec2-x86.sh` — Launch x86_64 EC2 instance
- `setup-ec2-x86.sh` — Setup script for x86_64 EC2 host
- `build-chromium-x86.sh` — Simplified build script (15 steps)
- `BUILD-GUIDE-X86.md` — This documentation

### ARM64 Build Files (for reference)
- `args.gn` — GN build configuration for ARM64
- `Dockerfile` — Ubuntu 22.04 build environment (ARM64)
- `launch-ec2.sh` — Launch ARM64 EC2 instance
- `setup-ec2.sh` — Setup script for ARM64 EC2 host
- `build-chromium.sh` — Full build script with LLVM bootstrap (16 steps)
- `BUILD-GUIDE.md` — ARM64 documentation

### Shared Files
- `.gclient` — gclient configuration (same for both architectures)
- `.env` — AWS credentials

## Comparison: ARM64 vs x86_64

| Aspect | ARM64 | x86_64 |
|--------|-------|--------|
| Instance type | c7g.8xlarge (Graviton3) | c6i.8xlarge (Intel) |
| LLVM setup | Bootstrap from source | Download pre-built |
| Build time | ~1h46m | ~1 hour |
| Build script steps | 16 (including LLVM patches) | 15 (simplified) |
| Output file | chromium-headless-shell-linux-arm64.zip | chromium-headless-shell-linux64.zip |
| target_cpu | arm64 | x64 |
| Complexity | High (many patches required) | Low (mostly automated) |

## Cost Estimate

- **c6i.8xlarge**: ~$1.36/hour (on-demand, eu-central-1)
- **Build time**: ~1 hour
- **Storage**: 200 GiB gp3 (~$0.08/GB-month)
- **Total per build**: ~$1.50-2.00

Tip: Use spot instances for ~70% savings if build interruption is acceptable.
