#!/usr/bin/env bash
# entrypoint.sh — per-container boot: virtual display, Steam, BepInEx wiring, log fanout.
# Assumes Liftoff runs via Proton (Windows-only game on Linux Steam).

set -euo pipefail

log() { printf '[entrypoint:%s] %s\n' "${INSTANCE_ID:-?}" "$*"; }

: "${INSTANCE_ID:?INSTANCE_ID must be set}"
: "${DISPLAY_NUM:?DISPLAY_NUM must be set}"
: "${DISPLAY_RESOLUTION:=1280x720}"
: "${COMPETITION_SERVER_URL:?COMPETITION_SERVER_URL must be set}"
: "${PLUGIN_API_KEY:?PLUGIN_API_KEY must be set}"
: "${STEAM_USER_LABEL:=${INSTANCE_ID}}"
: "${VNC_PASSWORD_FILE:=/run/secrets/vnc-passwd}"
: "${ALLOW_UNAUTH_VNC:=0}"
: "${LIFTOFF_APPID:=410340}"
# Default visible: -silent minimises Steam to a system tray, but openbox has no
# tray applet — the result is an empty black VNC session with no way to inspect
# or recover. Operators can still opt into silent mode per-instance.
: "${STEAM_SILENT:=0}"

export DISPLAY=":${DISPLAY_NUM}"
STEAM_ROOT="${HOME}/.local/share/Steam"
STEAM_CONFIG="${HOME}/.steam/steam/config"
LIFTOFF_DIR="${STEAM_ROOT}/steamapps/common/Liftoff"
BEPINEX_LOG="${LIFTOFF_DIR}/BepInEx/LogOutput.log"
HOST_LOGS="${HOME}/logs"
mkdir -p "${HOST_LOGS}" 2>/dev/null || true
# Host bind mount is often created by Docker as root; steam (uid 1000) then
# can't write to it, which silently kills Steam (the `&` backgrounds the
# redirect-fail exit). Detect and fall back to an internal path if so.
if ! ( touch "${HOST_LOGS}/.writetest" 2>/dev/null && rm -f "${HOST_LOGS}/.writetest" ); then
  printf '[entrypoint:%s] WARNING: %s is not writable (host dir likely owned by root). Falling back to %s/.local/logs.\n' \
    "${INSTANCE_ID}" "${HOST_LOGS}" "${HOME}"
  printf '[entrypoint:%s]          Persist logs on the host with: sudo chown -R 1000:1000 ./logs/\n' "${INSTANCE_ID}"
  HOST_LOGS="${HOME}/.local/logs"
  mkdir -p "${HOST_LOGS}"
fi

XVFB_PID=""
WM_PID=""
VNC_PID=""
STEAM_PID=""
WATCHDOG_PID=""
TAIL_PIDS=()

