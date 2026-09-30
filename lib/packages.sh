# shellcheck shell=bash
# Downloading Thunderstore packages and laying them out the way BepInEx wants.
#
# Thunderstore packages are not uniform. Some put the DLL at the archive root,
# some use a plugins/ subfolder, some ship a config/ tree, and at least one in
# this modpack writes its entries with Windows backslashes. r2modman smooths all
# of that over on Windows; this does the same on macOS.

# package_zip FULL_NAME VERSION — path of the cached archive, downloading once.
package_zip() {
	local full="$1" version="$2"
	local zip="$CACHE_DIR/packages/$full-$version.zip"

	if [ -s "$zip" ] && zip_valid "$zip"; then
		printf '%s\n' "$zip"
		return 0
	fi

	local url="$THUNDERSTORE_CDN/$full-$version.zip"
	local tmp; tmp="$(mktemp -t vspkg)"
	dbg "GET $url"
	if ! curl -sSL --fail --max-time 300 -o "$tmp" "$url"; then
		rm -f "$tmp"
		bad "download failed: $full $version"
		return 1
	fi
	if ! zip_valid "$tmp"; then
		rm -f "$tmp"
		bad "downloaded archive is corrupt: $full $version"
		return 1
	fi
	mv "$tmp" "$zip"
	printf '%s\n' "$zip"
}

# normalize_separators DIR — turn "plugins\Mod.dll" entries into real subpaths.
normalize_separators() {
	local root="$1" f dir base target
	find "$root" -type f -name '*\\*' 2>/dev/null | while IFS= read -r f; do
		dir="$(dirname "$f")"
		base="$(basename "$f")"
		target="$dir/$(printf '%s' "$base" | tr '\\' '/')"
		mkdir -p "$(dirname "$target")"
		mv "$f" "$target"
	done
}

