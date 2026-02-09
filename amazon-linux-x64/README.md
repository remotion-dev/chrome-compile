# Chromium 144 Headless Shell - Amazon Linux x64 Build Guide

Build Chromium 144.0.7559.97 `headless_shell` for Amazon Linux 2023 x86_64 inside a Docker container.

Output: `chromium-headless-shell-amazon-linux2023-x64.zip` (~95MB) containing `headless_shell` + bundled system libraries.

## Infrastructure

- **EC2**: c6i.8xlarge (32 x86_64 vCPU, 64 GiB RAM, Intel), 200 GiB gp3, eu-central-1
- **Docker base image**: `amazonlinux:2023`
- **Build time**: ~1h15m (single phase — pre-built LLVM, no bootstrap)

## Files

| File | Purpose |
|---|---|
| `launch-ec2.sh` | Provisions the EC2 instance (AMI lookup, key pair, security group) |
| `setup-ec2.sh` | Runs on EC2: installs Docker, builds image, runs build, extracts zip |
| `Dockerfile` | Build container with all system dependencies (AL2023) |
| `build-chromium.sh` | Main build script (runs inside container) |
| `args.gn` | Chromium GN build flags for headless x64 |
| `.gclient` | gclient config (copied as `dot-gclient` in Docker context) |
| `.env` | AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) |

## Quick Start

```bash
# 1. Launch EC2
./launch-ec2.sh

# 2. SCP files to EC2
scp -i chrome-build-key-al-x86.pem Dockerfile build-chromium.sh ../shared/.gclient args.gn setup-ec2.sh ec2-user@<IP>:/home/ec2-user/

# 3. SSH in and run
ssh -i chrome-build-key-al-x86.pem ec2-user@<IP>
sudo cp /home/ec2-user/* /root/
sudo mv /root/.gclient /root/dot-gclient
sudo bash /root/setup-ec2.sh

# 4. Copy result back
scp -i chrome-build-key-al-x86.pem ec2-user@<IP>:/root/chromium-headless-shell-amazon-linux2023-x64.zip .

# 5. Terminate instance (important!)
aws ec2 terminate-instances --instance-ids <instance-id> --region eu-central-1
```

## Key Differences from Linux x64 (Ubuntu) Build

### Python 3.9 → 3.11 Fix

Amazon Linux 2023 ships Python 3.9, but Chrome 144 build scripts use `type | type` union syntax (Python 3.10+). After `gclient sync`, the build replaces system Python with Python 3.11 from the vpython cache:

```bash
VPYTHON3=$(find /root/.cache/vpython-root.0/store -name python3.11 -path "*/bin/python3.11" | head -1)
ln -sf "$VPYTHON3" /usr/local/bin/python3 && ln -sf "$VPYTHON3" /usr/bin/python3
```

### GCC Triplet

Amazon Linux uses `x86_64-amazon-linux` (not `x86_64-linux-gnu`). CRT objects are symlinked into `/usr/lib64/` (not `/usr/lib/`):

```bash
GCC_DIR=$(find /usr/lib/gcc/x86_64-amazon-linux/ -maxdepth 1 -type d | tail -1)
ln -sf "${GCC_DIR}/crtbeginS.o" /usr/lib64/crtbeginS.o
ln -sf "${GCC_DIR}/crtendS.o" /usr/lib64/crtendS.o
```

### System Libraries Bundled

Unlike the Ubuntu x64 build (where users `apt install` deps), this build bundles system libraries for self-contained Amazon Linux deployment:

```
libnss3.so, libnssutil3.so, libsoftokn3.so, libnspr4.so, libexpat.so.1,
libplc4.so, libplds4.so, libfreebl3.so, libfreeblpriv3.so,
libdbus-1.so.3, libgcc_s*.so.1, libsystemd.so.0
```

### LLVM Toolchain

Pre-built LLVM download works on AL2023 x64 (glibc 2.34 is new enough). No bootstrap from source needed — same simplicity as the Ubuntu x64 build.

## Output Contents

The zip contains a `chromium-headless-shell-amazon-linux2023-x64/` directory with:

| File | Description |
|---|---|
| `headless_shell` | Chromium headless browser binary (stripped) |
| `libEGL.so` | EGL graphics |
| `libGLESv2.so` | OpenGL ES |
| `libvk_swiftshader.so` | Software Vulkan renderer |
| `libvulkan.so.1` | Vulkan loader |
| `vk_swiftshader_icd.json` | Vulkan ICD config |
| `libnss3.so` | NSS |
| `libnssutil3.so` | NSS utility |
| `libsoftokn3.so` | NSS soft token |
| `libnspr4.so` | NSPR |
| `libexpat.so.1` | XML parser |
| `libplc4.so` | NSPR utility |
| `libplds4.so` | NSPR data structures |
| `libfreebl3.so` | NSS crypto |
| `libfreeblpriv3.so` | NSS crypto (private) |
| `libdbus-1.so.3` | D-Bus IPC |
| `libgcc_s*.so.1` | GCC runtime |
| `libsystemd.so.0` | systemd integration |

## Testing

```bash
# Extract
unzip chromium-headless-shell-amazon-linux2023-x64.zip

# Run on Amazon Linux
cd chromium-headless-shell-amazon-linux2023-x64
LD_LIBRARY_PATH=. ./headless_shell --no-sandbox --headless --dump-dom https://example.com
```

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `unknown lang item: format_placeholder` | Wrong Rust nightly version | Use exactly `nightly-2025-11-12` |
| Python `type \| type` syntax error | Python 3.9 too old | Ensure vpython Python 3.11 fix ran (Step 5.5) |
| `crtbeginS.o: No such file` | Wrong GCC CRT path | Check GCC triplet — may be `x86_64-redhat-linux` instead |
| `KeyError: 'host'` in run_build_script.py | rustc symlink points to rustup proxy | Use `rustup which rustc` for actual binary path |
| Node.js version mismatch | Wrong Node.js for Chrome 144 | Download v24.11.1 x64 directly |
