# shellcheck shell=bash
# Shared helpers: output, config, small filesystem utilities.

VS_DEFAULT_GAME_DIR="$HOME/Library/Application Support/Steam/steamapps/common/Valheim"
STATE_DIR="${VALHEIM_SYNC_STATE:-$HOME/Library/Application Support/valheim-sync}"
CACHE_DIR="${VALHEIM_SYNC_CACHE:-$HOME/Library/Caches/valheim-sync}"
LOCAL_CONF="${VALHEIM_SYNC_CONF:-$HOME/.config/valheim-sync/local.conf}"

THUNDERSTORE_CDN="https://gcdn.thunderstore.io/live/repository/packages"
PROFILE_API="https://thunderstore.io/api/experimental/legacyprofile/get"
BEPINEX_RELEASES="https://github.com/BepInEx/BepInEx/releases/download"

# Global flags, set by argument parsing in the entrypoint.
OPT_DRY_RUN=0
OPT_YES=0
OPT_VERBOSE=0

# ---------------------------------------------------------------- output ----

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
	C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
	C_RESET=''; C_BOLD=''; C_DIM=''
	C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s%s%s %s\n' "$C_BLUE" '==>' "$C_RESET" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
bad()  { printf '  %s✘%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
dbg()  { [ "$OPT_VERBOSE" -eq 1 ] && printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; return 0; }
die()  { printf '%s✘%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 2; }

# Shorten $HOME to ~ for display.
tilde() { case "$1" in "$HOME"/*) printf '~%s\n' "${1#"$HOME"}";; *) printf '%s\n' "$1";; esac; }

# confirm PROMPT — yes under --yes, no when stdin is not a terminal.
confirm() {
	[ "$OPT_YES" -eq 1 ] && return 0
	[ -t 0 ] || return 1
	local reply
	printf '  %s?%s %s [y/N] ' "$C_BOLD" "$C_RESET" "$1"
	read -r reply
	case "$reply" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac
}

# run CMD... — echo and skip under --dry-run, otherwise execute.
run() {
	if [ "$OPT_DRY_RUN" -eq 1 ]; then
		printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*"
		return 0
	fi
	"$@"
}

# ---------------------------------------------------------------- config ----

load_config() {
	# shellcheck source=/dev/null
	[ -f "$VS_ROOT/config.conf" ] || die "missing $VS_ROOT/config.conf"
	. "$VS_ROOT/config.conf"
	# shellcheck source=/dev/null
	[ -f "$LOCAL_CONF" ] && . "$LOCAL_CONF"

	GAME_DIR="${OPT_GAME_DIR:-${GAME_DIR:-$VS_DEFAULT_GAME_DIR}}"
	GAME_DIR="${GAME_DIR%/}"
	PROFILE_CODE="${OPT_PROFILE_CODE:-${PROFILE_CODE:-}}"
	BEPINEX_VERSION="${BEPINEX_VERSION:-5.4.23.5}"
	BEPINEX_SHA256="${BEPINEX_SHA256:-}"
	SKIP_PACKAGES="${SKIP_PACKAGES:-}"

	APP="$GAME_DIR/valheim.app"
	BEPINEX_DIR="$GAME_DIR/BepInEx"
	PLUGINS_DIR="$BEPINEX_DIR/plugins"
	CONFIG_DIR="$BEPINEX_DIR/config"
	RUN_SCRIPT="$GAME_DIR/run_bepinex.sh"
	DOORSTOP_LIB="$GAME_DIR/libdoorstop.dylib"
	BEPINEX_LOG="$BEPINEX_DIR/LogOutput.log"

	INSTALLED_TSV="$STATE_DIR/installed.tsv"
	OVERLAY_TSV="$STATE_DIR/overlay.tsv"
	DROPPED_TXT="$STATE_DIR/dropped.txt"
	PROFILE_ZIP="$STATE_DIR/profile.zip"
	PROFILE_R2X="$STATE_DIR/profile.r2x"
	PROFILE_ETAG="$STATE_DIR/profile.etag"
	BEPINEX_STAMP="$STATE_DIR/bepinex-version"

	[ -n "$PROFILE_CODE" ] || die "no PROFILE_CODE set — edit config.conf or pass --profile CODE"
	mkdir -p "$STATE_DIR" "$CACHE_DIR/packages" || die "cannot create state directories"
}

# ------------------------------------------------------------ filesystem ----

# copy_into SRC_DIR DEST_DIR — merge the *contents* of SRC_DIR into DEST_DIR.
copy_into() {
	local src="$1" dest="$2"
	run mkdir -p "$dest" || return 1
	run /usr/bin/ditto "$src" "$dest"
}

# strip_quarantine PATH... — remove com.apple.quarantine and friends, quietly.
strip_quarantine() {
	local p
	for p in "$@"; do
		[ -e "$p" ] || continue
		run /usr/bin/xattr -cr "$p" 2>/dev/null || true
	done
}

sha256_of() { /usr/bin/shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

# prune_backups KEEP — the Seasonality config alone is 8MB, so old config
# snapshots are not worth hoarding.
prune_backups() {
	local keep="$1" dir="$STATE_DIR/backups" old
	[ -d "$dir" ] || return 0
	ls -1 "$dir" 2>/dev/null | sort -r | tail -n "+$((keep + 1))" | while IFS= read -r old; do
		[ -n "$old" ] && rm -rf "${dir:?}/${old:?}"
	done
}

# unzip exits 1 for warnings and 2+ for real errors. At least one package in
# this modpack is zipped with Windows path separators, which macOS unzip
# converts correctly while still warning about it, so 1 has to count as success.
unzip_quiet() { local rc; unzip -qq "$@" 2>/dev/null; rc=$?; [ "$rc" -le 1 ]; }
zip_valid()   { local rc; unzip -tqq "$1" >/dev/null 2>&1; rc=$?; [ "$rc" -le 1 ]; }

# list_skipped — normalized membership test for SKIP_PACKAGES.
is_skipped() {
	local want="$1" p
	for p in $SKIP_PACKAGES; do
		[ "$p" = "$want" ] && return 0
	done
	return 1
}

# ----------------------------------------------------------- state files ----

# installed_version FULL_NAME — echoes the recorded version, empty if absent.
installed_version() {
	[ -f "$INSTALLED_TSV" ] || return 0
	awk -F'\t' -v n="$1" '$1 == n { print $2; exit }' "$INSTALLED_TSV"
}

# record_installed FULL_NAME VERSION — upsert into the state table.
record_installed() {
	[ "$OPT_DRY_RUN" -eq 1 ] && return 0
	local tmp; tmp="$(mktemp)"
	if [ -f "$INSTALLED_TSV" ]; then
		awk -F'\t' -v n="$1" '$1 != n' "$INSTALLED_TSV" > "$tmp"
	fi
	printf '%s\t%s\n' "$1" "$2" >> "$tmp"
	sort -o "$tmp" "$tmp"
	mv "$tmp" "$INSTALLED_TSV"
}

# forget_installed FULL_NAME
forget_installed() {
	[ "$OPT_DRY_RUN" -eq 1 ] && return 0
	[ -f "$INSTALLED_TSV" ] || return 0
	local tmp; tmp="$(mktemp)"
	awk -F'\t' -v n="$1" '$1 != n' "$INSTALLED_TSV" > "$tmp"
	mv "$tmp" "$INSTALLED_TSV"
}