# package_root DIR — the directory holding the package payload.
# Thunderstore packs for BepInEx itself nest everything one level down in a
# folder like BepInExPack_Valheim/; ordinary mods do not.
package_root() {
	local work="$1" entry
	for entry in "$work"/*; do
		[ -d "$entry" ] || continue
		case "$(basename "$entry")" in
			BepInExPack*) printf '%s\n' "$entry"; return 0;;
		esac
	done
	printf '%s\n' "$work"
}

# install_package FULL_NAME VERSION ZIP
install_package() {
	local full="$1" version="$2" zip="$3"
	local work root entry name
	work="$(mktemp -d -t vsinstall)" || return 1

	if ! unzip_quiet -o "$zip" -d "$work"; then
		rm -rf "$work"; bad "could not unpack $full"; return 1
	fi
	normalize_separators "$work"
	root="$(package_root "$work")"

	# Anything that is not one of the well-known trees is mod payload and lands
	# in the mod's own plugins folder, exactly as r2modman arranges it.
	local mod_dir="$PLUGINS_DIR/$full"
	run rm -rf "$mod_dir"
	run mkdir -p "$mod_dir"

	for entry in "$root"/* "$root"/.[!.]*; do
		[ -e "$entry" ] || continue
		name="$(basename "$entry")"
		case "$name" in
			plugins)
				copy_into "$entry" "$mod_dir" || return 1;;
			patchers)
				copy_into "$entry" "$BEPINEX_DIR/patchers/$full" || return 1;;
			monomod)
				copy_into "$entry" "$BEPINEX_DIR/monomod/$full" || return 1;;
			core)
				copy_into "$entry" "$BEPINEX_DIR/core" || return 1;;
			config)
				# Package defaults. The profile's own config is applied after
				# every package, so these never win over the shared settings.
				copy_into "$entry" "$CONFIG_DIR" || return 1;;
			BepInEx)
				copy_into "$entry" "$BEPINEX_DIR" || return 1;;
			*)
				run /usr/bin/ditto "$entry" "$mod_dir/$name" || return 1;;
		esac
	done

	rm -rf "$work"
	strip_quarantine "$mod_dir"
	record_installed "$full" "$version"
	return 0
}

# remove_package FULL_NAME — drop every tree a package could have written.
remove_package() {
	local full="$1" d
	for d in "$PLUGINS_DIR/$full" "$BEPINEX_DIR/patchers/$full" "$BEPINEX_DIR/monomod/$full"; do
		[ -d "$d" ] && run rm -rf "$d"
	done
	forget_installed "$full"
}

# sync_packages — bring BepInEx/plugins in line with the profile manifest.
# Echoes a short summary; returns 1 if anything failed.
sync_packages() {
	local wanted failed=0 full version have zip
	wanted="$(mktemp -t vswanted)"
	desired_mods | cut -f1,2 > "$wanted"

	local n_add=0 n_upd=0 n_fix=0 n_same=0 n_del=0 n_skip=0

	while IFS=$'\t' read -r full version; do
		[ -n "$full" ] || continue
		if is_skipped "$full"; then
			n_skip=$((n_skip + 1))
			dbg "skipping $full (handled by the macOS BepInEx build)"
			continue
		fi
		have="$(installed_version "$full")"
		if [ "$have" = "$version" ] && [ -d "$PLUGINS_DIR/$full" ]; then
			n_same=$((n_same + 1))
			continue
		fi
		zip="$(package_zip "$full" "$version")" || { failed=1; continue; }
		if [ "$have" = "$version" ]; then
			# Right version on record, but the files are gone — Steam's "verify
			# integrity" and a half-finished sync both land here.
			info "repair  $full  ${version}"
			n_fix=$((n_fix + 1))
		elif [ -n "$have" ]; then
			info "update  $full  ${have} -> ${version}"
			n_upd=$((n_upd + 1))
		else
			info "install $full  ${version}"
			n_add=$((n_add + 1))
		fi
		install_package "$full" "$version" "$zip" || failed=1
	done < "$wanted"

	# Anything installed that the profile no longer pins.
	if [ -f "$INSTALLED_TSV" ]; then
		while IFS=$'\t' read -r full version; do
			[ -n "$full" ] || continue
			if ! awk -F'\t' -v n="$full" '$1 == n { found = 1 } END { exit !found }' "$wanted"; then
				info "remove  $full  $version"
				remove_package "$full"
				n_del=$((n_del + 1))
			fi
		done < "$INSTALLED_TSV"
	fi

	rm -f "$wanted"

	SYNC_SUMMARY="$n_add installed, $n_upd updated, $n_del removed, $n_same already current"
	[ "$n_fix" -gt 0 ] && SYNC_SUMMARY="$n_add installed, $n_upd updated, $n_fix repaired, $n_del removed, $n_same already current"
	[ "$n_skip" -gt 0 ] && SYNC_SUMMARY="$SYNC_SUMMARY, $n_skip handled by the macOS loader"
	return $failed
}

# sync_profile_config PAYLOAD_DIR — apply the profile's exported configuration.
# The shared config is authoritative; whatever it replaces is backed up first.
sync_profile_config() {
	local payload="$1"
	local stamp backup
	stamp="$(date +%Y%m%d-%H%M%S)"
	backup="$STATE_DIR/backups/$stamp"

	if [ -d "$CONFIG_DIR" ] && [ -d "$payload/config" ]; then
		run mkdir -p "$backup"
		run /usr/bin/ditto "$CONFIG_DIR" "$backup/config" 2>/dev/null || true
		CONFIG_BACKUP="$backup/config"
		prune_backups 5
	fi

	if [ -d "$payload/config" ]; then
		copy_into "$payload/config" "$CONFIG_DIR" || return 1
	fi
	# Some exports also carry loose files under BepInEx/ (a mod's readme, a
	# config a mod insists on reading from its plugins folder). Keep them.
	if [ -d "$payload/BepInEx" ]; then
		copy_into "$payload/BepInEx" "$BEPINEX_DIR" || return 1
	fi
	strip_quarantine "$CONFIG_DIR"
	return 0
}
