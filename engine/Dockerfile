# In-house custom Flutter engine builder (Android), for CI/hosting.
#
# Build the image:
#   docker build -t inhouse-engine-builder hosting/
# Run a build (mount an output dir for artifacts):
#   docker run --rm -v "$PWD/hosting:/work" -v "$PWD/engine-artifacts:/artifacts" \
#     inhouse-engine-builder 05db9689081f091050f01aed79f04dce0c750154
#
# Why Linux: the Android engine cross-compiles cleanly here. Building an older
# engine (e.g. Flutter 3.35.2, Aug 2025) on a brand-new macOS/Xcode SDK fails on
# deprecation-as-error + swift-testing macros — Linux sidesteps all of that.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl python3 python3-distutils unzip zip xz-utils \
      pkg-config build-essential ninja-build ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Chromium depot_tools (provides gclient, gn, ninja, vpython3).
RUN git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git /opt/depot_tools
ENV PATH="/opt/depot_tools:${PATH}"

WORKDIR /work
COPY build-engine.sh /usr/local/bin/build-engine.sh
RUN chmod +x /usr/local/bin/build-engine.sh

# The hook patch is mounted at /work/flutter-loader-hook.patch via the volume,
# or COPY it in for a self-contained image:
# COPY flutter-loader-hook.patch /work/flutter-loader-hook.patch

ENTRYPOINT ["/usr/local/bin/build-engine.sh"]
