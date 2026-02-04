# Chromium 144 Headless Shell - ARM64 Build Guide

Build Chromium 144.0.7559.97 `headless_shell` for ARM64 (aarch64) inside a Docker container based on the AWS Lambda Node.js 24 image (Amazon Linux 2023).

Output: `chromium.zip` (~88MB) containing `headless_shell` + shared libraries.

## Infrastructure

- **EC2**: c7g.8xlarge (32 ARM64 vCPU, 64 GiB RAM, Graviton3), 200 GiB gp3, eu-central-1
- **Docker base image**: `public.ecr.aws/lambda/nodejs:24.2026.01.26.23`
- **Build time**: ~4 hours total (steps 1-9 ~1.5h, LLVM ~30min, Chromium compile ~2h)

## Files

| File | Purpose |
|---|---|
| `launch-ec2.sh` | Provisions the EC2 instance (AMI lookup, key pair, security group) |
| `setup-ec2.sh` | Runs on EC2: installs Docker, builds image, runs build, extracts zip |
| `Dockerfile` | Build container with all system dependencies |
| `build-chromium.sh` | Main build script (runs inside container) - **has known issues, see below** |
| `args.gn` | Chromium GN build flags for headless ARM64 |
| `.gclient` | gclient config (copied as `dot-gclient` in Docker context) |
| `.env` | AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) |

## Quick Start (Ideal Path)

```bash
# 1. Launch EC2
./launch-ec2.sh

# 2. SCP files to EC2
scp -i chrome-build-key.pem Dockerfile build-chromium.sh .gclient args.gn setup-ec2.sh ec2-user@<IP>:/home/ec2-user/

# 3. SSH in and run
ssh -i chrome-build-key.pem ec2-user@<IP>
sudo cp /home/ec2-user/* /root/
sudo bash /root/setup-ec2.sh

# 4. Copy result back
scp -i chrome-build-key.pem ec2-user@<IP>:/root/chromium.zip .
```

## Critical Corrections to `build-chromium.sh`

The checked-in `build-chromium.sh` was the initial version. The actual successful build required numerous fixes discovered during the process. An agent executing this must apply all of the following corrections:

### Step 6: Node.js version

Chromium 144 expects Node.js **v24.11.1**, not whatever `update_node_binaries` fetches. After running the update script, replace with a direct download:

```bash
cd /root/chromium/src/third_party/node/linux
rm -rf node-linux-x64 node-linux-arm64
NODE_VERSION="v24.11.1"
wget -q "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-arm64.tar.gz" -O node-arm64.tar.gz
tar xzf node-arm64.tar.gz
mv "node-${NODE_VERSION}-linux-arm64" node-linux-arm64
ln -sf node-linux-arm64 node-linux-x64
rm -f node-arm64.tar.gz
```

### Step 10: LLVM/Clang Build - PIC for libclang.so

bindgen requires a **shared** `libclang.so`, but the default LLVM build produces only static archives. The build.py must be patched to use PIC (Position Independent Code) for the **final** build stage while keeping PIC off for bootstrap:

```python
# In tools/clang/scripts/build.py:
# 1. REMOVE the PIC line from base_cmake_args (replace f'-DLLVM_ENABLE_PIC={pic_mode}' with a comment)
# 2. ADD to bootstrap_args: '-DLLVM_ENABLE_PIC=OFF'
# 3. ADD to final cmake_args: '-DLLVM_ENABLE_PIC=ON' and '-DCMAKE_POSITION_INDEPENDENT_CODE=ON'
```

The LLVM build will **partially fail** - `libclang-cpp.so` will fail to link, but `libclang.so` will be built successfully before that failure. This is fine. Commit the container state at this point and continue.

After the LLVM build, copy `libclang.so*` from the LLVM build dir into `third_party/rust-toolchain/lib/`:

```bash
LLVM_LIB=/root/chromium/src/third_party/llvm-build/Release+Asserts/lib
cp -P "$LLVM_LIB"/libclang.so* /root/chromium/src/third_party/rust-toolchain/lib/
export LIBCLANG_PATH=/root/chromium/src/third_party/rust-toolchain/lib
```

### Step 10: LLVM Build - Additional Patches

These patches are also needed in `tools/clang/scripts/build.py`:

- **Remove `riscv64` sysroot download**: The script tries to download Debian sysroots via `cipd`. Remove the riscv64 sysroot fetch or patch it to use `wget` instead:
  ```python
  # Remove riscv64 from LLVM_BUILTIN_TARGETS and LLVM_RUNTIME_TARGETS cmake args
  ```
