# =============================================================================
# Dockerfile — Chromium 144 headless_shell build environment
#
# Based on the Lambda Node.js 24 image (Amazon Linux 2023, ARM64).
# Overrides the Lambda entrypoint so we can use it as a plain build container.
# =============================================================================
FROM public.ecr.aws/lambda/nodejs:24.2026.01.26.23

# Override Lambda entrypoint so we can run arbitrary commands
ENTRYPOINT []
CMD ["bash"]

# --- Install build dependencies ---
# The Lambda image uses microdnf / dnf (AL2023 minimal).
# We need a full development toolchain for Chromium.
# microdnf doesn't support group installs, so we list individual packages.
# Split into two layers: core build tools, then Chromium-specific deps.
# curl-minimal and openssl-snapsafe-libs are pre-installed in Lambda image;
# swap them for standard versions so Python SSL works.
RUN dnf swap -y curl-minimal curl && \
    dnf swap -y openssl-snapsafe-libs openssl-libs && \
    dnf install -y \
    gcc \
    gcc-c++ \
    make \
    git \
    clang \
    python3 \
    python3-pip \
    perl \
    ruby \
    rust \
    cargo \
    tar \
    unzip \
    wget \
    zip \
    nano \
    bc \
    gperf \
    which \
    findutils \
    diffutils \
    patch \
    && dnf clean all

RUN dnf install -y \
    alsa-lib-devel \
    atk-devel \
    bluez-libs-devel \
    bzip2-devel \
    cairo-devel \
    cups-devel \
    dbus-devel \
    dbus-glib-devel \
    expat-devel \
    gtk3-devel \
    libatomic \
    libcap-devel \
    libcurl-devel \
    libdrm-devel \
    libjpeg-devel \
    libuuid-devel \
    libXScrnSaver-devel \
    libxkbcommon-x11-devel \
    libxml2-devel \
    nspr-devel \
    nss-devel \
    openssl-devel \
    pam-devel \
    pciutils-devel \
    && dnf clean all

# --- Copy build files ---
COPY build-chromium.sh /root/build-chromium.sh
COPY dot-gclient /root/dot-gclient
COPY args.gn /root/args.gn

RUN chmod +x /root/build-chromium.sh
