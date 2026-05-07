# syntax=docker/dockerfile:1.6
# LO_Bot_Host — headless Liftoff runtime with Steam + Proton + BepInEx 5.4 (Mono, x64).
#
# Liftoff is a Windows-only Unity Mono game. On Linux, Steam runs it via Proton,
# so we use the WINDOWS x64 BepInEx release and hook via winhttp.dll override.
# The plugin DLL targets net472 and runs inside Unity's bundled Mono (Wine-loaded).

ARG BEPINEX_VERSION=5.4.23.2
ARG VIRTUALGL_VERSION=3.1.3

############################################
# Stage 1: fetch BepInEx Windows x64 release
############################################
FROM alpine:3.20 AS bepinex-fetch
ARG BEPINEX_VERSION
# Liftoff has a native Linux build (Liftoff.x86_64 + UnityPlayer.so + launch.sh),
# so we use the Linux x64 Mono BepInEx variant — ships run_bepinex.sh, doorstop_libs/,
# libdoorstop_x64.so. Plugin DLLs are still net472, loaded by Unity's Mono.
RUN apk add --no-cache curl unzip ca-certificates \
 && mkdir -p /bepinex \
 && curl -fsSL -o /tmp/bepinex.zip \
      "https://github.com/BepInEx/BepInEx/releases/download/v${BEPINEX_VERSION}/BepInEx_linux_x64_${BEPINEX_VERSION}.zip" \
 && unzip -q /tmp/bepinex.zip -d /bepinex \
 && rm /tmp/bepinex.zip \
 && ls -la /bepinex


