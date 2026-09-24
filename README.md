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
| `add MOD...` | Add a mod and its dependencies, no r2modman needed |
| `drop MOD...` | Remove a mod |
| `publish` | Upload the current mod list and get a code to share |
| `server [add\|status\|sync\|tree\|forget]` | Inspect and sync the dedicated server over FTP |
| `logs` | The BepInEx log — BepInEx 5 has no console on macOS |
| `steam-options` | The string to paste into Steam's launch options |

Useful flags: `-n/--dry-run`, `-y/--yes`, `-v/--verbose`, `--keep-config`,
`--foreground`, `--profile CODE`, `--game-dir PATH`, `--name`, `--no-config`,
`--to-server`, `--from-server`.

## Updating the modpack

When someone changes the mod list in r2modman and re-exports the profile, put
the new code in `config.conf`, commit, and tell everyone to run
`./valheim-sync sync`. That is the whole workflow.

`config.conf` is the shared file. Anything machine-specific — a Valheim install
on another drive, say — goes in `~/.config/valheim-sync/local.conf` with the
same syntax, so nobody has to keep a local edit out of the repo.

## Changing the modpack from a Mac

You do not need r2modman, or a Windows machine, to change the mod list and hand
the group a new code:

```sh
./valheim-sync add Advize-PlantEasily        # latest version
./valheim-sync add RustyMods-Almanac@3.7.94  # a specific version
./valheim-sync drop TenebrisReverie-ResourceBoost
./valheim-sync publish                       # -> a code anyone can import
```

A mod can be named as `Namespace-ModName`, `Namespace-ModName-1.2.3`,
`Namespace-ModName@1.2.3`, or a thunderstore.io package URL. Dependencies are
resolved recursively from Thunderstore's API and pulled in automatically.

`add` and `drop` record what you changed in a **local overlay** on top of the
shared profile, so a later `sync` will not undo your changes — it merges the
profile with your overlay. `status` labels each mod `profile` or `local`, and
preflight reminds you when you have local changes nobody else has:

```
! local changes         1 not in the shared profile — run: valheim-sync publish
```

`publish` builds the same export format r2modman produces — the full mod list
(including the Windows BepInEx pack, so Windows players who import the code
still get a loader) plus your `BepInEx/config` — uploads it to Thunderstore, and
prints the new code. Use `--no-config` to publish the mod list alone, and
`--name` to rename the profile.

Because the returned code is what everyone else pins, `publish` then offers to
write it into `config.conf` and fold your overlay in, leaving you with nothing
local and a one-line commit to push. On Windows, your friends import it with
r2modman → Import/Update → Import from code; on a Mac, they just pull and run
`./valheim-sync sync`.

A published code is public to anyone who has it, so `publish` always asks before
uploading.

## Checking the game server over FTP

Hosts like Host Havoc give you the server's files over FTP. Tell valheim-sync
the login once, and it can compare the server's mods with yours:

```sh
./valheim-sync server add      # host, port, user, password -> Keychain
./valheim-sync server status   # every mod: local version vs server version
./valheim-sync server sync     # fix differences, asking which way each time
./valheim-sync server tree     # browse the server's directory tree
```

The password goes in your macOS Keychain; the host, user and path go in
`~/.config/valheim-sync/server.conf` (mode 600, outside the repo). `server
forget` removes both.

`status` reads `BepInEx/plugins` on the server and lists each mod as `ok`,
`version differs`, `not on server`, `only on server` or `server version
unknown`. Versions come from the `manifest.json` inside each
`Namespace-ModName` folder, which is what r2modman and this tool both leave
there. A folder without one (or with a hand-made name) can be seen but not
version-checked; loose DLLs are listed and never touched.

`server sync` asks about every difference:

| Difference | `l` local wins | `s` server wins |
| --- | --- | --- |
| version differs | upload your version to the server | install the server's version here |
| not on server | upload it | drop it locally |
| only on server | delete it from the server (asks again) | add it to your local list |

A capital `L` or `S` answers the same way for everything left. For scripts,
`--to-server` or `--from-server` skips the questions (`--yes` requires one of
them). Uploads replace the mod's whole folder using the same layout a local
install produces, and `-n` shows what would happen. "Server wins" goes through
the local overlay, so `publish` is how you then share it with the group. The
game server needs a restart to load anything you uploaded.

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
| Server login | `~/.config/valheim-sync/server.conf` (+ Keychain) |
| Local overlay | `<state>/overlay.tsv`, `<state>/dropped.txt` |
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