- **Remove x86/armv7 runtime triples**: Only keep `aarch64-unknown-linux-gnu` in `runtimes_triples_args`
- **Fix bootstrap targets**: Change `bootstrap_targets = 'X86'` to `'ARM;AArch64'`

### Step 11: Do NOT Use tmpfs

The original script mounts a 48GB tmpfs for `out/Headless`. This will cause the **final link step** to fail with "No space left on device" because ThinLTO needs 50GB+ of temp space and the machine only has 64GB RAM. **Use disk instead**:

```bash
mkdir -p /root/chromium/src/out/Headless
# Do NOT mount tmpfs
cp /root/args.gn /root/chromium/src/out/Headless/args.gn
```

### Step 13: Rust Version - THE CRITICAL FIX

This was the hardest problem. Chromium 144 bundles a **custom-patched** rustc 1.93.0 (commit `11339a0ef5ed586bb7ea4f85a9b7287880caac3a` from November 11, 2025). The bundled library source uses internal lang items (`format_placeholder`, `format_count`) and compiler attributes that only exist in specific rustc versions.

**What does NOT work:**
- Rust stable 1.93.0: Rejects `-Z` flags (nightly-only flags required by Chromium's build system)
- Rust nightly-2026-01-09 (1.94.0) or newer: `format_placeholder`/`format_count` lang items were **removed** from rustc after 1.93.0
- Rust nightly-2025-04-15 (1.88.0): Too old, missing `-Cpanic=immediate-abort` support
- Any `rustup` proxy symlink: Must use the **actual binary path** from `rustup which rustc`

**What WORKS:**
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# Use nightly-2025-11-12, which matches the exact commit date (Nov 11, 2025)
RUST_NIGHTLY="nightly-2025-11-12"
rustup install "$RUST_NIGHTLY"
rustup default "$RUST_NIGHTLY"

# IMPORTANT: Use the actual binary path, not the rustup proxy
RUSTC_ACTUAL=$(rustup which rustc)
ln -sf "$RUSTC_ACTUAL" ./third_party/rust-toolchain/bin/rustc

# Also install bindgen and rustfmt
cargo install bindgen-cli 2>/dev/null || cargo install bindgen-cli --version 0.71.1
RUSTFMT_ACTUAL=$(rustup which rustfmt 2>/dev/null || which rustfmt)
ln -sf "$(which bindgen)" ./third_party/rust-toolchain/bin/bindgen
ln -sf "$RUSTFMT_ACTUAL" ./third_party/rust-toolchain/bin/rustfmt
```

### Step 13: Python Version

System Python 3.9 on AL2023 is too old for Chrome 144 (uses `type | type` union syntax from 3.10+). Use Python 3.11 from the vpython cache:

```bash
VPYTHON3=$(find /root/.cache/vpython-root.0/store -name python3.11 -path "*/bin/python3.11" 2>/dev/null | head -1)
if [ -n "$VPYTHON3" ] && [ -x "$VPYTHON3" ]; then
  ln -sf "$VPYTHON3" /usr/local/bin/python3
  ln -sf "$VPYTHON3" /usr/local/bin/python
fi
```

### Step 15: depot_tools Python Path

depot_tools needs to find the correct Python:

```bash
mkdir -p /root/depot_tools/.cipd_bin
ln -sf /usr/local/bin/python3 /root/depot_tools/.cipd_bin/python3
echo ".cipd_bin" > /root/depot_tools/python3_bin_reldir.txt
```

### Step 15: Environment Variables for Build

```bash
export LIBCLANG_PATH=/root/chromium/src/third_party/rust-toolchain/lib
export LD_LIBRARY_PATH="${LIBCLANG_PATH}:${LD_LIBRARY_PATH:-}"
```

## Recommended Build Strategy

Because the LLVM build partially fails and Docker container state needs to be preserved between stages, the build is best done in phases:

1. **Phase 1 (Steps 1-9)**: Run inside Docker. Commit container state as `chrome-builder-step10`.
2. **Phase 2 (Step 10 - LLVM)**: Run from `chrome-builder-step10`. LLVM build will partially fail (expected). Commit as `chrome-builder-llvm-pic`.
3. **Phase 3 (Steps 11-16)**: Run from `chrome-builder-llvm-pic`. This is the Chromium compile + package step.

Use `docker commit <container> <image-name>` to save state between phases. Use `--privileged` flag when running containers (needed for tmpfs if used, and binfmt_misc).

## Output Contents

The `chromium.zip` contains 14 files:

| File | Size | Description |
|---|---|---|
| `headless_shell` | ~179MB | Chromium headless browser binary (stripped) |
| `libEGL.so` | 0.3MB | EGL graphics (stripped) |
| `libGLESv2.so` | 5.2MB | OpenGL ES (stripped) |
| `libvk_swiftshader.so` | 16MB | Software Vulkan renderer (stripped) |
| `libvulkan.so.1` | 0.6MB | Vulkan loader (stripped) |
| `vk_swiftshader_icd.json` | 0.1KB | Vulkan ICD config |
| `libnss3.so` | 1.3MB | NSS |
| `libnspr4.so` | 0.3MB | NSPR |
| `libsoftokn3.so` | 0.5MB | NSS soft token |
| `libexpat.so.1` | 0.3MB | XML parser |
| `libplc4.so` | 0.2MB | NSPR utility |
| `libplds4.so` | 0.2MB | NSPR data structures |
| `libfreebl3.so` | 0.2MB | NSS crypto |
| `libfreeblpriv3.so` | 0.7MB | NSS crypto (private) |
| `libnssutil3.so` | 0.3MB | NSS utility |
| `libdbus-1.so.3` | 0.5MB | D-Bus IPC |
| `libgcc_s-14-20250110.so.1` | 0.3MB | GCC runtime |
| `libsystemd.so.0` | 1.0MB | systemd integration |

**Important**: The last 4 libraries (`libnssutil3.so`, `libdbus-1.so.3`, `libgcc_s-14-20250110.so.1`, `libsystemd.so.0`) are also required at runtime but were missing from the original build script. They must be copied from `/usr/lib64/` in the build container.

### Stripping Binaries

All build-output binaries must be stripped to remove debug symbols. This saves significant space:

| Binary | Unstripped | Stripped | Saved |
|---|---|---|---|
| `headless_shell` | 263MB | 179MB | 84MB |
| `libvk_swiftshader.so` | 24MB | 16MB | 8MB |
| `libGLESv2.so` | 7.7MB | 5.2MB | 2.5MB |
| `libvulkan.so.1` | 842KB | 633KB | 209KB |
| `libEGL.so` | 408KB | 257KB | 151KB |

```bash
cd /root/chromium/src
for bin in out/Headless/headless_shell out/Headless/libEGL.so out/Headless/libGLESv2.so \
           out/Headless/libvk_swiftshader.so out/Headless/libvulkan.so.1; do
  strip "$bin"
done
```

### Packaging

```bash
mkdir -p final
cp out/Headless/headless_shell final/
cp out/Headless/libEGL.so final/
cp out/Headless/libGLESv2.so final/
cp out/Headless/libvk_swiftshader.so final/
cp out/Headless/libvulkan.so.1 final/
cp out/Headless/vk_swiftshader_icd.json final/

for lib in libnss3.so libnssutil3.so libsoftokn3.so libnspr4.so libexpat.so.1 \
           libplc4.so libplds4.so libfreebl3.so libfreeblpriv3.so \
           libdbus-1.so.3 libgcc_s-14-20250110.so.1 libsystemd.so.0; do
  [ -f "/lib64/$lib" ] && cp "/lib64/$lib" "final/$lib" || \
  [ -f "/usr/lib64/$lib" ] && cp "/usr/lib64/$lib" "final/$lib" || \
  echo "WARNING: $lib not found"
done

cd final && zip -r chromium.zip .
```

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `unknown lang item: format_placeholder` | Wrong Rust nightly version | Use exactly `nightly-2025-11-12` |
| `the option 'Z' is only accepted on the nightly compiler` | Using stable Rust | Must use nightly, not stable |
| `KeyError: 'host'` in run_build_script.py | rustc symlink points to rustup proxy | Use `rustup which rustc` for actual binary path |
| `No space left on device` during ThinLTO link | tmpfs too small for RAM | Don't use tmpfs for out/ directory |
| `recompile with -fPIC` during LLVM | LLVM objects not PIC | Apply PIC patches to build.py (see above) |
| `error: cannot install while Rust is installed` | rustup conflict with system rust | Ignore (non-fatal with `-y` flag) |
| Python `type \| type` syntax error | Python 3.9 too old | Use Python 3.11 from vpython cache |
| Node.js version mismatch | Wrong Node.js for Chrome 144 | Download v24.11.1 arm64 directly |