#######################################
# Shutdown: never SIGKILL Steam — it corrupts local state.
#######################################
graceful_shutdown() {
  log "SIGTERM received; shutting down cleanly"
  if [[ -n "${STEAM_PID}" ]] && kill -0 "${STEAM_PID}" 2>/dev/null; then
    steam -shutdown >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      kill -0 "${STEAM_PID}" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "${STEAM_PID}" 2>/dev/null; then
      log "Steam did not exit within 20s; sending SIGTERM"
      kill "${STEAM_PID}" 2>/dev/null || true
      sleep 5
      kill -9 "${STEAM_PID}" 2>/dev/null || true
    fi
  fi
  for p in "${WATCHDOG_PID}" "${VNC_PID}" "${WM_PID}" "${XVFB_PID}" "${TAIL_PIDS[@]}"; do
    [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true
  done
  log "shutdown complete"
  exit 0
}
trap graceful_shutdown SIGTERM SIGINT

#######################################
# Virtual display stack.
#######################################
start_xvfb() {
  log "starting Xvfb on ${DISPLAY} at ${DISPLAY_RESOLUTION}"
  rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" 2>/dev/null || true
  Xvfb "${DISPLAY}" -screen 0 "${DISPLAY_RESOLUTION}x24" \
       +extension GLX +extension RANDR +render -noreset \
       -ac &
  XVFB_PID=$!
  for _ in $(seq 1 20); do
    if [[ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ]]; then
      log "Xvfb ready (pid ${XVFB_PID})"
      return 0
    fi
    sleep 0.5
  done
  log "ERROR: Xvfb failed to start"
  exit 1
}

start_wm() {
  log "starting openbox"
  openbox --sm-disable >/dev/null 2>&1 &
  WM_PID=$!
}

start_vnc() {
  local args=(-display "${DISPLAY}" -forever -shared -quiet -noxdamage -nowf -wait 30 -rfbport 5900)
  if [[ "${ALLOW_UNAUTH_VNC}" == "1" ]]; then
    log "WARNING: starting x11vnc WITHOUT authentication (ALLOW_UNAUTH_VNC=1)"
    args+=(-nopw)
  elif [[ -f "${VNC_PASSWORD_FILE}" ]]; then
    log "starting x11vnc with password file ${VNC_PASSWORD_FILE}"
    args+=(-rfbauth "${VNC_PASSWORD_FILE}")
  else
    log "ERROR: no VNC password file at ${VNC_PASSWORD_FILE} and ALLOW_UNAUTH_VNC!=1"
    log "       create one with: x11vnc -storepasswd <pw> ./secrets/vnc-passwd"
    exit 1
  fi
  x11vnc "${args[@]}" >/dev/null 2>&1 &
  VNC_PID=$!
  log "x11vnc started (pid ${VNC_PID}) on container port 5900"
}

#######################################
# First-run banner + Steam bootstrap.
#######################################
first_run_banner() {
  cat <<BANNER
================================================================================
 FIRST RUN for ${INSTANCE_ID} (Steam account label: ${STEAM_USER_LABEL})
 ---------------------------------------------------------------
 1. Tunnel the mapped VNC port to your workstation, e.g.:
      ssh -L 5901:127.0.0.1:5901 <host>
    then connect your VNC client to localhost:5901 (use the password
    stored in ./secrets/vnc-passwd).
 2. In Steam: log in as the account that owns Liftoff for this instance,
    complete Steam Guard.
 3. Settings -> Compatibility -> enable "Steam Play for all other titles"
    (Proton Experimental or GE-Proton).
 4. Install Liftoff (AppID ${LIFTOFF_APPID}); wait for the download to finish.
 5. Right-click Liftoff -> Properties -> General -> Launch Options, paste:
        WINEDLLOVERRIDES="winhttp=n,b" %command%
 6. Close Steam from the tray (File -> Exit). The container will auto-
    resume and launch Liftoff with BepInEx injected.
================================================================================
BANNER
}

launch_steam() {
  # CEF in a container without /dev/dri passthrough reliably blacks out the UI
  # when it tries to spawn a GPU helper. Force software-only rendering via the
  # flags webhelper honours (env var is picked up by steamwebhelper_sniper_wrap.sh).
  export STEAM_CEF_FORCE_SWIFTSHADER=1
  # As a belt-and-braces measure, write explicit Chromium flags to the location
  # the helper wrapper reads (resets every start so changes land).
  mkdir -p "${HOME}/.local/share/Steam"
  printf '%s\n' \
    '--disable-gpu' \
    '--disable-gpu-compositing' \
    '--disable-software-rasterizer' \
    '--in-process-gpu' \
    '--use-gl=swiftshader' \
    '--disable-features=UseChromeOSDirectVideoDecoder' \
    > "${HOME}/.local/share/Steam/cef_args.txt"

  # -silent minimises Steam to the system tray. With no tray applet in the
  # container's openbox stack, that renders as a black screen over VNC, so
  # the operator would be unable to log in or inspect client state. The
  # default is STEAM_SILENT=0 (visible); operators can opt into -silent per
  # instance if they have no need to attach via VNC.
  # -no-browser is always applied — it reduces idle CEF GPU work and is
  # safe whether or not the window is visible.
  local steam_args=(-no-browser)
  if [[ "${STEAM_SILENT}" == "1" ]]; then
    steam_args=(-silent "${steam_args[@]}")
  fi
  log "launching Steam client (STEAM_SILENT=${STEAM_SILENT})"
  steam "${steam_args[@]}" >"${HOST_LOGS}/steam.log" 2>&1 &
  STEAM_PID=$!
  log "Steam started (pid ${STEAM_PID})"
}

wait_for_liftoff_install() {
  log "waiting for Liftoff install at ${LIFTOFF_DIR}"
  local waited=0
  while [[ ! -d "${LIFTOFF_DIR}/BepInEx" && ! -f "${LIFTOFF_DIR}/Liftoff.exe" ]]; do
    # Bail fast once the directory exists, whether or not BepInEx has been
    # injected yet; BepInEx payload is staged by us below.
    if [[ -d "${LIFTOFF_DIR}" ]] && compgen -G "${LIFTOFF_DIR}/*" >/dev/null; then
      break
    fi
    sleep 5
    waited=$((waited + 5))
    if (( waited % 60 == 0 )); then
      log "still waiting for Liftoff install (${waited}s elapsed); check VNC"
    fi
  done
  log "Liftoff install directory ready"
}

#######################################
# BepInEx + plugin injection. Idempotent; runs every boot.
#######################################
inject_bepinex() {
  log "injecting BepInEx (Linux x64 Mono) payload into ${LIFTOFF_DIR}"

  # Purge any legacy Windows-variant BepInEx artifacts that an earlier image
  # may have dropped (winhttp.dll, doorstop_config.ini from win_x64, etc).
  rm -f "${LIFTOFF_DIR}/winhttp.dll" "${LIFTOFF_DIR}/.doorstop_version" 2>/dev/null || true

  # Copy BepInEx core+loader without overwriting game executables.
  rsync -a --ignore-existing /opt/bepinex-payload/ "${LIFTOFF_DIR}/"

  # Always refresh BepInEx/core and doorstop libs so version bumps land.
  if [[ -d /opt/bepinex-payload/BepInEx/core ]]; then
    rsync -a --delete /opt/bepinex-payload/BepInEx/core/ "${LIFTOFF_DIR}/BepInEx/core/"
  fi
  if [[ -d /opt/bepinex-payload/doorstop_libs ]]; then
    rsync -a --delete /opt/bepinex-payload/doorstop_libs/ "${LIFTOFF_DIR}/doorstop_libs/"
  fi
  # run_bepinex.sh is the Unix doorstop launcher; always overwrite with the
  # image's copy so we control behaviour.
  if [[ -f /opt/bepinex-payload/run_bepinex.sh ]]; then
    install -m 0755 /opt/bepinex-payload/run_bepinex.sh "${LIFTOFF_DIR}/run_bepinex.sh"
  fi

  mkdir -p "${LIFTOFF_DIR}/BepInEx/plugins"

  # Bundled plugin: image is source of truth — overwrite every start.
  install -m 0644 /opt/plugin-bundled/LiftoffPhotonEventLogger.dll \
    "${LIFTOFF_DIR}/BepInEx/plugins/LiftoffPhotonEventLogger.dll"
  # .pdb is optional — Release builds may omit it; deploy when present so
  # BepInEx can resolve managed stack traces against it.
  if [[ -f /opt/plugin-bundled/LiftoffPhotonEventLogger.pdb ]]; then
    install -m 0644 /opt/plugin-bundled/LiftoffPhotonEventLogger.pdb \
      "${LIFTOFF_DIR}/BepInEx/plugins/LiftoffPhotonEventLogger.pdb"
    log "bundled plugin deployed: LiftoffPhotonEventLogger.dll + .pdb"
  else
    log "bundled plugin deployed: LiftoffPhotonEventLogger.dll (no .pdb)"
  fi

  # Stage VirtualGL's faker libs under the Liftoff dir. Steam runs launch.sh
  # inside pressure-vessel (SteamLinuxRuntime_soldier), which bind-mounts the
  # game install dir but NOT /usr/bin/vglrun or /usr/lib/libvglfaker.so — so
  # we cannot call the vglrun shell script from inside the sandbox. Instead
  # we copy the two faker libs next to the game and LD_PRELOAD them directly
  # in the launch wrapper. Refreshed every boot so image updates land.
  mkdir -p "${LIFTOFF_DIR}/virtualgl"
  install -m 0644 /usr/lib/libvglfaker.so "${LIFTOFF_DIR}/virtualgl/libvglfaker.so"
  install -m 0644 /usr/lib/libdlfaker.so  "${LIFTOFF_DIR}/virtualgl/libdlfaker.so"
  log "VirtualGL fakers staged: libvglfaker.so + libdlfaker.so"

  # Wrap Liftoff's own launch.sh so BepInEx injects without needing the
  # Steam "Launch Options" UI (which is broken under our headless CEF).
  # Backs up the original on first run, then replaces with a wrapper that
  # delegates to BepInEx's shipped run_bepinex.sh — that script handles arch
  # detection, LD_PRELOAD of libdoorstop.so, doorstop env vars, and Steam's
  # reaper/SteamLaunch argv rotation. Rolling our own wrapper is how we ended
  # up preloading a non-existent libdoorstop_x64.so and loading nothing.
  local game_launch="${LIFTOFF_DIR}/launch.sh"
  local orig="${LIFTOFF_DIR}/launch.sh.orig"
  if [[ -f "${game_launch}" && ! -f "${orig}" ]]; then
    cp -a "${game_launch}" "${orig}"
    log "backed up Liftoff's launch.sh -> launch.sh.orig"
  fi
  cat > "${game_launch}" <<'WRAP'
#!/bin/sh
# LO_Bot_Host BepInEx + VirtualGL wrapper for Liftoff's launch.sh.
#
# We run inside Steam's pressure-vessel sandbox, so we can't call
# /usr/bin/vglrun (lives outside the bind-mount). Instead we replicate what
# vglrun does: set VGL_DISPLAY=egl and LD_PRELOAD the two faker libs that
# entrypoint.sh staged under ./virtualgl/. run_bepinex.sh then prepends
# libdoorstop_x64.so to LD_PRELOAD — final chain:
#   libdoorstop_x64.so:./virtualgl/libdlfaker.so:./virtualgl/libvglfaker.so
# -force-glcore skips Unity's Vulkan probe so the GL path VGL fakes is taken.
# launch.sh.orig is retained for reference.
set -eu
cd "$(dirname "$0")"
export VGL_DISPLAY=egl
export VGL_ISACTIVE=1
if [ -z "${LD_PRELOAD:-}" ]; then
  export LD_PRELOAD="./virtualgl/libdlfaker.so:./virtualgl/libvglfaker.so"
else
  export LD_PRELOAD="./virtualgl/libdlfaker.so:./virtualgl/libvglfaker.so:${LD_PRELOAD}"
fi
exec ./run_bepinex.sh ./Liftoff.x86_64 -force-glcore "$@"
WRAP
  chmod +x "${game_launch}"
  log "wrote BepInEx wrapper at ${game_launch}"

  # BepInEx writes config/ and cache/ next to itself; we previously symlinked
  # these to named volumes for per-instance isolation, but Mono's
  # Directory.CreateDirectory throws IOException on a symlink (treats it as a
  # file), crashing the preloader before plugins load. Per-instance isolation
  # is already provided by the steamlocal volume, which wraps the whole Liftoff
  # dir — so we just let BepInEx use its natural subdirs.
  # Clear stale symlinks from upgraded hosts before materialising the dirs.
  for p in "${LIFTOFF_DIR}/BepInEx/config" "${LIFTOFF_DIR}/BepInEx/cache"; do
    [[ -L "${p}" ]] && rm -f "${p}"
  done
  mkdir -p "${LIFTOFF_DIR}/BepInEx/config" "${LIFTOFF_DIR}/BepInEx/cache"

  # Hot-swap dir. Copy from ro mount into plugins/ so BepInEx can load them
  # without needing write access to the host-mounted directory.
  if compgen -G "/opt/plugins-extra/*.dll" >/dev/null; then
    log "copying hot-swap plugins from /opt/plugins-extra/"
    mkdir -p "${LIFTOFF_DIR}/BepInEx/plugins/extra"
    rsync -a --delete --include='*.dll' --include='*.pdb' --exclude='*' \
      /opt/plugins-extra/ "${LIFTOFF_DIR}/BepInEx/plugins/extra/"
  fi

  # Mirror log file to host bind mount for persistence.
  mkdir -p "${HOST_LOGS}/BepInEx"
  touch "${BEPINEX_LOG}"
  ln -sfn "${BEPINEX_LOG}" "${HOST_LOGS}/BepInEx/LogOutput.log"
}

render_plugin_config() {
  local cfg_dir="${LIFTOFF_DIR}/BepInEx/config"
  local cfg_file="${cfg_dir}/uk.co.geekhost.liftoff.photoneventlogger.cfg"
  local tmpl="/opt/config-templates/uk.co.geekhost.liftoff.photoneventlogger.cfg.tmpl"

  mkdir -p "${cfg_dir}"
  # Migrate any operator edits from the legacy /var/liftoff/bepinex-config
  # path (used before we stopped symlinking BepInEx/config). One-shot.
  local legacy="/var/liftoff/bepinex-config/uk.co.geekhost.liftoff.photoneventlogger.cfg"
  if [[ ! -f "${cfg_file}" && -f "${legacy}" ]]; then
    log "migrating plugin config from legacy /var/liftoff/bepinex-config/"
    cp -a "${legacy}" "${cfg_file}"
  fi
  if [[ -f "${cfg_file}" ]]; then
    # Re-sync env-driven fields on every start so .env changes propagate
    # without discarding operator edits to the other settings.
    log "plugin config present; re-syncing ServerUrl, ApiKey (from env) and EnableDryRun=false (safety-locked), preserving other edits"
    sed -i \
      -e "s|^ServerUrl = .*|ServerUrl = ${COMPETITION_SERVER_URL}|" \
      -e "s|^ApiKey = .*|ApiKey = ${PLUGIN_API_KEY}|" \
      -e "s|^EnableDryRun = .*|EnableDryRun = false|" \
      "${cfg_file}"
    return 0
  fi
  log "rendering plugin config from template"
  COMPETITION_SERVER_URL="${COMPETITION_SERVER_URL}" \
  PLUGIN_API_KEY="${PLUGIN_API_KEY}" \
  INSTANCE_ID="${INSTANCE_ID}" \
    envsubst '${COMPETITION_SERVER_URL} ${PLUGIN_API_KEY} ${INSTANCE_ID}' \
    < "${tmpl}" > "${cfg_file}"
  chmod 0640 "${cfg_file}"
}

#######################################
# Wait until the running Steam client owns the IPC pipe so a subsequent
# `steam -applaunch` invocation relays the command via ~/.steam/steam.pipe
# and exits, instead of spawning a second full client.
#
# Replicates is_steam_running() from Steam's own steam.sh wrapper:
#   1. ~/.steam/steam.pid exists and holds a pid
#   2. /proc/<pid> exists (pid is alive)
#   3. that pid has an fd open on ~/.steam/steam.pipe
#
# If all three hold, the wrapper's relay path is guaranteed to be taken.
# Without this wait, entrypoint used to fire -applaunch while the first
# Steam was still bootstrapping, producing two parallel Steam clients that
# fight over ~/.local/share/Steam and drive steamwebhelper into a crash
# loop (visible as "Restart webhelper process, counter 2" every ~10s).
#######################################
wait_for_steam_ipc_ready() {
  local timeout="${1:-90}"
  local pid_file="${HOME}/.steam/steam.pid"
  local pipe_path="${HOME}/.steam/steam.pipe"
  local waited=0 pid=""
  log "waiting for Steam IPC to be ready (steam.pid + steam.pipe fd)"
  while (( waited < timeout )); do
    if [[ -r "${pid_file}" ]]; then
      pid=$(<"${pid_file}")
      if [[ -n "${pid}" && -d "/proc/${pid}" ]]; then
        if find "/proc/${pid}/fd" -lname "${pipe_path}" 2>/dev/null | read -r _; then
          log "Steam IPC ready (pid ${pid}); -applaunch will relay over pipe"
          return 0
        fi
      fi
    fi
    sleep 2
    waited=$((waited + 2))
    if (( waited % 20 == 0 )); then
      log "still waiting for Steam IPC (${waited}s elapsed)"
    fi
  done
  log "WARNING: Steam IPC not ready after ${timeout}s — firing -applaunch anyway (may spawn a duplicate client and trigger the webhelper crash loop)"
  return 1
}

#######################################
# Game launch + log tailing.
#######################################
launch_liftoff() {
  log "requesting Liftoff launch via Steam (-applaunch ${LIFTOFF_APPID})"
  log "  (BepInEx injected via Liftoff/launch.sh wrapper -> run_bepinex.sh -> LD_PRELOAD=libdoorstop.so)"
  steam -applaunch "${LIFTOFF_APPID}" >>"${HOST_LOGS}/steam.log" 2>&1 &
}

tail_logs() {
  # BepInEx log (the important one).
  ( tail -n 0 -F "${BEPINEX_LOG}" 2>/dev/null \
      | sed -u "s|^|[bepinex:${INSTANCE_ID}] |" ) &
  TAIL_PIDS+=($!)
  # Steam stderr (best-effort — path exists once Steam has run once).
  ( tail -n 0 -F "${HOME}/.steam/steam/logs/stderr.txt" 2>/dev/null \
      | sed -u "s|^|[steam:${INSTANCE_ID}] |" ) &
  TAIL_PIDS+=($!)
}

#######################################
# Soft BepInEx readiness watchdog.
# Never restarts the container — prints one-shot info or warning.
#######################################
start_bepinex_watchdog() {
  (
    sleep 90
    if grep -Fq "Chainloader ready" "${BEPINEX_LOG}" 2>/dev/null; then
      printf '[entrypoint:%s] BepInEx chainloader loaded successfully\n' "${INSTANCE_ID}"
    else
      printf '[entrypoint:%s] WARNING: BepInEx chainloader marker not detected after 90s — plugins may not have loaded. Check BepInEx/LogOutput.log for errors.\n' "${INSTANCE_ID}"
    fi
  ) &
  WATCHDOG_PID=$!
}

#######################################
# Main.
#######################################
main() {
  start_xvfb
  start_wm
  start_vnc

  local first_run=0
  if [[ ! -f "${STEAM_CONFIG}/loginusers.vdf" ]]; then
    first_run=1
    first_run_banner
    # Force the Steam UI visible over VNC so the operator can complete
    # the first-run walkthrough. Without this, -silent minimises Steam
    # to a tray that openbox has no applet for → black screen.
    log "first-run detected — forcing STEAM_SILENT=0 so the Steam UI is visible over VNC"
    STEAM_SILENT=0
  fi

  launch_steam
  wait_for_liftoff_install

  inject_bepinex
  render_plugin_config

  # Must happen before -applaunch: otherwise the second `steam` invocation
  # starts its own full client instead of relaying over the IPC pipe,
  # producing two Steam clients per container and a steamwebhelper
  # crash-restart loop.
  wait_for_steam_ipc_ready 90 || true

  # Launch the game (Steam will honour the WINEDLLOVERRIDES launch option set
  # during the first-run walkthrough — we do not mutate localconfig.vdf).
  launch_liftoff

  tail_logs
  start_bepinex_watchdog

  if (( first_run )); then
    log "first-run bootstrap complete; container is now in steady state"
  fi

  # Block on Steam. When Steam exits (e.g. docker stop -> graceful_shutdown
  # calls steam -shutdown), this returns and the container exits cleanly.
  wait "${STEAM_PID}"
  log "Steam exited; leaving background pids for final cleanup"
  graceful_shutdown
}

main "$@"
