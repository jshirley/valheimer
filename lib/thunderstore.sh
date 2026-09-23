# shellcheck shell=bash
# Talking to Thunderstore directly, so you can add a mod and hand the group a
# new profile code without going near r2modman.
#
# Two endpoints do the work:
#   GET  /api/experimental/package/<ns>/<name>/[<version>/]  metadata + deps
#   POST /api/experimental/legacyprofile/create/             returns {"key": …}
#
# JSON is read with plutil, which ships with macOS, so this stays dependency
# free — no jq, no python.

TS_PACKAGE_API="https://thunderstore.io/api/experimental/package"
TS_PROFILE_CREATE="https://thunderstore.io/api/experimental/legacyprofile/create/"

json_raw() { /usr/bin/plutil -extract "$2" raw -o - -- "$1" 2>/dev/null; }

# json_list FILE KEYPATH — one element per line, for a JSON array of strings.
# plutil writes no trailing newline, so the last element would arrive as a
# partial line that `while read` drops on the floor. awk's print fixes that.
json_list() {
	/usr/bin/plutil -extract "$2" json -o - -- "$1" 2>/dev/null |
		tr -d '[]"' | tr ',' '\n' | awk 'NF { print }'
}

# parse_spec SPEC — echo "namespace<TAB>name<TAB>version" ("" version = latest).
# Accepts Namespace-ModName, Namespace-ModName-1.2.3, Namespace-ModName@1.2.3
# and thunderstore.io package URLs.
parse_spec() {
	local s="$1" ns name ver="" rest
	case "$s" in
		http://*|https://*)
			s="$(printf '%s' "$s" | sed -e 's|^https\{0,1\}://[^/]*/||' -e 's|/*$||')"
			s="${s#c/*/p/}"
			s="${s#package/}"
			case "$s" in */*) ;; *) return 1;; esac
			ns="${s%%/*}"; rest="${s#*/}"
			name="${rest%%/*}"
			if [ "$rest" != "$name" ]; then ver="${rest#*/}"; ver="${ver%%/*}"; fi
			;;
		*)
			case "$s" in *@*) ver="${s##*@}"; s="${s%@*}";; esac
			# A trailing -MAJOR.MINOR.PATCH is a version, not part of the name.
			if [ -z "$ver" ]; then
				case "${s##*-}" in
					[0-9]*.[0-9]*.[0-9]*) ver="${s##*-}"; s="${s%-*}";;
				esac
			fi
			case "$s" in *-*) ;; *) return 1;; esac
			ns="${s%%-*}"; name="${s#*-}"
			;;
	esac
	[ -n "$ns" ] && [ -n "$name" ] || return 1
	printf '%s\t%s\t%s\n' "$ns" "$name" "$ver"
}

# ts_package_json NS NAME [VERSION] — cache the metadata and echo its path.
ts_package_json() {
	local ns="$1" name="$2" ver="${3:-}"
	local url="$TS_PACKAGE_API/$ns/$name/" key="$ns-$name"
	if [ -n "$ver" ]; then url="$url$ver/"; key="$key-$ver"; fi
	local out="$CACHE_DIR/meta/$key.json"
	mkdir -p "$CACHE_DIR/meta"

	# Pinned versions are immutable; "latest" goes stale, so re-check hourly.
	local stale=1
	if [ -s "$out" ]; then
		if [ -n "$ver" ] || [ -z "$(find "$out" -mmin +60 2>/dev/null)" ]; then
			stale=0
		fi
	fi

	if [ "$stale" -eq 1 ]; then
		local tmp code; tmp="$(mktemp -t vsmeta)"
		dbg "GET $url"
		code="$(curl -sSL --max-time 60 -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null)" || {
			rm -f "$tmp"; bad "could not reach Thunderstore"; return 1
		}
		if [ "$code" = "404" ]; then
			rm -f "$tmp"
			if [ -n "$ver" ]; then
				bad "Thunderstore has no $ns-$name version $ver"
			else
				bad "Thunderstore has no package $ns-$name"
			fi
			return 1
		fi
		[ "$code" = "200" ] || { rm -f "$tmp"; bad "Thunderstore returned HTTP $code for $ns-$name"; return 1; }
		mv "$tmp" "$out"
	fi
	printf '%s\n' "$out"
}

# ts_resolve SPEC — echo "full_name<TAB>version" for the mod and, recursively,
# every dependency it declares. The directly requested mod wins any version
# disagreement, because breadth-first order puts it first.
ts_resolve() {
	local queue next resolved item ns name ver meta actual dep depth=0
	queue="$(mktemp -t vsq)"; resolved="$(mktemp -t vsr)"
	printf '%s\n' "$1" > "$queue"

	while [ -s "$queue" ] && [ "$depth" -lt 12 ]; do
		next="$(mktemp -t vsn)"
		# `|| [ -n "$item" ]` so a file with no trailing newline still yields
		# its last line.
		while IFS= read -r item || [ -n "$item" ]; do
			[ -n "$item" ] || continue
			IFS=$'\t' read -r ns name ver <<EOF
$(parse_spec "$item")
EOF
			if [ -z "${ns:-}" ] || [ -z "${name:-}" ]; then
				bad "cannot make sense of '$item' — expected Namespace-ModName"
				rm -f "$queue" "$next" "$resolved"; return 1
			fi
			# Already pulled in at some version; first one wins.
			if awk -F'\t' -v n="$ns-$name" '$1 == n { f = 1 } END { exit !f }' "$resolved"; then
				continue
			fi
			meta="$(ts_package_json "$ns" "$name" "$ver")" || {
				rm -f "$queue" "$next" "$resolved"; return 1
			}
			if [ -n "$ver" ]; then
				actual="$(json_raw "$meta" version_number)"
				json_list "$meta" dependencies >> "$next"
			else
				actual="$(json_raw "$meta" latest.version_number)"
				json_list "$meta" latest.dependencies >> "$next"
			fi
			[ -n "$actual" ] || { bad "no version information for $ns-$name"; rm -f "$queue" "$next" "$resolved"; return 1; }
			printf '%s-%s\t%s\n' "$ns" "$name" "$actual" >> "$resolved"
		done < "$queue"
		mv "$next" "$queue"
		depth=$((depth + 1))
	done

	awk -F'\t' '!seen[$1]++' "$resolved"
	rm -f "$queue" "$resolved"
}

