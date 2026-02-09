# chromium-headless-shell-amazon-linux2023-arm64.zip

## How this zip was created

This zip was created by restructuring `chromium-headless-shell-lambda-arm64.zip` to match the directory structure of the other Chrome headless shell distributions.

### Problem

The original `chromium-headless-shell-lambda-arm64.zip` had all files at the root level:

```
headless_shell
libEGL.so
libGLESv2.so
...
```

The other zips (`chrome-headless-shell-linux-arm64.zip` and `chrome-headless-shell-linux64.zip`) have files inside a subdirectory:

```
chrome-headless-shell-linux64/
  chrome-headless-shell
  libEGL.so
  libGLESv2.so
  ...
```

### Solution

Extracted the original zip into a new subdirectory and re-zipped:

```bash
# Create temp directory with target structure
mkdir -p temp_lambda/chromium-headless-shell-amazon-linux2023-arm64

# Extract original zip into the subdirectory
unzip -q chromium-headless-shell-lambda-arm64.zip -d temp_lambda/chromium-headless-shell-amazon-linux2023-arm64

# Create new zip with proper structure
cd temp_lambda
zip -r ../chromium-headless-shell-amazon-linux2023-arm64.zip chromium-headless-shell-amazon-linux2023-arm64

# Cleanup
cd ..
rm -rf temp_lambda
```

### Result

The new zip contains all files under `chromium-headless-shell-amazon-linux2023-arm64/`:

- `headless_shell` - Chromium headless shell binary
- `libEGL.so`, `libGLESv2.so` - Graphics libraries
- `libvk_swiftshader.so`, `libvulkan.so.1`, `vk_swiftshader_icd.json` - Vulkan/SwiftShader
- `libnss3.so`, `libnssutil3.so`, `libnspr4.so`, `libsoftokn3.so`, `libfreebl3.so`, `libfreeblpriv3.so` - NSS/NSPR libraries
- `libexpat.so.1` - XML parsing library
- `libplc4.so`, `libplds4.so` - NSPR utility libraries
- `libdbus-1.so.3` - D-Bus library
- `libgcc_s-14-20250110.so.1` - GCC runtime
- `libsystemd.so.0` - systemd library

These additional libraries (compared to the standard Chrome distributions) are included because this build targets Amazon Linux 2023 for AWS Lambda, which requires bundling more system dependencies.
