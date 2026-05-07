# LiftoffBotServer

Dockerised runtime for 2–3 concurrent headless [Liftoff FPV](https://store.steampowered.com/app/410340/Liftoff_FPV_Drone_Racing/) instances on a single Ubuntu 24.04 host with an NVIDIA GPU. Each instance runs the full Steam client, injects [BepInEx 5.4](https://github.com/BepInEx/BepInEx) (Linux x64 Mono), loads the `LiftoffPhotonEventLogger` plugin, and connects to the competition server as a keyed bot.

---

## Contents

- [Architecture](#architecture)
- [Requirements](#requirements)
- [Repository layout](#repository-layout)
- [First-time setup](#first-time-setup)
- [First-run Steam authentication](#first-run-steam-authentication-vnc)
- [Day-to-day operations](#day-to-day-operations)
- [Workshop subscription management](#workshop-subscription-management)
- [VRAM and performance](#vram-and-performance)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)

---

## Architecture

```
Ubuntu 24.04 host (NVIDIA GPU)
└── Docker (NVIDIA Container Toolkit)
    ├── liftoff-bot-1  ─┐
    ├── liftoff-bot-2  ─┤── image: lo-bot-host:local
    └── liftoff-bot-3  ─┘
            │
            │  each container
            ├── Xvfb :N          virtual framebuffer
            ├── openbox          window manager
            ├── x11vnc           VNC server → host port 590N
            ├── Steam client     full desktop client (not SteamCMD)
            └── Liftoff.x86_64   native Linux Unity build
                    └── BepInEx (Linux x64 Mono, doorstop via LD_PRELOAD)
                            └── LiftoffPhotonEventLogger plugin
                                    └── WebSocket → competition server
```

**Key design points:**

- **Native Linux game.** Liftoff ships a native Linux build (`Liftoff.x86_64`). No Proton or Wine is involved.
- **BepInEx via LD_PRELOAD.** The entrypoint rewrites Liftoff's `launch.sh` into a wrapper that sets `LD_PRELOAD=libdoorstop_x64.so`, which hijacks Unity's Mono startup and loads BepInEx. No Steam launch options are needed.
- **VirtualGL for GPU rendering.** The entrypoint stages `libvglfaker.so` + `libdlfaker.so` alongside the game and LD_PRELOADs them so Liftoff's renderer opens an off-screen EGL pbuffer on the NVIDIA GPU and blits frames back to Xvfb.
- **One Steam account per bot.** Family Sharing caps concurrent sessions at one; each bot needs a separately-licensed account.
- **Graceful shutdown.** The entrypoint calls `steam -shutdown` before exiting. Hard-killing Steam corrupts its local state. `stop_grace_period: 45s` in Compose exists for this reason — never reduce it, never use `docker compose kill`.
- **Idempotent restarts.** The bundled plugin DLL is overwritten on every start (image is source of truth). BepInEx core is rsynced with `--delete`. Plugin config is rendered once from a template, then operator edits are preserved.

---

## Requirements

### Hardware

| Item | Minimum | Notes |
|------|---------|-------|
| OS | Ubuntu 24.04 LTS | Other distros untested |
| GPU | NVIDIA (any CUDA-capable) | GTX 1650 runs 3 bots comfortably |
| VRAM | 4 GB | ~1–1.3 GB per bot at 1280×720 |
| Disk | ~30 GB per bot | Steam + Liftoff install per account |

### Accounts and licences

- **2–3 separate Steam accounts**, each owning Liftoff (AppID 410340). Family Sharing does not allow concurrent sessions.
- **Bot API keys** — one per instance — registered in the competition server's `bots` table. Generate via the server admin UI or directly in SQL.
- **Competition server URL** — a running instance of the companion competition server, reachable from the host.

### Build prerequisites (plugin)

- A **Windows dev machine** with .NET SDK 6.0+ to build `LiftoffPhotonEventLogger.dll`. The plugin references Unity/Photon DLLs from the Liftoff install and cannot be built inside the image.
- The sibling plugin repo checked out at `C:\Projects\Liftoff`.

### Optional: Steam Workshop manager

- **Steamworks SDK** (download from [partner.steamgames.com](https://partner.steamgames.com/)). Required only for the `steam-workshop` backup/restore tool. The zip must be present in the repo root as `steamworks_sdk_*.zip` before `docker compose build`.

---

## Repository layout

```
LiftoffBotServer/
├── Dockerfile                    multi-stage: BepInEx fetch + swm build + Ubuntu runtime
├── docker-compose.yml            3 bot services
├── entrypoint.sh                 per-container boot orchestration
├── setup-host.sh                 idempotent Ubuntu 24.04 host bootstrap
├── sync-plugin.ps1               Windows: copy built DLL into plugin-build/
├── steam-workshop                thin wrapper for the workshop CLI (sets env vars)
├── .env.example                  environment template — copy to .env and fill in
├── .gitattributes                enforces LF line endings on shell/config files
├── .gitignore
├── plugin-build/                 gitignored; populate before docker compose build
│   └── LiftoffPhotonEventLogger.dll
├── plugins-extra/                bind-mounted hot-swap plugin directory
│   └── README.md
├── config-templates/
│   └── uk.co.geekhost.liftoff.photoneventlogger.cfg.tmpl
├── workshop-backups/
│   ├── liftoff-bot-1/            bind-mounted into bot-1; backup JSONs land here
│   ├── liftoff-bot-2/
│   └── liftoff-bot-3/
├── logs/liftoff-bot-N/           bind-mounted BepInEx + Steam logs (gitignored)
└── secrets/
    └── vnc-passwd                created by x11vnc -storepasswd; gitignored
```

---

## First-time setup

### 1. Bootstrap the Ubuntu host

Run once on a fresh Ubuntu 24.04 machine. Idempotent — safe to rerun.

```bash
sudo ./setup-host.sh
```

This installs the NVIDIA driver (if absent), Docker, and the NVIDIA Container Toolkit, then verifies GPU access inside a test container. If the script flags a required reboot, reboot before continuing.

### 2. Build the plugin DLL (Windows dev machine)

```powershell
# In C:\Projects\Liftoff
dotnet build -c Release Pluggins\LiftoffPhotonEventLogger\LiftoffPhotonEventLogger.csproj

# In C:\Projects\LiftoffBotServer (this repo)
.\sync-plugin.ps1
```

`sync-plugin.ps1` copies the built DLL into `./plugin-build/`. Transfer this directory to the Ubuntu host (rsync, scp, or SSHFS):

```bash
rsync -av plugin-build/ user@ubuntu-host:~/LiftoffBotServer/plugin-build/
```

### 3. Obtain the Steamworks SDK (optional — workshop manager only)

Download the Steamworks SDK zip from [partner.steamgames.com](https://partner.steamgames.com/) (requires a Steamworks partner account). Place the zip in the repo root:

```
LiftoffBotServer/steamworks_sdk_164.zip   ← filename can vary; zip must start with steamworks_sdk_
```

If you skip this step, the `swm-build` Docker stage will fail. Omit it only if you don't need the `steam-workshop` tool (see the [Workshop section](#workshop-subscription-management) to decide).

> **Note:** The Steamworks SDK zip is gitignored and must never be committed to a public repository.

### 4. Configure environment variables

```bash
cp .env.example .env
nano .env   # or vi, vim, etc.
```

Fill in:

```dotenv
COMPETITION_SERVER_URL=wss://your-server/plugin
PLUGIN_API_KEY_1=<api-key-for-bot-1>
PLUGIN_API_KEY_2=<api-key-for-bot-2>
PLUGIN_API_KEY_3=<api-key-for-bot-3>

# Optional — human-readable labels for each bot's Steam account
STEAM_USER_1=bot-easy
STEAM_USER_2=bot-medium
STEAM_USER_3=bot-hard
```

### 5. Create the shared VNC password

All three bots share one VNC password file:

```bash
x11vnc -storepasswd "your-strong-password" ./secrets/vnc-passwd
```

### 6. Fix workshop-backups directory ownership

The `workshop-backups/` subdirectories are created by root but must be writable by the `steam` user (UID 1000) inside the container:

```bash
sudo chown -R 1000:1000 ./workshop-backups/
```

### 7. Build the Docker image

```bash
docker compose build
```

This runs three stages: fetches BepInEx, builds the `steam-subber` workshop CLI against the Steamworks SDK, and assembles the runtime image. The first build takes several minutes; subsequent builds are fast (layers cached).

### 8. Start the first bot and complete Steam authentication

Start only bot-1 initially. First-run requires a human at a VNC client to log in to Steam.

```bash
docker compose up -d liftoff-bot-1
docker compose logs -f liftoff-bot-1
```

Watch the logs for the first-run banner, then follow the [First-run Steam authentication](#first-run-steam-authentication-vnc) steps below.

Repeat for bot-2 and bot-3 once bot-1 is stable.

### 9. Start the full fleet

```bash
docker compose up -d
```

---

## First-run Steam authentication (VNC)

Each bot's Steam credentials are entered once via VNC and persist in the per-instance Docker volumes (`liftoff-bot-N-steam`, `liftoff-bot-N-steamlocal`). **Never delete these volumes** without being prepared to re-authenticate — each Steam account will re-download ~5 GB of game files.

**For each bot in turn (bot-1 first):**

1. **Tunnel the VNC port** from your workstation:

   ```bash
   ssh -L 5901:127.0.0.1:5901 your-ubuntu-host
   ```

   Use port 5902 for bot-2, 5903 for bot-3.

2. **Connect a VNC client** to `localhost:5901`. Use the password from `./secrets/vnc-passwd`. You will see the Steam login window on a black desktop.

3. **Log in** as the Steam account that owns Liftoff for this instance. Complete Steam Guard if prompted (check the account's email).

4. **Install Liftoff** from the Steam Library. Wait for the download to finish (~5 GB).

5. **Close Steam** via *Steam → Exit* (not the window X button — that minimises Steam without quitting). The entrypoint is polling for the Liftoff install directory. As soon as it appears, the entrypoint:
   - Injects the BepInEx payload and plugin DLL
   - Renders the plugin config from the template
   - Waits for Steam IPC, then calls `steam -applaunch 410340`

6. **Confirm success** in the logs:

   ```
   [entrypoint:liftoff-bot-1] BepInEx chainloader loaded successfully
   ```

   This appears ~90 s after the game launch. The game will be visible in the VNC window at the Liftoff main menu.

---

## Day-to-day operations

### Starting, stopping, restarting

```bash
# Full fleet
docker compose up -d
docker compose down          # graceful (respects stop_grace_period: 45s)

# Individual bot
docker compose up -d liftoff-bot-1
docker compose restart liftoff-bot-2

# Never use:
docker compose kill          # bypasses graceful Steam shutdown; corrupts state
```

### Reading logs

```bash
# Live Docker logs (prefixed by source)
docker compose logs -f liftoff-bot-1

# BepInEx log on disk (survives restarts)
tail -F ./logs/liftoff-bot-1/BepInEx/LogOutput.log
```

Log line prefixes: `[entrypoint:liftoff-bot-1]`, `[bepinex:liftoff-bot-1]`, `[steam:liftoff-bot-1]`.

### Updating the bundled plugin

```powershell
# Windows: rebuild and sync
dotnet build -c Release Pluggins\LiftoffPhotonEventLogger\...csproj
.\sync-plugin.ps1
# Transfer plugin-build/ to host, then:
```

```bash
docker compose build
docker compose up -d
```

### Hot-swapping third-party plugins

Drop DLLs into `./plugins-extra/`, then restart the relevant bot:

```bash
cp my-plugin.dll ./plugins-extra/
docker compose restart liftoff-bot-1
```

The `plugins-extra/` directory is bind-mounted read-only into all three containers. See [`plugins-extra/README.md`](plugins-extra/README.md) for target-framework requirements.

### Editing a bot's plugin config

```bash
# Read the live config
docker compose exec liftoff-bot-1 \
  cat /var/liftoff/bepinex-config/uk.co.geekhost.liftoff.photoneventlogger.cfg

# Replace it with an edited copy
docker cp my-edited.cfg \
  liftoff-bot-1:/var/liftoff/bepinex-config/uk.co.geekhost.liftoff.photoneventlogger.cfg
docker compose restart liftoff-bot-1
```

`ServerUrl`, `ApiKey`, and `EnableDryRun` are re-synced from env vars on every restart and cannot be permanently overridden via the config file.

### Clearing the BepInEx assembly cache

If plugins fail to load after a game update or DLL swap:

```bash
docker compose exec liftoff-bot-1 rm -rf /var/liftoff/bepinex-cache/*
docker compose restart liftoff-bot-1
```

---

## Workshop subscription management

Each bot has its own Steam account and therefore its own set of Steam Workshop subscriptions. The `steam-workshop` CLI (built from [SteamWorkshopManager](https://github.com/geekhostuk/SteamWorkshopManager) during the Docker build) lets you back up and restore subscriptions per bot.

> **Requirement:** The Steamworks SDK zip must have been present during `docker compose build`. If `steam-workshop` is not found in the container, rebuild the image with the SDK zip in place.

> **Timing:** The Steam client must be running inside the container when you run these commands. Wait at least 60 seconds after `docker compose up` before using `steam-workshop`.

### Backing up subscriptions

The backup file is written to the bot's `workshop-backups/` directory on the host. Use `-w` to set the working directory so the file lands there:

```bash
docker exec -it -w /home/steam/workshop-backups liftoff-bot-1 steam-workshop --backup
```

The file is named after the bot's Steam ID: e.g. `76561198726097002.json`. It appears at `./workshop-backups/liftoff-bot-1/` on the host immediately.

### Listing current subscriptions

```bash
docker exec -it liftoff-bot-1 steam-workshop --list
```

### Copying a backup file from your workstation

The `workshop-backups/liftoff-bot-N/` directories on the server are bind-mounted directly into the containers, so any file you copy there is immediately available inside without a container restart.

**From Windows (PowerShell or Command Prompt):**

```powershell
# Copy to bot-1's backup directory
scp C:\path\to\backup.json user@your-server:~/LiftoffBotServer/workshop-backups/liftoff-bot-1/

# To apply the same file to all three bots
scp C:\path\to\backup.json user@your-server:~/LiftoffBotServer/workshop-backups/liftoff-bot-1/
scp C:\path\to\backup.json user@your-server:~/LiftoffBotServer/workshop-backups/liftoff-bot-2/
scp C:\path\to\backup.json user@your-server:~/LiftoffBotServer/workshop-backups/liftoff-bot-3/
```

**From Linux / macOS:**

```bash
scp /path/to/backup.json user@your-server:~/LiftoffBotServer/workshop-backups/liftoff-bot-1/
```

Once copied, restore as normal. Note the path mapping — the `liftoff-bot-N/` subdirectory on the host is the mount root inside the container:

```
host:  ./workshop-backups/liftoff-bot-1/myfile.json
                    ↓ bind mount
container:  /home/steam/workshop-backups/myfile.json   ← use this path with steam-workshop
```

### Restoring from a JMT FPV playlist export

The [JMT FPV](https://jmtfpv.com) playlist manager lets you export all competition tracks as a JSON backup. This is the recommended way to ensure every bot has the correct Liftoff Workshop tracks subscribed before a competition.

**Step 1 — Export from JMT FPV**

In the JMT FPV admin panel, export the track playlist to a `.json` file on your local machine (e.g. `jmtfpv-tracks.json`).

**Step 2 — Copy to the server**

```powershell
# Windows PowerShell — copy to all three bots at once
foreach ($bot in 1,2,3) {
    scp C:\Downloads\jmtfpv-tracks.json `
        user@your-server:~/LiftoffBotServer/workshop-backups/liftoff-bot-$bot/
}
```

**Step 3 — Restore on each bot**

Each bot subscribes independently (separate Steam accounts), so run the restore on each:

```bash
# Preview first — no changes made
# Note: the path inside the container is /home/steam/workshop-backups/<filename>
# The liftoff-bot-N subdirectory on the host is the mount root; don't include it in the path.
docker exec -it liftoff-bot-1 steam-workshop --dry-run \
  --restore /home/steam/workshop-backups/jmtfpv-tracks.json

# Apply to all three bots
for bot in liftoff-bot-1 liftoff-bot-2 liftoff-bot-3; do
  echo "=== Restoring $bot ==="
  docker exec -it $bot steam-workshop \
    --restore /home/steam/workshop-backups/jmtfpv-tracks.json
done
```

Steam must be running inside each container when you run this (wait ~60 s after `docker compose up`).

### Restoring subscriptions (from a steam-workshop backup)

```bash
docker exec -it liftoff-bot-1 steam-workshop \
  --restore /home/steam/workshop-backups/76561198726097002.json
```

### Unsubscribing from everything

```bash
docker exec -it liftoff-bot-1 steam-workshop --unsubscribe-all
```

### Dry run (preview without changes)

```bash
docker exec -it liftoff-bot-1 steam-workshop \
  --dry-run --restore /home/steam/workshop-backups/76561198726097002.json
```

### Cross-bot restore (apply one bot's subscriptions to another)

```bash
# Copy bot-1's backup to bot-2's directory
cp ./workshop-backups/liftoff-bot-1/76561198726097002.json \
   ./workshop-backups/liftoff-bot-2/

# Restore into bot-2
docker exec -it liftoff-bot-2 steam-workshop \
  --restore /home/steam/workshop-backups/76561198726097002.json
```

---

## VRAM and performance

```bash
# Monitor GPU usage across all bots
watch -n2 nvidia-smi
```

Measured on a GTX 1660 (6 GB) at 1280×720, lowest in-game graphics preset:

| Instances | VRAM (approx.) |
|-----------|----------------|
| 1 | ~200 MB idle / ~1 GB in race |
| 3 | ~600 MB idle / 3–4 GB peak during scene load |

To reduce footprint, set `DISPLAY_RESOLUTION=1024x576` in `.env` before rebuilding. In-game graphics settings live under `~/.config/unity3d/LuGus Studios/Liftoff/` in each container — edit via VNC from the in-game video settings menu.

> **Scaling limit:** Adding a 4th bot requires a 4th separately-licensed Steam account. Family Sharing does not cover concurrent sessions. There is no software workaround.

---

## Troubleshooting

### VNC connects but shows a black screen

Xvfb is up but nothing is rendering. Check whether openbox or Steam exited:

```bash
docker compose logs liftoff-bot-1 | grep -Ei 'xvfb|openbox|steam'
```

### Liftoff shows as running in Steam but the game window never appears

Usually a VirtualGL / GPU rendering issue. Diagnose in order:

```bash
# 1. Confirm the container sees the GPU
docker compose exec liftoff-bot-1 nvidia-smi

# 2. Confirm VirtualGL can bind to the NVIDIA EGL device
docker compose exec liftoff-bot-1 bash -c \
  'DISPLAY=:1 vglrun -d egl glxinfo | grep -E "OpenGL vendor|OpenGL renderer"'
# Expected: NVIDIA Corporation / NVIDIA GeForce ...

# 3. Confirm the staged fakers are present
docker compose exec liftoff-bot-1 ls \
  /home/steam/.local/share/Steam/steamapps/common/Liftoff/virtualgl/
# Expected: libdlfaker.so  libvglfaker.so

# 4. Confirm the Unity process has them LD_PRELOADed
docker compose exec liftoff-bot-1 bash -c \
  'tr "\0" "\n" < /proc/$(pgrep -f Liftoff.x86_64 | head -1)/environ | grep -E "LD_PRELOAD|VGL_"'
# Expected: LD_PRELOAD=...libdoorstop_x64.so:./virtualgl/libdlfaker.so:...
#           VGL_DISPLAY=egl, VGL_ISACTIVE=1

# 5. Confirm Unity chose the NVIDIA renderer
docker compose exec liftoff-bot-1 grep -E "Renderer:|Graphics memory" \
  "/home/steam/.config/unity3d/LuGus Studios/Liftoff/Player.log"
# Expected: Renderer: NVIDIA GeForce ...
```

If the launch wrapper at `…/Liftoff/launch.sh` is stale, force a recreate:

```bash
docker compose up -d --force-recreate liftoff-bot-1
```

### BepInEx chainloader not detected after 90 s

```bash
# Check the BepInEx log directly
docker compose exec liftoff-bot-1 \
  tail -50 /home/steam/.local/share/Steam/steamapps/common/Liftoff/BepInEx/LogOutput.log
```

Common causes:
- **Stale assembly cache** — clear with `rm -rf /var/liftoff/bepinex-cache/*` then restart.
- **DLL target framework mismatch** — plugin must be `net472`.
- **Missing game DLL references** — rebuild the plugin against the current Liftoff version.

### Plugin connects but the server sees no events

Verify the API key matches a row in the server's `bots` table, and that `COMPETITION_SERVER_URL` is reachable from inside the container:

```bash
docker compose exec liftoff-bot-1 \
  curl -v "${COMPETITION_SERVER_URL/ws:/http:}" 2>&1 | head -20
```

### Steam Guard loops on every start

The session isn't persisting. Confirm the named volumes exist and are not being recreated:

```bash
docker volume ls | grep liftoff-bot-1-steam
```

If the volume was deleted, re-authenticate via VNC.

### `steam-workshop` writes "Could not open … for writing"

The `workshop-backups/` directory on the host is owned by root. Fix:

```bash
sudo chown -R 1000:1000 ./workshop-backups/
```

### Container won't stop cleanly

`docker compose stop` sends SIGTERM and waits 45 s for Steam to shut down gracefully before sending SIGKILL. If Steam is hung, the SIGKILL will fire at 45 s — Steam recovers on the next start but may re-verify game files. Avoid `docker compose kill` (bypasses the grace period entirely).

---

## Security notes

- **VNC is localhost-only by default.** The `VNC_BIND_ADDR=127.0.0.1` default keeps VNC off the network. Always tunnel via SSH (`ssh -L 590N:127.0.0.1:590N host`). Never bind to `0.0.0.0` without a firewall rule and a strong password.
- **Always set a VNC password.** `ALLOW_UNAUTH_VNC=1` is for local development only. In production, `./secrets/vnc-passwd` must exist.
- **Steam credentials are never in env vars or files.** They are entered interactively over VNC and persist in Docker volumes. Treat the volumes as secrets — do not share or back them up to untrusted storage.
- **Bot API keys are bearer tokens.** Rotate by updating the server's `bots` table and the corresponding `PLUGIN_API_KEY_N` in `.env`, then `docker compose up -d`.
- **The Steamworks SDK zip must not be committed.** It is gitignored. Keep it out of any public or shared repository.
- **`security_opt: [apparmor:unconfined, seccomp:unconfined]`** is required for Steam's use of `clone3` on Ubuntu 24.04 kernels. Do not remove these without a tested replacement profile.
