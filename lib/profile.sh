# shellcheck shell=bash
# Fetching and parsing the r2modman / Thunderstore shared profile.
#
# The API hands back a text file: the literal line "#r2modman" followed by a
# base64 zip. Inside the zip, export.r2x lists the pinned mods and config/
# holds the exported BepInEx configuration.

PROFILE_NAME=""
PROFILE_FRESH=0   # 1 when the last fetch pulled a new payload, 0 on a 304

# fetch_profile — refresh $PROFILE_ZIP unless the server says it is unchanged.
fetch_profile() {
	local url="$PROFILE_API/$PROFILE_CODE/"
	local tmp code etag_new
	tmp="$(mktemp -t vsprofile)" || return 1
	# curl truncates its --etag-save file when the server answers 304, which
	# would throw away the tag we just matched and make the next sync download
	# the whole profile again. Save to a scratch file and keep it only on a 200.
	etag_new="$(mktemp -t vsetag)" || { rm -f "$tmp"; return 1; }

	local -a etag_args=()
	if [ -s "$PROFILE_ETAG" ] && [ -s "$PROFILE_ZIP" ] && [ -s "$PROFILE_R2X" ]; then
		etag_args=(--etag-compare "$PROFILE_ETAG")
	fi

	dbg "GET $url"
	code="$(curl -sSL --max-time 300 \
		"${etag_args[@]+"${etag_args[@]}"}" --etag-save "$etag_new" \
		-o "$tmp" -w '%{http_code}' "$url" 2>/dev/null)" || {
		rm -f "$tmp" "$etag_new"
		bad "could not reach Thunderstore (profile $PROFILE_CODE)"
		return 1
	}

	# 304 means the cached copy is still current; curl writes no output file.
	if [ "$code" = "304" ]; then
		rm -f "$tmp" "$etag_new"
		PROFILE_FRESH=0
		dbg "profile unchanged (304)"
		return 0
	fi

	if [ "$code" != "200" ]; then
		rm -f "$tmp" "$etag_new"
		case "$code" in
			404) bad "Thunderstore does not know profile code $PROFILE_CODE";;
			*)   bad "Thunderstore returned HTTP $code for profile $PROFILE_CODE";;
		esac
		return 1
	fi

	if [ ! -s "$tmp" ]; then
		rm -f "$tmp" "$etag_new"
		bad "Thunderstore returned an empty profile"
		return 1
	fi

	# "#r2modman\n" header, then base64.
	local head1; head1="$(head -n 1 "$tmp")"
	case "$head1" in
		'#r2modman'*) ;;
		*) rm -f "$tmp" "$etag_new"
		   bad "profile code $PROFILE_CODE did not return an r2modman export"; return 1;;
	esac

	local zip; zip="$(mktemp -t vsprofilezip)"
	if ! tail -n +2 "$tmp" | tr -d '\r\n' | base64 -D > "$zip" 2>/dev/null; then
		rm -f "$tmp" "$zip" "$etag_new"; bad "could not decode the profile payload"; return 1
	fi
	rm -f "$tmp"

	if ! zip_valid "$zip"; then
		rm -f "$zip" "$etag_new"; bad "decoded profile is not a valid zip"; return 1
	fi

	mv "$zip" "$PROFILE_ZIP"
	if ! unzip -p "$PROFILE_ZIP" export.r2x > "$PROFILE_R2X" 2>/dev/null; then
		rm -f "$etag_new"
		bad "profile archive has no export.r2x"
		return 1
	fi

	# Only now is the cache complete enough for the tag to stand for it.
	if [ -s "$etag_new" ]; then
		mv "$etag_new" "$PROFILE_ETAG"
	else
		rm -f "$etag_new" "$PROFILE_ETAG"
	fi
	PROFILE_FRESH=1
	return 0
}

# have_profile — true when a cached profile manifest exists.
have_profile() { [ -s "$PROFILE_R2X" ]; }

# profile_name — the name the exporter gave the profile.
profile_name() {
	have_profile || return 0
	awk -F': *' '/^profileName:/ { sub(/\r$/,"",$2); print $2; exit }' "$PROFILE_R2X"
}

# profile_mods — one "full_name<TAB>version<TAB>enabled" line per pinned mod.
profile_mods() {
	have_profile || return 0
	awk '
		function val(line,   v) { v = line; sub(/^[^:]*:[ \t]*/, "", v); gsub(/[\r"]/, "", v); return v }
		function flush() {
			if (name != "") printf "%s\t%s.%s.%s\t%s\n", name, major, minor, patch, enabled
			name = ""; major = "0"; minor = "0"; patch = "0"; enabled = "true"
		}
		/^[ \t]*-[ \t]*name:[ \t]*/ {
			flush()
			name = $0
			sub(/^[ \t]*-[ \t]*name:[ \t]*/, "", name)
			gsub(/[\r"]/, "", name)
			next
		}
		name == "" { next }
		/^[ \t]*major:/   { major   = val($0); next }
		/^[ \t]*minor:/   { minor   = val($0); next }
		/^[ \t]*patch:/   { patch   = val($0); next }
		/^[ \t]*enabled:/ { enabled = val($0); next }
		END { flush() }
	' "$PROFILE_R2X"
}

# profile_enabled_mods — the mods we are actually meant to install.
profile_enabled_mods() {
	profile_mods | awk -F'\t' '$3 == "true" { print $1 "\t" $2 }'
}

# extract_profile_configs DEST_TMP — unpack the profile's config payload.
# Returns 0 and echoes the temp directory on stdout.
extract_profile_payload() {
	local work
	work="$(mktemp -d -t vsprofx)" || return 1
	if ! unzip_quiet -o "$PROFILE_ZIP" -d "$work"; then
		rm -rf "$work"; return 1
	fi
	printf '%s\n' "$work"
}
