# plugins-extra/

Hot-swappable BepInEx plugin directory. DLLs dropped in here are copied into
`Liftoff/BepInEx/plugins/extra/` inside each container on container start
(not build). No image rebuild required.

## Workflow

1. Drop a compiled `.dll` (optionally with its `.pdb`) into this directory.
2. Restart the target instance:

   ```bash
   docker compose restart liftoff-bot-1
   ```

3. Watch the BepInEx log for the load message:

   ```bash
   docker compose logs -f liftoff-bot-1 | grep -i "loading \[.*\]"
   ```

## Rules

- **Target framework**: plugins must target `net472` (Windows .NET Framework
  4.7.2). BepInEx 5.4 Mono x64 will reject anything else silently or loudly.
- **No native .so files here.** This directory is for managed DLLs only.
  Native deps need to be added to the image directly.
- **Read-only from the container side** — this directory is bind-mounted as
  `:ro`. Plugins cannot write back here. Use `BepInEx/config` (a per-instance
  Docker volume) for runtime state.
- All three bot containers share this directory. If you need a plugin on only
  one instance, build separate `./plugins-extra-N/` dirs and adjust the
  compose mount — the default setup treats it as a shared fleet.

## Debugging a failed plugin load

- Check target framework: `dotnet dis $PLUGIN.dll | head` or open in ILSpy.
- Look for `Chainloader ready` in `./logs/liftoff-bot-N/BepInEx/LogOutput.log`.
- Unresolved type errors usually mean missing game assembly references. The
  reference DLLs live in Liftoff's install dir — copy out via VNC + `docker cp`
  to build against locally.
- If plugin keeps failing, clear the assembly cache:
  `docker compose exec liftoff-bot-1 rm -rf /var/liftoff/bepinex-cache/*`
  then restart the instance.
