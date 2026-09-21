# shellcheck shell=bash
# Installing and repairing the macOS BepInEx loader.
#
# Three things have to be true for BepInEx to load on an Apple Silicon Mac, and
# all three get undone by a Steam update or a "Verify integrity of game files":
#
#   1. libdoorstop.dylib and run_bepinex.sh sit beside valheim.app.
#   2. run_bepinex.sh names valheim.app and forces x86_64. The stock script
#      prefers arm64, under which the preloader starts but the chainloader
#      silently never runs.
#   3. valheim.app carries an ad-hoc signature, not the shipped hardened-runtime
#      one. Hardened runtime makes dyld drop DYLD_INSERT_LIBRARIES, which is
#      exactly how doorstop gets in.

# ---------------------------------------------------------------- rosetta ----

is_apple_silicon() { [ "$(uname -m)" = "arm64" ]; }

have_rosetta() {
	is_apple_silicon || return 0
	/usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1
}

install_rosetta() {
	info "Installing Rosetta 2 (needs your admin password)"
	run softwareupdate --install-rosetta --agree-to-license
}

# ---------------------------------------------------------------- install ----

bepinex_installed_version() {
	[ -f "$BEPINEX_STAMP" ] && cat "$BEPINEX_STAMP"
}

bepinex_present() {
	[ -f "$DOORSTOP_LIB" ] && [ -f "$RUN_SCRIPT" ] && [ -f "$BEPINEX_DIR/core/BepInEx.Preloader.dll" ]
}

# install_bepinex — download the pinned macos-universal build and unpack it
# beside valheim.app. Idempotent; a no-op when the pinned version is in place.
install_bepinex() {
	if bepinex_present && [ "$(bepinex_installed_version)" = "$BEPINEX_VERSION" ]; then
		dbg "BepInEx $BEPINEX_VERSION already installed"
		return 0
	fi

	local name="BepInEx_macos_universal_$BEPINEX_VERSION.zip"
	local zip="$CACHE_DIR/$name"

	if [ ! -s "$zip" ]; then
		info "Downloading BepInEx $BEPINEX_VERSION (macos-universal)"
		local tmp; tmp="$(mktemp -t vsbep)"
		if ! curl -sSL --fail --max-time 300 -o "$tmp" "$BEPINEX_RELEASES/v$BEPINEX_VERSION/$name"; then
			rm -f "$tmp"; bad "could not download $name"; return 1
		fi
		mv "$tmp" "$zip"
	fi

	if [ -n "$BEPINEX_SHA256" ]; then
		local got; got="$(sha256_of "$zip")"
		if [ "$got" != "$BEPINEX_SHA256" ]; then
			rm -f "$zip"
			bad "BepInEx checksum mismatch (expected $BEPINEX_SHA256, got $got)"
			return 1
		fi
		dbg "BepInEx checksum verified"
	fi

	info "Installing BepInEx $BEPINEX_VERSION into $(tilde "$GAME_DIR")"
	if [ "$OPT_DRY_RUN" -eq 1 ]; then
		printf '  %s[dry-run]%s unzip %s -> %s\n' "$C_DIM" "$C_RESET" "$name" "$GAME_DIR"
	else
		unzip_quiet -o "$zip" -d "$GAME_DIR" || { bad "could not unpack BepInEx"; return 1; }
		printf '%s\n' "$BEPINEX_VERSION" > "$BEPINEX_STAMP"
	fi

	strip_quarantine "$BEPINEX_DIR" "$DOORSTOP_LIB" "$RUN_SCRIPT"
	run chmod +x "$RUN_SCRIPT"
	return 0
}

# ----------------------------------------------------------------- script ----

launcher_names_app() {
	[ -f "$RUN_SCRIPT" ] || return 1
	grep -qE '^executable_name="valheim\.app"' "$RUN_SCRIPT"
}

launcher_forces_x86() {
	[ -f "$RUN_SCRIPT" ] || return 1
	grep -q 'ARCHPREFERENCE="x86_64"' "$RUN_SCRIPT" &&
		! grep -q 'ARCHPREFERENCE="arm64,x86_64"' "$RUN_SCRIPT"
}

launcher_patched() {
	launcher_names_app && launcher_forces_x86
}

# patch_launcher — apply both edits to run_bepinex.sh, keeping a .orig copy.
patch_launcher() {
	if [ ! -f "$RUN_SCRIPT" ]; then
		# Under --dry-run BepInEx was never actually unpacked, so there is
		# nothing to patch yet; say what would happen instead of failing.
		if [ "$OPT_DRY_RUN" -eq 1 ]; then
			printf '  %s[dry-run]%s patch run_bepinex.sh once BepInEx is unpacked\n' "$C_DIM" "$C_RESET"
			return 0
		fi
		bad "run_bepinex.sh is missing"
		return 1
	fi
	launcher_patched && { dbg "run_bepinex.sh already patched"; return 0; }

	info "Patching run_bepinex.sh (target valheim.app, force x86_64)"
	[ -f "$RUN_SCRIPT.orig" ] || run cp "$RUN_SCRIPT" "$RUN_SCRIPT.orig"
	run sed -i '' \
		-e 's|^executable_name=.*|executable_name="valheim.app"|' \
		-e 's|ARCHPREFERENCE="arm64,x86_64"|ARCHPREFERENCE="x86_64"|' \
		"$RUN_SCRIPT" || return 1
	run chmod +x "$RUN_SCRIPT"

	if [ "$OPT_DRY_RUN" -eq 0 ] && ! launcher_patched; then
		bad "run_bepinex.sh did not take the patch — BepInEx may have changed its script"
		return 1
	fi
	return 0
}

# -------------------------------------------------------------- signature ----

app_codesign_flags() {
	[ -d "$APP" ] || return 1
	codesign -dv "$APP" 2>&1 | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p'
}

app_is_adhoc() {
	local flags; flags="$(app_codesign_flags)" || return 1
	case "$flags" in *adhoc*) return 0;; esac
	return 1
}

app_has_hardened_runtime() {
	local flags; flags="$(app_codesign_flags)" || return 1
	case "$flags" in *runtime*) return 0;; esac
	return 1
}

app_signature_valid() {
	[ -d "$APP" ] || return 1
	codesign --verify --deep "$APP" >/dev/null 2>&1
}

signature_ready() {
	app_is_adhoc && ! app_has_hardened_runtime && app_signature_valid
}

# resign_app — replace the shipped hardened signature with an ad-hoc one.
resign_app() {
	[ -d "$APP" ] || { bad "valheim.app not found in $(tilde "$GAME_DIR")"; return 1; }
	info "Re-signing valheim.app ad-hoc"
	run codesign --force --deep --sign - "$APP" || { bad "codesign failed"; return 1; }

	if [ "$OPT_DRY_RUN" -eq 0 ] && ! signature_ready; then
		bad "valheim.app still reports flags=$(app_codesign_flags) after re-signing"
		return 1
	fi
	return 0
}

# ensure_loader — everything under "the game can load mods at all".
ensure_loader() {
	install_bepinex || return 1
	patch_launcher || return 1
	strip_quarantine "$BEPINEX_DIR" "$DOORSTOP_LIB" "$RUN_SCRIPT"
	if ! signature_ready; then
		resign_app || return 1
	else
		dbg "valheim.app signature already ad-hoc"
	fi
	return 0
}
