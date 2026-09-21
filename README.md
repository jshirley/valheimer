# valheim-sync

Keeps a macOS Valheim install in step with the group's r2modman profile, and
launches it with BepInEx actually attached.

r2modman has no working macOS build for this, and the hand-rolled setup has a
lot of steps that quietly come undone every time Steam updates the game. This
wraps the whole thing in two commands.

```sh
./valheim-sync setup     # once, on a new machine
./valheim-sync play      # every time you want to play
```

`play` runs the preflight first and offers to fix whatever drifted, so in
practice it is the only command you need.

## Commands

| Command | What it does |
| --- | --- |
| `setup` | First run: Rosetta, BepInEx, signing, mods, config, launch options |
| `sync` | Fetch the shared profile, install/update/remove mods, re-apply the loader patches and the ad-hoc signature |
| `preflight` | Check all of the above and report. Changes nothing |
| `play` | Preflight, then launch and confirm the chainloader came up |
| `status` | What the profile pins versus what is installed |
| `logs` | The BepInEx log — BepInEx 5 has no console on macOS |
| `steam-options` | The string to paste into Steam's launch options |

Useful flags: `-n/--dry-run`, `-y/--yes`, `-v/--verbose`, `--keep-config`,
`--foreground`, `--profile CODE`, `--game-dir PATH`.

## Updating the modpack

When someone changes the mod list in r2modman and re-exports the profile, put
the new code in `config.conf`, commit, and tell everyone to run
`./valheim-sync sync`. That is the whole workflow.

`config.conf` is the shared file. Anything machine-specific — a Valheim install
on another drive, say — goes in `~/.config/valheim-sync/local.conf` with the
same syntax, so nobody has to keep a local edit out of the repo.

## What preflight actually checks

Everything on this list breaks modding, and the first three get silently undone
by a Steam update or a "Verify integrity of game files":

1. **`run_bepinex.sh` targets `valheim.app` and forces x86_64.** The stock
   script prefers arm64. Under arm64 the preloader starts, the chainloader
   never runs, and nothing tells you — the log just isn't there.
2. **`valheim.app` carries an ad-hoc signature, not the shipped hardened one.**
   Hardened runtime makes dyld drop `DYLD_INSERT_LIBRARIES`, which is exactly
   how doorstop gets in. Verified by reading the real `codesign` flags:
   `flags=0x2(adhoc)` good, `flags=0x10000(runtime)` broken.
3. **No quarantine xattrs on the loader files.**
4. Rosetta 2 is installed, Valheim is where we think it is, the pinned BepInEx
   build is in place, every mod matches the profile, and Steam is running.

`sync` repairs 1–3 and the mod list on every run, so the answer to "Steam
updated and my mods are gone" is always just `./valheim-sync sync`.

## Two things worth knowing

**The BepInEx pack in the profile is deliberately skipped.**
The profile pins `denikson-BepInExPack_Valheim`, which is the Windows loader —
`winhttp.dll` and an x86-only doorstop. macOS needs the official
`BepInEx_macos_universal` build instead, which is what `BEPINEX_VERSION` in
`config.conf` points at (pinned by SHA-256). Every other mod in the profile is
a plain managed DLL and installs unchanged. `SKIP_PACKAGES` controls this.

**Mods are installed the way r2modman installs them**, because Thunderstore
packages are not uniform: some ship the DLL at the archive root, some use a
`plugins/` subfolder, some carry a `config/` tree, and `PONEIS-CraftFromChestsPlus`
is zipped with Windows path separators. Each package lands in
`BepInEx/plugins/<Namespace-ModName>/`, `patchers/` and `monomod/` go where they
belong, and the profile's exported config is applied last so the shared settings
always win.

## Where things live

| | |
| --- | --- |
| Game | `~/Library/Application Support/Steam/steamapps/common/Valheim` |
| Shared config | `config.conf` in this repo |
| Local overrides | `~/.config/valheim-sync/local.conf` |
| State | `~/Library/Application Support/valheim-sync` |
| Download cache | `~/Library/Caches/valheim-sync` |
| BepInEx log | `<game>/BepInEx/LogOutput.log` |
| Preloader crash log | `<game>/valheim.app/Contents/MacOS/preloader_*.log` |
| Game log | `~/Library/Logs/IronGate/Valheim/Player.log` |

Your previous `BepInEx/config` is copied into `<state>/backups/<timestamp>/`
before each sync overwrites it; the last five are kept.

## Requirements

macOS, Valheim installed through Steam, and the Xcode command line tools
(`xcode-select --install`) for `codesign`. Rosetta 2 is required on Apple
Silicon and is the one thing this tool cannot install without your password:

```sh
softwareupdate --install-rosetta --agree-to-license
```
