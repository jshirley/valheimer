# shellcheck shell=bash
# The preflight check. Read-only: it reports, it never repairs.
#
# Exit status: 0 everything ready, 1 something needs `valheim-sync sync`,
# 2 something this tool cannot fix on its own.

PF_FAIL=0     # blocking, fixable by us
PF_BLOCK=0    # blocking, needs the user
PF_WARN=0
PF_HINTS=""

pf_reset() { PF_FAIL=0; PF_BLOCK=0; PF_WARN=0; PF_HINTS=""; }

pf_line() { printf '  %s%s%s %-21s %s\n' "$2" "$1" "$C_RESET" "$3" "$4"; }
pf_ok()    { pf_line '✔' "$C_GREEN"  "$1" "$2"; }
pf_warn()  { PF_WARN=$((PF_WARN + 1));   pf_line '!' "$C_YELLOW" "$1" "$2"; }
pf_fix()   { PF_FAIL=$((PF_FAIL + 1));   pf_line '✘' "$C_RED"    "$1" "$2"; }
pf_block() { PF_BLOCK=$((PF_BLOCK + 1)); pf_line '✘' "$C_RED"    "$1" "$2"; }
pf_hint()  { PF_HINTS="$PF_HINTS$1"$'\n'; }

# ------------------------------------------------------------------ checks --

pfc_tools() {
	local missing="" t
	for t in curl unzip zip codesign shasum sed awk ditto xattr plutil; do
		command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
	done
	if [ -n "$missing" ]; then
		pf_block "command line tools" "missing:$missing"
		pf_hint "Install the Xcode command line tools: xcode-select --install"
	else
		pf_ok "command line tools" "all present"
	fi
}

pfc_game() {
	if [ ! -d "$GAME_DIR" ]; then
		pf_block "Valheim install" "not found at $(tilde "$GAME_DIR")"
		pf_hint "Install Valheim through Steam, or set GAME_DIR in $(tilde "$LOCAL_CONF")"
		return
	fi
	if [ ! -d "$APP" ]; then
		pf_block "Valheim install" "$(tilde "$GAME_DIR") has no valheim.app"
		pf_hint "Point GAME_DIR at the folder that contains valheim.app"
		return
	fi
	pf_ok "Valheim install" "$(tilde "$GAME_DIR")"
}

pfc_rosetta() {
	if ! is_apple_silicon; then
		pf_ok "Rosetta 2" "not needed on Intel"
		return
	fi
	if have_rosetta; then
		pf_ok "Rosetta 2" "installed"
	else
		pf_block "Rosetta 2" "not installed — BepInEx only loads under x86_64"
		pf_hint "Install it once: softwareupdate --install-rosetta --agree-to-license"
	fi
}

pfc_bepinex() {
	if ! bepinex_present; then
		pf_fix "BepInEx loader" "not installed"
		return
	fi
	local have; have="$(bepinex_installed_version)"
	if [ -n "$have" ] && [ "$have" != "$BEPINEX_VERSION" ]; then
		pf_fix "BepInEx loader" "$have installed, $BEPINEX_VERSION pinned"
	else
		pf_ok "BepInEx loader" "${have:-$BEPINEX_VERSION} (macos-universal)"
	fi
}

pfc_launcher() {
	if [ ! -f "$RUN_SCRIPT" ]; then
		pf_fix "launch script" "run_bepinex.sh missing"
		return
	fi
	local problems=""
	launcher_names_app  || problems="does not target valheim.app"
	if ! launcher_forces_x86; then
		[ -n "$problems" ] && problems="$problems; "
		problems="${problems}still prefers arm64"
	fi
	if [ ! -x "$RUN_SCRIPT" ]; then
		[ -n "$problems" ] && problems="$problems; "
		problems="${problems}not executable"
	fi
	if [ -n "$problems" ]; then
		pf_fix "launch script" "$problems"
	else
		pf_ok "launch script" "targets valheim.app, forces x86_64"
	fi
}

pfc_signature() {
	[ -d "$APP" ] || return 0
	local flags; flags="$(app_codesign_flags)"
	if app_has_hardened_runtime; then
		pf_fix "code signature" "hardened runtime (flags=$flags) blocks doorstop"
		return
	fi
	if ! app_is_adhoc; then
		pf_fix "code signature" "unexpected signature (flags=${flags:-none})"
		return
	fi
	if ! app_signature_valid; then
		pf_fix "code signature" "ad-hoc but fails verification"
		return
	fi
	pf_ok "code signature" "ad-hoc (flags=$flags)"
}

