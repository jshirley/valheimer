# shellcheck shell=bash
# Starting the game, and proving BepInEx actually came up.

steam_running() { pgrep -x steam_osx >/dev/null 2>&1; }

ensure_steam() {
	steam_running && return 0
	warn "Steam is not running; Valheim will not authenticate without it"
	if confirm "Start Steam now?"; then
		run open -a Steam || return 1
		local i
		for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
			steam_running && { ok "Steam is up"; return 0; }
			sleep 2
		done
		warn "Steam has not finished starting; launching anyway"
	fi
	return 0
}

# steam_launch_options — the string to paste into Steam's launch options, for
# anyone who would rather start the game from their library.
steam_launch_options() {
	printf '/usr/bin/arch -x86_64 /bin/bash "%s" %%command%%\n' "$RUN_SCRIPT"
}

# wait_for_chainloader TIMEOUT — watch LogOutput.log for a successful load.
wait_for_chainloader() {
	local timeout="$1" waited=0
	printf '  %swaiting for the chainloader%s' "$C_DIM" "$C_RESET"
	while [ "$waited" -lt "$timeout" ]; do
		if [ -f "$BEPINEX_LOG" ] && grep -q 'Chainloader startup complete' "$BEPINEX_LOG" 2>/dev/null; then
			printf '\r\033[K'
			local n
			n="$(grep -c 'Loading \[' "$BEPINEX_LOG" 2>/dev/null || echo 0)"
			ok "chainloader up — $n plugin(s) loaded"
			return 0
		fi
		printf '.'
		sleep 2
		waited=$((waited + 2))
	done
	printf '\r\033[K'
	warn "no 'Chainloader startup complete' after ${timeout}s"
	say "  Check the logs with: $(basename "$0") logs"
	return 1
}

# launch_game [--foreground] — start Valheim with BepInEx attached.
launch_game() {
	local foreground="${1:-0}"

	[ -x "$RUN_SCRIPT" ] || die "run_bepinex.sh is missing or not executable — run: $(basename "$0") sync"

	# The launch script resolves executable_name relative to the working
	# directory, so it has to be started from the game folder.
	if [ "$OPT_DRY_RUN" -eq 1 ]; then
		printf '  %s[dry-run]%s cd %s && /usr/bin/arch -x86_64 /bin/bash ./run_bepinex.sh\n' \
			"$C_DIM" "$C_RESET" "$GAME_DIR"
		return 0
	fi

	# A stale log would make the chainloader check pass instantly.
	[ -f "$BEPINEX_LOG" ] && mv "$BEPINEX_LOG" "$BEPINEX_LOG.prev"

	info "Launching Valheim"
	if [ "$foreground" -eq 1 ]; then
		cd "$GAME_DIR" || die "cannot enter $GAME_DIR"
		exec /usr/bin/arch -x86_64 /bin/bash ./run_bepinex.sh
	fi

	( cd "$GAME_DIR" && /usr/bin/arch -x86_64 /bin/bash ./run_bepinex.sh >/dev/null 2>&1 & )
	wait_for_chainloader 90
}

# show_logs [-f] — the BepInEx log, which is the only console macOS gives you.
show_logs() {
	local follow="${1:-0}"
	if [ ! -f "$BEPINEX_LOG" ]; then
		warn "no BepInEx log yet at $(tilde "$BEPINEX_LOG")"
		say "  The preloader writes its own crash log to:"
		say "    $(tilde "$APP")/Contents/MacOS/preloader_*.log"
		say "  and the game writes to ~/Library/Logs/IronGate/Valheim/Player.log"
		return 1
	fi
	if [ "$follow" -eq 1 ]; then
		tail -f "$BEPINEX_LOG"
	else
		tail -n 60 "$BEPINEX_LOG"
	fi
}
