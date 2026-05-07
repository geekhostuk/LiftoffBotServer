# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo purpose and scope

This is the **bot runtime host** for the Liftoff competition platform. It is a small repo (Dockerfile, `docker-compose.yml`, two shell scripts, one PowerShell script, one BepInEx config template) that packages Steam + BepInEx + a pre-built plugin DLL into a container image and runs 2-3 instances on a single Ubuntu 24.04 / NVIDIA GPU host.

**The plugin source lives in a separate repo at `C:\Projects\Liftoff`** (under `Pluggins\LiftoffPhotonEventLogger\`). That repo also owns the competition server and admin UI. Do not look for plugin code, server code, or admin UI code here — they are out of scope. Changes to plugin behaviour almost always mean editing the sibling repo, not this one.

## Cross-repo workflow (why there's no in-tree build)

There is no `build` command for the plugin in this repo. The DLL must be built on a Windows dev box against Liftoff's Unity/Photon assemblies, then copied into `./plugin-build/` before `docker compose build` runs:

```powershell
# On Windows, in C:\Projects\Liftoff:
dotnet build -c Release Pluggins\LiftoffPhotonEventLogger\LiftoffPhotonEventLogger.csproj

# Then in C:\Projects\LO_Bot_Host:
.\sync-plugin.ps1            # copies bin/Release/net472/*.dll into ./plugin-build/
```

`sync-plugin.ps1` fails fast if the DLL is missing — that's the signal to rebuild in the sibling repo. `./plugin-build/` is gitignored; the DLL is **not** checked in.

The `Dockerfile` has no stage that compiles the plugin because building it requires game DLL stubs that can't live in a public image (see README "Out of scope"). Image rebuild picks up new DLLs via `COPY plugin-build/...`.

## Platform split

- Shell scripts (`entrypoint.sh`, `setup-host.sh`) run **inside the container or on the Ubuntu host** — never on Windows. Use Unix line endings; `.gitattributes` enforces LF and `dos2unix` runs in the Dockerfile as a belt-and-braces measure.
- `sync-plugin.ps1` runs on **Windows only** (`.ps1` is forced to CRLF).
- The working directory on the maintainer's dev box is Windows (`C:\Projects\LO_Bot_Host`); deployment target is Ubuntu. Keep that in mind when writing any new script.

## Architecture — how a bot actually starts

Liftoff ships a native Linux build (`Liftoff.x86_64` + `UnityPlayer.so` + `launch.sh`). BepInEx is the **Linux x64 Mono** variant (not Windows/Proton, despite some README wording that predates the current approach). Injection happens like this:

1. `entrypoint.sh` brings up Xvfb, openbox, x11vnc, then launches `steam -silent -no-browser`.
2. It polls `~/.local/share/Steam/steamapps/common/Liftoff/` until Steam has downloaded the game (first run: human completes Steam login + install over VNC).
3. `inject_bepinex()` rsyncs `/opt/bepinex-payload/` (BepInEx core + `doorstop_libs/`) into the Liftoff dir, drops `/opt/plugin-bundled/LiftoffPhotonEventLogger.dll` into `BepInEx/plugins/`, and **rewrites `Liftoff/launch.sh`** to a wrapper that sets `LD_PRELOAD=libdoorstop_x64.so` + doorstop env vars and then chains to `launch.sh.orig`. The original is backed up once.
4. `steam -applaunch 410340` runs the (now-wrapped) `launch.sh`; doorstop hijacks Unity's Mono startup and loads BepInEx.
5. Plugin reads `/var/liftoff/bepinex-config/uk.co.geekhost.liftoff.photoneventlogger.cfg` (rendered once from `config-templates/*.tmpl` via `envsubst`, then preserved), opens a WebSocket to `COMPETITION_SERVER_URL` authenticated by `PLUGIN_API_KEY`, and idles at the Liftoff main menu awaiting server commands.

The `WINEDLLOVERRIDES="winhttp=n,b" %command%` instruction in the README is a **legacy/fallback** — the current `launch.sh` wrapper + `LD_PRELOAD` approach does not require it. If you find yourself debugging injection, check the wrapper first.

### Idempotency rules the entrypoint relies on

- **Bundled plugin is overwritten every start** — the image is source of truth for `LiftoffPhotonEventLogger.dll`.
- **BepInEx core and `doorstop_libs` are rsynced with `--delete`** — version bumps in `BEPINEX_VERSION` land on restart.
- **Config files are preserved after first render** — operator edits to `*.cfg` survive restarts (see `render_plugin_config`).
- **Steam install state is preserved** — it lives in per-instance named volumes (`liftoff-bot-N-steam`, `liftoff-bot-N-steamlocal`). Never delete these casually; first-run re-auth takes ~5 GB of redownload and a human at a VNC client.

### Graceful shutdown is load-bearing

`graceful_shutdown()` calls `steam -shutdown` and waits up to 20 s before SIGTERM/SIGKILL. Hard-killing Steam corrupts its local config. `stop_grace_period: 45s` in `docker-compose.yml` exists to give this time; don't reduce it. `docker compose kill` bypasses this — avoid it.

### Readiness is a soft watchdog, not a healthcheck

Docker's HEALTHCHECK is `pgrep Liftoff` only. BepInEx's chainloader is probed 90 s after start (`start_bepinex_watchdog`) and logs one WARNING line if the `Chainloader ready` marker is absent — **it never restarts the container**. This is deliberate: BepInEx timing jitter should not trigger restart loops. If you add new readiness checks, preserve this property.

### Per-instance isolation

Each of the three services (`liftoff-bot-1/2/3`) has:
- Its own Steam account + Liftoff install (Family Sharing caps concurrency at 1; each bot needs its own paid license).
- Its own `DISPLAY_NUM` / `:1`, `:2`, `:3` Xvfb display.
- Its own VNC port (5901/5902/5903 on the host → 5900 in the container).
- Its own set of 4 named volumes (steam, steamlocal, bepinex-config, bepinex-cache).
- A shared read-only mount of `./plugins-extra/` for hot-swap DLLs. All three containers see the same extras by default.

Treat the fleet as homogeneous unless explicitly asked otherwise. If you're tempted to differ per-instance behaviour via env, first check whether `STEAM_USER_LABEL` / `INSTANCE_ID` already cover it.

## Common commands

```bash
# Build the image (requires ./plugin-build/LiftoffPhotonEventLogger.dll to exist)
docker compose build

# Start one bot, tail logs (first-run flow requires this before starting the others)
docker compose up -d liftoff-bot-1
docker compose logs -f liftoff-bot-1

# Start the fleet
docker compose up -d

# Replace the bundled plugin (rebuild + recreate all containers)
.\sync-plugin.ps1            # on Windows
docker compose build
docker compose up -d

# Hot-swap a third-party plugin (no rebuild)
cp my-plugin.dll ./plugins-extra/
docker compose restart liftoff-bot-1

# Read / replace a bot's plugin config
docker compose exec liftoff-bot-1 cat /var/liftoff/bepinex-config/uk.co.geekhost.liftoff.photoneventlogger.cfg
docker cp my-edited.cfg liftoff-bot-1:/var/liftoff/bepinex-config/uk.co.geekhost.liftoff.photoneventlogger.cfg
docker compose restart liftoff-bot-1

# Clear the BepInEx assembly metadata cache (fixes stale-plugin load failures)
docker compose exec liftoff-bot-1 rm -rf /var/liftoff/bepinex-cache/*
docker compose restart liftoff-bot-1

# First-run VNC (tunnel from workstation, then connect to localhost:5901)
ssh -L 5901:127.0.0.1:5901 <ubuntu-host>

# Create the shared VNC password file (once, before first `up`)
x11vnc -storepasswd "some-strong-password" ./secrets/vnc-passwd

# Bootstrap a fresh Ubuntu 24.04 host (idempotent)
sudo ./setup-host.sh
```

There are **no tests, no linter, no CI**. Validation is: `docker compose build` succeeds → `docker compose up -d liftoff-bot-1` runs → `docker compose logs` shows `[entrypoint] BepInEx chainloader loaded successfully` ~90 s later → the competition server logs the bot's WebSocket connect.

## Things to flag before making changes

Per the user's standing guidance, surface blocking real-world constraints explicitly rather than papering over them. Examples that matter in this repo:

- **Steam licensing.** You cannot add a fourth bot by adding a fourth service — it requires a fourth separately-licensed Steam account owning Liftoff. Family Sharing does not cover concurrent sessions.
- **Plugin build.** You cannot build the plugin inside the image without game DLL stubs that can't legally ship in a public image. "Just add a build stage" is not a shortcut.
- **Steam bootstrap sandbox.** `security_opt: [apparmor:unconfined, seccomp:unconfined]` is required for Steam's `clone3` usage on Ubuntu 24.04 kernels. Don't "tighten" this without a concrete replacement profile that's been tested against the Steam bootstrap.
- **GPU footprint.** VRAM scales roughly linearly; 3 bots on a GTX 1650 is near the ceiling at 1280x720. Dropping resolution is the lever (`DISPLAY_RESOLUTION=1024x576`).

## Secrets and untracked paths

- `.env` (copied from `.env.example`) holds `PLUGIN_API_KEY_{1,2,3}` — bearer tokens that map to rows in the competition server's `bots` table.
- `./secrets/vnc-passwd` — x11vnc password blob. Gitignored.
- `./plugin-build/LiftoffPhotonEventLogger.dll` — pre-built plugin. Gitignored.
- `./logs/liftoff-bot-N/` — bind-mounted per-instance BepInEx logs. Gitignored.
- Steam credentials **never** appear in env vars or files in this repo — they are entered interactively over VNC and persist in the per-instance Steam volume.
