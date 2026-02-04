# Chromium Headless Shell Build System

Build Chromium 144.0.7559.97 `headless_shell` with proprietary codecs (H.264/AAC) for multiple platforms.

## Supported Platforms

| Platform | Target | Build Time | Output Size | Use Case |
|----------|--------|------------|-------------|----------|
| **Lambda ARM64** | AWS Lambda (AL2023) | ~4 hours | 88 MB | Serverless browser automation |
| **Linux ARM64** | Debian/Ubuntu ARM64 | ~1h46m | 84 MB | ARM64 servers, Graviton |
| **Linux x64** | Debian/Ubuntu x86_64 | ~1h12m | 91 MB | Standard Linux servers |

## Directory Structure

```
chrome-compile/
├── README.md                    # This file
├── shared/
│   └── .gclient                 # gclient configuration (shared)
├── lambda-arm64/                # AWS Lambda ARM64 build
│   ├── README.md                # Detailed build guide
│   ├── args.gn                  # GN build flags
│   ├── Dockerfile               # AL2023-based container
│   ├── build-chromium.sh        # Build script
│   ├── launch-ec2.sh            # Launch EC2 instance
│   └── setup-ec2.sh             # EC2 setup script
├── linux-arm64/                 # Linux ARM64 build
│   ├── README.md                # Detailed build guide
│   ├── args.gn                  # GN build flags
│   ├── Dockerfile               # Ubuntu 22.04 container
│   ├── build-chromium.sh        # Build script
│   ├── launch-ec2.sh            # Launch EC2 instance
│   └── setup-ec2.sh             # EC2 setup script
├── linux-x64/                   # Linux x64 build
│   ├── README.md                # Detailed build guide
│   ├── args.gn                  # GN build flags
│   ├── Dockerfile               # Ubuntu 22.04 container
│   ├── build-chromium.sh        # Build script (simplified)
│   ├── launch-ec2.sh            # Launch EC2 instance
│   └── setup-ec2.sh             # EC2 setup script
└── output/                      # Pre-built binaries
    ├── chromium-headless-shell-lambda-arm64.zip
    ├── chrome-headless-shell-linux-arm64.zip
    └── chrome-headless-shell-linux64.zip
```

## Quick Start

### Prerequisites

1. AWS CLI configured with credentials
2. Create `.env` file in the build directory:
   ```
   AWS_ACCESS_KEY_ID=your_key
   AWS_SECRET_ACCESS_KEY=your_secret
   ```

### Build Any Platform

```bash
cd <platform-directory>  # e.g., linux-x64

# 1. Launch EC2 instance
./launch-ec2.sh

# 2. Copy files to EC2 (use the SSH command from launch output)
scp -i <key>.pem Dockerfile build-chromium.sh ../shared/.gclient args.gn setup-ec2.sh ec2-user@<IP>:/home/ec2-user/

# 3. SSH and run build
ssh -i <key>.pem ec2-user@<IP>
sudo mv /home/ec2-user/* /root/
sudo mv /root/.gclient /root/dot-gclient  # Rename for Dockerfile
sudo bash /root/setup-ec2.sh

# 4. Download result
scp -i <key>.pem ec2-user@<IP>:/root/*.zip .

# 5. Terminate instance (important!)
aws ec2 terminate-instances --instance-ids <instance-id> --region eu-central-1
```

## Platform Comparison

### Build Complexity

| Aspect | Lambda ARM64 | Linux ARM64 | Linux x64 |
|--------|--------------|-------------|-----------|
| LLVM toolchain | Bootstrap from source | Bootstrap from source | Pre-built (download) |
| Build phases | 3 (with Docker commits) | 3 (with Docker commits) | 1 (single run) |
| PIC patches | Required | Required | Not needed |
| System libs bundled | Yes (for Lambda) | No (apt install) | No (apt install) |

### EC2 Instance Types

| Platform | Instance | vCPUs | RAM | Architecture |
|----------|----------|-------|-----|--------------|
| Lambda ARM64 | c7g.8xlarge | 32 | 64 GB | Graviton3 (ARM64) |
| Linux ARM64 | c7g.8xlarge | 32 | 64 GB | Graviton3 (ARM64) |
| Linux x64 | c6i.8xlarge | 32 | 64 GB | Intel (x86_64) |

### Output Contents

**Lambda ARM64** (includes system libs for Lambda runtime):
```
headless_shell, libEGL.so, libGLESv2.so, libvk_swiftshader.so, libvulkan.so.1,
vk_swiftshader_icd.json, libnss3.so, libnspr4.so, libexpat.so.1, libdbus-1.so.3,
libsoftokn3.so, libfreebl3.so, libfreeblpriv3.so, libnssutil3.so, libplc4.so,
libplds4.so, libgcc_s.so.1, libsystemd.so.0
```

**Linux ARM64/x64** (minimal, install deps via apt):
```
chrome-headless-shell-linux64/
├── chrome-headless-shell
├── libEGL.so
├── libGLESv2.so
├── libvk_swiftshader.so
├── libvulkan.so.1
└── vk_swiftshader_icd.json
```

## Runtime Dependencies

### Lambda ARM64
No additional dependencies needed - all required libs are bundled.

### Linux ARM64/x64
```bash
sudo apt install -y libnss3 libnspr4 libexpat1 libdbus-1-3 libgbm1 \
  libasound2 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
  libxkbcommon0 libx11-6 libxcomposite1 libxdamage1 libxext6 \
  libxfixes3 libxrandr2 libpango-1.0-0 libcairo2 fonts-liberation
```

## Testing

```bash
# Extract
unzip chrome-headless-shell-linux64.zip

# Run (Linux)
./chrome-headless-shell-linux64/chrome-headless-shell \
  --no-sandbox --headless --dump-dom https://example.com

# Run (Lambda - in Lambda environment)
./headless_shell --no-sandbox --headless --dump-dom https://example.com
```

## Key Build Flags (args.gn)

All builds share these core flags:

```gn
import("//build/args/headless.gn")
is_official_build = true
is_debug = false
symbol_level = 0

# Proprietary codecs (H.264/AAC)
proprietary_codecs = true
ffmpeg_branding = "Chrome"

# Embed resources into binary
headless_use_embedded_resources = true
icu_use_data_file = false

# Disable unused features
use_sysroot = false
use_dawn = false
skia_use_dawn = false
clang_use_chrome_plugins = false
```

Platform-specific:
- **ARM64**: `target_cpu = "arm64"`, `v8_target_cpu = "arm64"`
- **x64**: `target_cpu = "x64"`, `v8_target_cpu = "x64"`

## Troubleshooting

See individual platform README files for detailed troubleshooting guides.

Common issues:
- **Rust version**: Must use `nightly-2025-11-12` (matches Chromium 144's rustc)
- **Node.js version**: Must be v24.11.1
- **LLVM build fails**: Expected partial failure on ARM64 - `libclang.so` succeeds before `libclang-cpp.so` fails
- **Out of disk space**: Ensure 200 GB gp3 volume

## Cost Estimate

| Platform | Instance Cost | Build Time | Total |
|----------|--------------|------------|-------|
| Lambda ARM64 | ~$1.09/hr | ~4 hours | ~$4.50 |
| Linux ARM64 | ~$1.09/hr | ~1h46m | ~$2.00 |
| Linux x64 | ~$1.36/hr | ~1h12m | ~$1.70 |

Use spot instances for ~70% savings if build interruption is acceptable.

## Version

- **Chromium**: 144.0.7559.97
- **Build date**: February 2026