############################################
# Stage 2: build SteamWorkshopManager
############################################
FROM ubuntu:24.04 AS swm-build
ARG SWM_SDK_ZIP=steamworks_sdk_164.zip
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
      cmake build-essential git ca-certificates python3 \
 && rm -rf /var/lib/apt/lists/*
COPY ${SWM_SDK_ZIP} /tmp/steamworks.zip
RUN python3 -c "import zipfile; zipfile.ZipFile('/tmp/steamworks.zip').extractall('/steamworks')" \
 && rm /tmp/steamworks.zip
RUN git clone --depth 1 https://github.com/geekhostuk/SteamWorkshopManager /swm \
 && cmake -S /swm -B /swm/build \
          -DSTEAMWORKS_SDK_DIR=/steamworks/sdk \
          -DCMAKE_BUILD_TYPE=Release \
 && cmake --build /swm/build --config Release


############################################
# Stage 3: runtime
############################################
FROM ubuntu:24.04 AS runtime

ARG DEBIAN_FRONTEND=noninteractive
ARG STEAM_DEB_URL=https://repo.steampowered.com/steam/archive/precise/steam_latest.deb

# i386 is required for the Steam client (Steam itself is 32-bit).
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg \
      dos2unix xz-utils unzip \
      sudo dbus-x11 xauth procps jq gettext-base rsync \
      xvfb x11vnc openbox \
      mesa-utils libgl1 libglu1-mesa libglx-mesa0 \
      libgl1-mesa-dri libegl1 libegl-mesa0 libgles2 libosmesa6 \
      libvulkan1 vulkan-tools mesa-vulkan-drivers \
      libnss3 libnspr4 \
      libxcomposite1 libxrandr2 libxdamage1 libxfixes3 libxkbcommon0 \
      libxshmfence1 libxcb-cursor0 libxtst6 libxi6 libxcursor1 libxinerama1 libxss1 \
      libgbm1 libgtk-3-0t64 libpango-1.0-0 libcairo2 \
      libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libdrm2 \
      libasound2t64 libpulse0 \
      libnotify4 libsecret-1-0 \
      fonts-liberation fonts-dejavu-core \
      libgl1:i386 libglx-mesa0:i386 libglu1-mesa:i386 \
      libc6:i386 libstdc++6:i386 \
      libnss3:i386 libnspr4:i386 \
      libxcomposite1:i386 libxtst6:i386 libxrandr2:i386 \
      libxi6:i386 libxss1:i386 libxcursor1:i386 libxinerama1:i386 \
      libgbm1:i386 libgtk-3-0:i386 \
      libpulse0:i386 libasound2t64:i386 \
      libdbus-1-3:i386 libcurl4t64:i386 \
      libva2:i386 libvdpau1:i386 \
      libappindicator3-1 \
 && rm -rf /var/lib/apt/lists/*

# VirtualGL is not in the Ubuntu repos — grab the upstream .deb.
ARG VIRTUALGL_VERSION
RUN curl -fsSL -o /tmp/virtualgl.deb \
      "https://github.com/VirtualGL/virtualgl/releases/download/${VIRTUALGL_VERSION}/virtualgl_${VIRTUALGL_VERSION}_amd64.deb" \
 && apt-get update \
 && apt-get install -y --no-install-recommends /tmp/virtualgl.deb \
 && rm /tmp/virtualgl.deb \
 && rm -rf /var/lib/apt/lists/*

# Install the official Steam client (.deb, not SteamCMD).
# Accept Steam EULA non-interactively via debconf.
RUN curl -fsSL -o /tmp/steam-launcher.deb "${STEAM_DEB_URL}" \
 && echo "steam steam/question select I AGREE" | debconf-set-selections \
 && echo "steam steam/license note ''" | debconf-set-selections \
 && apt-get update \
 && apt-get install -y --no-install-recommends /tmp/steam-launcher.deb \
 && rm /tmp/steam-launcher.deb \
 && rm -rf /var/lib/apt/lists/* \
 && if [ -x /usr/bin/steamdeps ]; then \
      echo '#!/bin/sh' > /usr/bin/steamdeps && \
      echo 'exit 0' >> /usr/bin/steamdeps && \
      chmod +x /usr/bin/steamdeps; \
    fi

# Non-root user. UID 1000 matches the typical host user; override via build arg if needed.
# Ubuntu 24.04's base image ships with a default `ubuntu` user at 1000 — remove it first.
ARG STEAM_UID=1000
ARG STEAM_GID=1000
RUN if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu 2>/dev/null || userdel ubuntu; fi \
 && if getent group ubuntu >/dev/null; then groupdel ubuntu; fi \
 && groupadd -g ${STEAM_GID} steam \
 && useradd  -m -u ${STEAM_UID} -g ${STEAM_GID} -s /bin/bash steam \
 && usermod -aG video,audio steam \
 && mkdir -p /var/liftoff/bepinex-config /var/liftoff/bepinex-cache \
 && mkdir -p /home/steam/.steam /home/steam/.local/share/Steam /home/steam/.config /home/steam/logs \
 && ln -s /home/steam/.local/share/Steam /home/steam/.steam/steam \
 && chown -R steam:steam /home/steam /var/liftoff

# Payloads.
COPY --from=bepinex-fetch /bepinex/ /opt/bepinex-payload/
# Copies the bundled plugin (.dll) and its debug symbols (.pdb) if present.
# sync-plugin.ps1 is the upstream fail-fast guard for a missing .dll.
COPY plugin-build/ /opt/plugin-bundled/
COPY config-templates/ /opt/config-templates/

# Workshop Manager — binary + Steamworks library isolated to /opt/swm/ so
# libsteam_api.so never enters the system ldconfig path (avoids shadowing the
# game's own copy which would break rendering / Photon at launch).
# The steam-workshop wrapper sets SteamAppId and LD_LIBRARY_PATH only for
# steam-subber invocations; SteamAppId must NOT be exported globally or Unity
# may change its display/audio initialisation path.
RUN mkdir -p /opt/swm
COPY --from=swm-build /swm/build/steam-subber /opt/swm/steam-subber
COPY --from=swm-build /steamworks/sdk/redistributable_bin/linux64/libsteam_api.so \
                      /opt/swm/libsteam_api.so
RUN chmod 755 /opt/swm/steam-subber /opt/swm/libsteam_api.so
COPY --chmod=755 steam-workshop /usr/local/bin/steam-workshop

# Scripts. dos2unix guards against Windows CRLFs slipping through.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN dos2unix /usr/local/bin/entrypoint.sh \
 && chmod +x /usr/local/bin/entrypoint.sh

# Process-liveness only; BepInEx readiness is a soft watchdog in entrypoint.sh.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD pgrep -f "Liftoff" >/dev/null || exit 1

USER steam
WORKDIR /home/steam
ENV HOME=/home/steam \
    STEAM_RUNTIME=1 \
    DBUS_FATAL_WARNINGS=0 \
    SDL_AUDIODRIVER=dummy \
    PULSE_SERVER=none \
    __GLX_VENDOR_LIBRARY_NAME=nvidia

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