# ------------------------------------------------------------- publishing ----

# publish_entries — every mod line the published profile should carry.
# The loader packages we skip on macOS still belong in the export, or Windows
# players who import the code get no BepInEx at all.
publish_entries() {
	local packs full version
	packs="$(mktemp -t vspacks)"

	if have_profile; then
		profile_mods | while IFS=$'\t' read -r full version _; do
			[ -n "$full" ] || continue
			if is_skipped "$full"; then printf '%s\t%s\n' "$full" "$version"; fi
		done > "$packs"
	fi
	# Publishing a profile that never had one: fall back to the pinned pack.
	if [ ! -s "$packs" ] && [ -n "$SKIP_PACKAGES" ] && [ -n "${BEPINEX_PACK_FALLBACK:-}" ]; then
		printf '%s\t%s\n' "${BEPINEX_PACK_FALLBACK%-*}" "${BEPINEX_PACK_FALLBACK##*-}" > "$packs"
	fi

	cat "$packs"
	rm -f "$packs"

	# Skipped packages were emitted above, verbatim from the profile; don't
	# let desired_mods list them a second time.
	desired_mods | while IFS=$'\t' read -r full version _; do
		[ -n "$full" ] || continue
		is_skipped "$full" && continue
		printf '%s\t%s\n' "$full" "$version"
	done
}

# write_r2x NAME OUTFILE — the export manifest r2modman reads back.
write_r2x() {
	local name="$1" out="$2" full version maj min pat rest
	{
		printf 'profileName: %s\n' "$name"
		printf 'mods:\n'
		publish_entries | while IFS=$'\t' read -r full version; do
			[ -n "$full" ] || continue
			maj="${version%%.*}"; rest="${version#*.}"
			min="${rest%%.*}"; pat="${rest#*.}"; pat="${pat%%.*}"
			case "$maj" in ''|*[!0-9]*) maj=0;; esac
			case "$min" in ''|*[!0-9]*) min=0;; esac
			case "$pat" in ''|*[!0-9]*) pat=0;; esac
			printf '  - name: %s\n    version:\n      major: %s\n      minor: %s\n      patch: %s\n    enabled: true\n' \
				"$full" "$maj" "$min" "$pat"
		done
	} > "$out"
}

# build_profile_payload NAME OUTZIP [--no-config]
build_profile_payload() {
	local name="$1" outzip="$2" with_config="${3:-1}"
	local stage; stage="$(mktemp -d -t vspub)" || return 1

	write_r2x "$name" "$stage/export.r2x" || { rm -rf "$stage"; return 1; }

	if [ "$with_config" -eq 1 ] && [ -d "$CONFIG_DIR" ]; then
		/usr/bin/ditto "$CONFIG_DIR" "$stage/config" 2>/dev/null || true
	fi

	# Configs some mods insist on reading from the plugins folder itself.
	if [ -d "$PLUGINS_DIR" ]; then
		local loose; loose="$(find "$PLUGINS_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
		if [ "$loose" -gt 0 ]; then
			mkdir -p "$stage/BepInEx/plugins"
			find "$PLUGINS_DIR" -maxdepth 1 -type f -exec cp {} "$stage/BepInEx/plugins/" \; 2>/dev/null || true
		fi
	fi

	rm -f "$outzip"
	( cd "$stage" && zip -qr "$outzip" . ) || { rm -rf "$stage"; bad "could not build the profile archive"; return 1; }
	rm -rf "$stage"
	[ -s "$outzip" ]
}

# upload_profile ZIP — POST it, echo the new code.
upload_profile() {
	local zip="$1" body resp code key
	body="$(mktemp -t vsbody)"; resp="$(mktemp -t vsresp)"

	{ printf '#r2modman\n'; base64 -i "$zip" | tr -d '\n'; } > "$body" || {
		rm -f "$body" "$resp"; bad "could not encode the profile"; return 1
	}

	code="$(curl -sS -X POST --max-time 300 \
		-H 'Content-Type: application/octet-stream' \
		--data-binary "@$body" -o "$resp" -w '%{http_code}' "$TS_PROFILE_CREATE" 2>/dev/null)" || {
		rm -f "$body" "$resp"; bad "could not reach Thunderstore"; return 1
	}
	rm -f "$body"

	if [ "$code" != "200" ] && [ "$code" != "201" ]; then
		bad "Thunderstore refused the upload (HTTP $code)"
		[ -s "$resp" ] && dbg "$(head -c 300 "$resp")"
		rm -f "$resp"
		return 1
	fi

	key="$(json_raw "$resp" key)"
	rm -f "$resp"
	if [ -z "$key" ]; then
		bad "Thunderstore accepted the upload but returned no code"
		return 1
	fi
	printf '%s\n' "$key"
}