pfc_quarantine() {
	local found=0 p
	for p in "$RUN_SCRIPT" "$DOORSTOP_LIB"; do
		[ -e "$p" ] || continue
		if /usr/bin/xattr "$p" 2>/dev/null | grep -q com.apple.quarantine; then
			found=1
		fi
	done
	if [ "$found" -eq 1 ]; then
		pf_fix "quarantine flags" "loader files are quarantined"
	else
		pf_ok "quarantine flags" "clear"
	fi
}

pfc_profile() {
	if ! have_profile; then
		pf_fix "modpack profile" "never fetched"
		return
	fi
	local name age
	name="$(profile_name)"
	age="$(profile_age_human)"
	pf_ok "modpack profile" "${name:-unnamed} · fetched $age"
}

profile_age_human() {
	[ -f "$PROFILE_R2X" ] || { printf 'never\n'; return; }
	local mtime now delta
	mtime="$(stat -f %m "$PROFILE_R2X" 2>/dev/null || echo 0)"
	now="$(date +%s)"
	delta=$((now - mtime))
	if   [ "$delta" -lt 120 ];    then printf 'just now\n'
	elif [ "$delta" -lt 7200 ];   then printf '%dm ago\n' $((delta / 60))
	elif [ "$delta" -lt 172800 ]; then printf '%dh ago\n' $((delta / 3600))
	else printf '%dd ago\n' $((delta / 86400)); fi
}

pfc_mods() {
	have_profile || return 0
	local wanted have full version n_want=0 n_bad=0 detail=""
	wanted="$(mktemp -t vspfmods)"
	desired_mods | cut -f1,2 > "$wanted"

	while IFS=$'\t' read -r full version; do
		[ -n "$full" ] || continue
		is_skipped "$full" && continue
		n_want=$((n_want + 1))
		have="$(installed_version "$full")"
		if [ -z "$have" ]; then
			n_bad=$((n_bad + 1)); detail="${detail}${detail:+, }$full (missing)"
		elif [ "$have" != "$version" ]; then
			n_bad=$((n_bad + 1)); detail="${detail}${detail:+, }$full (${have} -> ${version})"
		elif [ ! -d "$PLUGINS_DIR/$full" ]; then
			n_bad=$((n_bad + 1)); detail="${detail}${detail:+, }$full (files gone)"
		fi
	done < "$wanted"

	# Installed but no longer in the profile.
	if [ -f "$INSTALLED_TSV" ]; then
		while IFS=$'\t' read -r full version; do
			[ -n "$full" ] || continue
			awk -F'\t' -v n="$full" '$1 == n { f = 1 } END { exit !f }' "$wanted" && continue
			n_bad=$((n_bad + 1)); detail="${detail}${detail:+, }$full (extra)"
		done < "$INSTALLED_TSV"
	fi
	rm -f "$wanted"

	local overlay; overlay="$(overlay_count)"
	local scope="the profile"
	[ "$overlay" -gt 0 ] && scope="the profile + $overlay local change(s)"

	if [ "$n_bad" -eq 0 ]; then
		pf_ok "mods" "$n_want in step with $scope"
	else
		pf_fix "mods" "$n_bad of $n_want out of step"
		pf_hint "Out of step: $detail"
	fi
	if [ "$overlay" -gt 0 ]; then
		pf_warn "local changes" "$overlay not in the shared profile — run: $(basename "$0") publish"
	fi
}

pfc_steam() {
	if pgrep -x steam_osx >/dev/null 2>&1; then
		pf_ok "Steam" "running"
	else
		pf_warn "Steam" "not running — start it before you launch"
	fi
}

# ------------------------------------------------------------------- runner --

# preflight [--quiet] — run every check, print a report, set PF_* counters.
preflight() {
	pf_reset
	local name; name="$(profile_name)"

	printf '\n%sValheim preflight%s  %s%s · profile %s%s\n\n' \
		"$C_BOLD" "$C_RESET" "$C_DIM" "$(tilde "$GAME_DIR")" \
		"${name:-$PROFILE_CODE}" "$C_RESET"

	pfc_tools
	pfc_game
	pfc_rosetta
	pfc_bepinex
	pfc_launcher
	pfc_signature
	pfc_quarantine
	pfc_profile
	pfc_mods
	pfc_steam

	printf '\n'
	if [ -n "$PF_HINTS" ]; then
		printf '%s' "$PF_HINTS" | while IFS= read -r line; do
			[ -n "$line" ] && printf '  %s→ %s%s\n' "$C_DIM" "$line" "$C_RESET"
		done
		printf '\n'
	fi

	if [ "$PF_BLOCK" -gt 0 ]; then
		bad "$PF_BLOCK problem(s) need you — see the notes above"
		return 2
	fi
	if [ "$PF_FAIL" -gt 0 ]; then
		warn "$PF_FAIL problem(s) — run: $(basename "$0") sync"
		return 1
	fi
	ok "ready to play"
	return 0
}
