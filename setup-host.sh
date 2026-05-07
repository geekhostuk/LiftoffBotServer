#!/usr/bin/env bash
# setup-host.sh — Ubuntu 24.04 host bootstrap. Idempotent; safe to rerun.
#
# Installs: NVIDIA driver, Docker Engine, NVIDIA Container Toolkit.
# Verifies: nvidia-smi works inside a GPU-enabled container.

set -euo pipefail

log()   { printf '[setup-host] %s\n' "$*"; }
warn()  { printf '[setup-host] WARNING: %s\n' "$*" >&2; }
fail()  { printf '[setup-host] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    fail "must run as root (try: sudo ./setup-host.sh)"
  fi
}

detect_ubuntu_24() {
  if ! grep -qE 'VERSION_ID="24\.' /etc/os-release; then
    warn "this script targets Ubuntu 24.04; detected $(. /etc/os-release && echo "${PRETTY_NAME}"). Continuing anyway."
  fi
}

apt_update_once() {
  if [[ -z "${_APT_UPDATED:-}" ]]; then
    apt-get update -y
    export _APT_UPDATED=1
  fi
}

install_nvidia_driver() {
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    log "nvidia-smi already works; skipping driver install"
    return 0
  fi
  log "installing NVIDIA driver via ubuntu-drivers autoinstall"
  apt_update_once
  apt-get install -y --no-install-recommends ubuntu-drivers-common
  ubuntu-drivers autoinstall
  log "NVIDIA driver installed; a reboot will be required before nvidia-smi works"
  echo "REBOOT_REQUIRED=1" >>"${LO_BOT_HOST_STATUS_FILE:-/tmp/lo-bot-host-setup.status}"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker --version >/dev/null 2>&1; then
    log "docker already installed ($(docker --version))"
    return 0
  fi
  log "installing Docker via official convenience script"
  apt_update_once
  apt-get install -y --no-install-recommends curl ca-certificates
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
  systemctl enable --now docker
  if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    usermod -aG docker "${SUDO_USER}"
    log "added ${SUDO_USER} to the docker group — log out and back in to pick it up"
  fi
}

install_nvidia_container_toolkit() {
  if command -v nvidia-ctk >/dev/null 2>&1; then
    log "nvidia-container-toolkit already installed"
  else
    log "installing NVIDIA Container Toolkit"
    apt_update_once
    apt-get install -y --no-install-recommends curl ca-certificates gnupg
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.gpg] https://#' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -y
    apt-get install -y --no-install-recommends nvidia-container-toolkit
  fi
  log "configuring docker runtime for NVIDIA"
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
}

verify_gpu_in_container() {
  if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
    warn "host nvidia-smi does not work yet (likely awaiting reboot after driver install); skipping in-container GPU test"
    return 0
  fi
  log "verifying GPU visibility inside a test container"
  if docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/tmp/lo-bot-host-gpu-test.log 2>&1; then
    log "PASS: GPU visible inside container"
    grep -E "NVIDIA-SMI|GeForce|Driver" /tmp/lo-bot-host-gpu-test.log || true
  else
    warn "in-container GPU test failed; see /tmp/lo-bot-host-gpu-test.log"
    return 1
  fi
}

main() {
  require_root
  detect_ubuntu_24
  install_nvidia_driver
  install_docker
  install_nvidia_container_toolkit
  verify_gpu_in_container || true

  echo
  log "setup complete"
  if [[ -f /tmp/lo-bot-host-setup.status ]] && grep -q REBOOT_REQUIRED /tmp/lo-bot-host-setup.status; then
    log "NEXT: reboot the host, then rerun this script to confirm GPU visibility"
  else
    log "NEXT:"
    log "  1. cp .env.example .env and fill in PLUGIN_API_KEY_* and COMPETITION_SERVER_URL"
    log "  2. build the plugin on a Windows dev box, copy DLL into ./plugin-build/"
    log "     (or run sync-plugin.ps1 from the Windows side)"
    log "  3. create the VNC password file: x11vnc -storepasswd <pw> ./secrets/vnc-passwd"
    log "  4. docker compose build && docker compose up -d liftoff-bot-1"
    log "  5. follow the first-run VNC walkthrough in README.md"
  fi
}

main "$@"
