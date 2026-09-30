# shellcheck shell=bash
# Inspecting and syncing the dedicated server over FTP.
#
# Hosts like Host Havoc give you the server's files over plain FTP, so this
# needs nothing but curl. The server is assumed to lay mods out the way r2modman
# and this tool do — one BepInEx/plugins/<Namespace>-<ModName>/ folder per
# package, with the package's manifest.json inside — which is what lets us read
# a version back off the server without unpacking anything.
#
# The password lives in the macOS Keychain. Everything else (host, user, where
# BepInEx is) goes in a 0600 file next to local.conf, never in the repo.

SERVER_CONF="${VALHEIM_SYNC_SERVER_CONF:-$HOME/.config/valheim-sync/server.conf}"
VS_KEYCHAIN_SERVICE="valheim-sync-ftp"
SERVER_CFG=""

# ----------------------------------------------------------- credentials ----

server_configured() { [ -f "$SERVER_CONF" ]; }

# server_load — read server.conf into SERVER_* or die with what to do next.
server_load() {
	server_configured || die "no server set up yet — run: $PROG server add"
	SERVER_HOST=""; SERVER_PORT=21; SERVER_USER=""; SERVER_TLS=0; SERVER_BEPINEX="BepInEx"
	# shellcheck source=/dev/null
	. "$SERVER_CONF"
	[ -n "$SERVER_HOST" ] && [ -n "$SERVER_USER" ] ||
		die "$(tilde "$SERVER_CONF") is incomplete — run: $PROG server add"
	SERVER_BEPINEX="${SERVER_BEPINEX#/}"; SERVER_BEPINEX="${SERVER_BEPINEX%/}"
}

server_password() {
	if [ -n "${VALHEIM_SYNC_SERVER_PASSWORD:-}" ]; then
		printf '%s' "$VALHEIM_SYNC_SERVER_PASSWORD"
		return 0
	fi
	/usr/bin/security find-generic-password \
		-s "$VS_KEYCHAIN_SERVICE" -a "$SERVER_USER@$SERVER_HOST" -w 2>/dev/null
}

# curl_quote STRING — escape for a double-quoted value in a curl config file.
curl_quote() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	printf '%s' "$s"
}

# urlencode PATH — percent-encode everything but unreserved characters and "/".
urlencode() {
	local s="$1" out="" c i
	local LC_ALL=C
	for ((i = 0; i < ${#s}; i++)); do
		c="${s:i:1}"
		case "$c" in
			[a-zA-Z0-9._~/-]) out+="$c";;
			*) out+="$(printf '%%%02X' "'$c")";;
		esac
	done
	printf '%s' "$out"
}

# ------------------------------------------------------------------- curl ----

# server_connect — load the saved login and open a connection config.
server_connect() { server_load; server_open; }

# server_open — write a private curl config that carries the login, so the
# password never appears in a process listing. Removed when the script exits.
server_open() {
	local pw; pw="$(server_password)" ||
		die "no password stored for $SERVER_USER@$SERVER_HOST — run: $PROG server add"
	SERVER_CFG="$(mktemp -t vsftp)" || die "cannot create a temp file"
	trap 'rm -f "$SERVER_CFG"' EXIT
	{
		printf 'user = "%s:%s"\n' "$(curl_quote "$SERVER_USER")" "$(curl_quote "$pw")"
		printf 'silent\nftp-pasv\nconnect-timeout = 20\nmax-time = 300\n'
		[ "$SERVER_TLS" = 1 ] && printf 'ssl-reqd\n'
	} > "$SERVER_CFG"
}

ftp_url() {
	local path="${1#/}"
	printf 'ftp://%s:%s/%s' "$SERVER_HOST" "$SERVER_PORT" "$(urlencode "$path")"
}

ftp_explain() {
	case "$1" in
		6)  echo "could not resolve $SERVER_HOST";;
		7)  echo "connection refused by $SERVER_HOST:$SERVER_PORT";;
		9)  echo "no such directory on the server";;
		28) echo "timed out talking to $SERVER_HOST";;
		67) echo "the server rejected the login";;
		78) echo "no such file on the server";;
		*)  echo "curl exit $1";;
	esac
}

# ftp_ls PATH — "type<TAB>name" for each entry (type is d or f), from a Unix
# style LIST. Returns curl's exit code when the listing itself fails.
ftp_ls() {
	local path="${1%/}" out rc
	dbg "LIST /$path"
	out="$(curl -K "$SERVER_CFG" "$(ftp_url "$path/")" 2>/dev/null)"; rc=$?
	[ "$rc" -eq 0 ] || return "$rc"
	printf '%s\n' "$out" | tr -d '\r' | awk '
		{
			t = substr($1, 1, 1)
			if (t != "d" && t != "-" && t != "l") next
			name = $9
			for (i = 10; i <= NF; i++) name = name " " $i
			sub(/ -> .*/, "", name)
			if (name == "" || name == "." || name == "..") next
			print (t == "d" ? "d" : "f") "\t" name
		}'
}

# ftp_find DIR — every entry beneath DIR as "type<TAB>path", children before
# their parent, which is the order a recursive delete needs.
ftp_find() {
	local dir="$1" type name
	ftp_ls "$dir" | while IFS=$'\t' read -r type name; do
		if [ "$type" = d ]; then
			ftp_find "$dir/$name"
			printf 'd\t%s\n' "$dir/$name"
		else
			printf 'f\t%s\n' "$dir/$name"
		fi
	done
}

# ftp_rm_tree DIR — delete a directory and everything in it. Quiet when the
# directory is not there.
ftp_rm_tree() {
	local dir="${1%/}" cfg type path n=0
	if [ "$OPT_DRY_RUN" -eq 1 ]; then
		printf '  %s[dry-run]%s delete /%s\n' "$C_DIM" "$C_RESET" "$dir"
		return 0
	fi
	ftp_ls "$dir" >/dev/null 2>&1 || return 0
	cfg="$(mktemp -t vsrm)"
	cat "$SERVER_CFG" > "$cfg"
	while IFS=$'\t' read -r type path; do
		[ -n "$path" ] || continue
		case "$path" in *\"*) warn "not deleting /$path (odd characters in the name)"; continue;; esac
		printf 'quote = "%s %s"\n' "$([ "$type" = d ] && echo RMD || echo DELE)" "$path" >> "$cfg"
		n=$((n + 1))
	done <<EOF
$(ftp_find "$dir")
EOF
	printf 'quote = "RMD %s"\n' "$dir" >> "$cfg"
	curl -K "$cfg" -o /dev/null "$(ftp_url "")" 2>/dev/null
	local rc=$?
	rm -f "$cfg"
	[ "$rc" -eq 0 ] || { bad "could not delete /$dir ($(ftp_explain "$rc"))"; return 1; }
	return 0
}

# ftp_put_tree LOCAL_DIR REMOTE_DIR — upload every file under LOCAL_DIR,
# creating remote directories as needed, over one connection.
ftp_put_tree() {
	local src="${1%/}" dest="${2%/}" cfg f rel n=0
	cfg="$(mktemp -t vsput)"
	cat "$SERVER_CFG" > "$cfg"
	printf 'ftp-create-dirs\n' >> "$cfg"
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		rel="${f#"$src"/}"
		case "$(basename "$f")" in .DS_Store) continue;; esac
		printf 'upload-file = "%s"\nurl = "%s"\n' \
			"$(curl_quote "$f")" "$(curl_quote "$(ftp_url "$dest/$rel")")" >> "$cfg"
		n=$((n + 1))
	done <<EOF
$(find "$src" -type f | LC_ALL=C sort)
EOF
	if [ "$OPT_DRY_RUN" -eq 1 ]; then
		printf '  %s[dry-run]%s upload %s file(s) to /%s\n' "$C_DIM" "$C_RESET" "$n" "$dest"
		rm -f "$cfg"; return 0
	fi
	[ "$n" -gt 0 ] || { rm -f "$cfg"; return 0; }
	curl -K "$cfg" 2>/dev/null
	local rc=$?
	rm -f "$cfg"
	[ "$rc" -eq 0 ] || { bad "upload to /$dest failed ($(ftp_explain "$rc"))"; return 1; }
	return 0
}

# ------------------------------------------------------------------- setup ----

# server_discover — find the BepInEx folder: the FTP root, or one level down
# (hosts often nest the game under a folder). Echoes a path relative to the
# login directory; nothing when it cannot be found.
server_discover() {
	local type name
	if ftp_ls "" | grep -qx $'d\tBepInEx'; then echo "BepInEx"; return 0; fi
	while IFS=$'\t' read -r type name; do
		[ "$type" = d ] || continue
		if ftp_ls "$name" 2>/dev/null | grep -qx $'d\tBepInEx'; then
			echo "$name/BepInEx"; return 0
		fi
	done <<EOF
$(ftp_ls "")
EOF
	return 1
}

server_add() {
	[ -t 0 ] || die "server add asks questions — run it in a terminal"
	local host port user tls reply
	SERVER_HOST=""; SERVER_PORT=21; SERVER_USER=""; SERVER_TLS=0; SERVER_BEPINEX="BepInEx"
	server_configured && . "$SERVER_CONF"

	info "Server FTP login"
	say "  Host Havoc shows these under your server's FTP details."
	printf '  Host [%s]: ' "$SERVER_HOST"; read -r host;  host="${host:-$SERVER_HOST}"
	printf '  Port [%s]: ' "$SERVER_PORT"; read -r port;  port="${port:-$SERVER_PORT}"
	printf '  Username [%s]: ' "$SERVER_USER"; read -r user; user="${user:-$SERVER_USER}"
	[ -n "$host" ] && [ -n "$user" ] || die "host and username are required"
	case "$port" in ''|*[!0-9]*) die "port must be a number";; esac
	printf '  Require FTPS (TLS)? [y/N]: '; read -r reply
	case "$reply" in [yY]*) tls=1;; *) tls=$SERVER_TLS;; esac
	[ -n "$reply" ] || tls=$SERVER_TLS

	if [ -z "${VALHEIM_SYNC_SERVER_PASSWORD:-}" ]; then
		say "  The password goes into your Keychain (service '$VS_KEYCHAIN_SERVICE');"
		say "  macOS will ask for it twice."
		/usr/bin/security add-generic-password -U -s "$VS_KEYCHAIN_SERVICE" \
			-a "$user@$host" -w || die "could not store the password"
	fi

	SERVER_HOST="$host"; SERVER_PORT="$port"; SERVER_USER="$user"; SERVER_TLS="$tls"
	server_open

	info "Testing the login"
	local rc=0
	ftp_ls "" >/dev/null || rc=$?
	[ "$rc" -eq 0 ] || die "could not log in: $(ftp_explain "$rc")"
	ok "connected to $SERVER_HOST as $SERVER_USER"

	local found; found="$(server_discover || true)"
	if [ -n "$found" ]; then
		ok "found BepInEx at /$found"
	else
		warn "no BepInEx folder found at the top of the FTP tree"
		found="$SERVER_BEPINEX"
	fi
	printf '  BepInEx folder on the server [%s]: ' "$found"; read -r reply
	SERVER_BEPINEX="${reply:-$found}"

	mkdir -p "$(dirname "$SERVER_CONF")"
	umask 077
	{
		printf '# Written by %s server add — safe to edit. The password is in the Keychain.\n' "$PROG"
		printf 'SERVER_HOST=%q\nSERVER_PORT=%q\nSERVER_USER=%q\nSERVER_TLS=%q\nSERVER_BEPINEX=%q\n' \
			"$SERVER_HOST" "$SERVER_PORT" "$SERVER_USER" "$SERVER_TLS" "$SERVER_BEPINEX"
	} > "$SERVER_CONF"
	chmod 600 "$SERVER_CONF"
	ok "saved $(tilde "$SERVER_CONF")"
	say "  Next: $PROG server status"
}

server_forget() {
	server_configured || { say "  Nothing to forget."; return 0; }
	server_load
	/usr/bin/security delete-generic-password -s "$VS_KEYCHAIN_SERVICE" \
		-a "$SERVER_USER@$SERVER_HOST" >/dev/null 2>&1 || true
	rm -f "$SERVER_CONF"
	ok "removed the server login for $SERVER_USER@$SERVER_HOST"
}

# ------------------------------------------------------------------- tree ----

# server_tree PATH DEPTH — print the remote directory tree, DEPTH levels deep.
server_tree() {
	local dir="${1%/}" depth="$2" indent="${3:-}" type name
	ftp_ls "$dir" | while IFS=$'\t' read -r type name; do
		if [ "$type" = d ]; then
			printf '%s%s%s/%s\n' "$indent" "$C_BOLD" "$name" "$C_RESET"
			[ "$depth" -gt 1 ] && server_tree "$dir/$name" $((depth - 1)) "$indent  "
		else
			printf '%s%s\n' "$indent" "$name"
		fi
	done
}

# ------------------------------------------------------------- inventory ----

# server_inventory MANAGED LOOSE — read what the server has installed.
#   MANAGED  "full_name<TAB>version" ("?" when the version cannot be told)
#   LOOSE    entries in plugins/ that are not Namespace-ModName folders
server_inventory() {
	local managed="$1" loose="$2" plugins="$SERVER_BEPINEX/plugins"
	local listing rc=0 type name work cfg i=0
	: > "$managed"; : > "$loose"

	listing="$(ftp_ls "$plugins")" || rc=$?
	[ "$rc" -eq 0 ] || { bad "could not list /$plugins ($(ftp_explain "$rc"))"; return 1; }

	work="$(mktemp -d -t vsinv)"
	cfg="$work/cfg"
	cat "$SERVER_CFG" > "$cfg"
	: > "$work/index"

	# One connection fetches every manifest.json; the ones that do not exist
	# just fail quietly and leave no file.
	while IFS=$'\t' read -r type name; do
		[ -n "$name" ] || continue
		# Only Namespace-ModName folders are packages; anything else (loose
		# files, a folder someone made by hand) is reported but never touched.
		case "$type:$name" in
			d:*\ *|d:-*|d:*-) type=f;;
			d:*-*) ;;
			*) type=f;;
		esac
		if [ "$type" != d ]; then
			printf '%s\n' "$name" >> "$loose"
			continue
		fi
		i=$((i + 1))
		printf 'url = "%s"\noutput = "%s"\n' \
			"$(curl_quote "$(ftp_url "$plugins/$name/manifest.json")")" "$work/m$i" >> "$cfg"
		printf '%s\t%s\n' "$i" "$name" >> "$work/index"
	done <<EOF
$listing
EOF
	[ "$i" -eq 0 ] || curl -K "$cfg" 2>/dev/null || true

	local idx dir version base
	while IFS=$'\t' read -r idx dir; do
		[ -n "$dir" ] || continue
		version=""
		if [ -s "$work/m$idx" ]; then
			# Thunderstore manifests are usually saved with a UTF-8 byte-order mark.
			LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$work/m$idx" > "$work/m$idx.json"
			version="$(json_raw "$work/m$idx.json" version_number)"
		fi
		base="$dir"
		# "Ns-Name-1.2.3" folders: the version is in the name, and is not part of it.
		case "${dir##*-}" in
			[0-9]*.[0-9]*.[0-9]*)
				[ -n "$version" ] || version="${dir##*-}"
				base="${dir%-*}";;
		esac
		printf '%s\t%s\n' "$base" "${version:-?}" >> "$managed"
	done < "$work/index"
	rm -rf "$work"
	sort -o "$managed" "$managed"
	return 0
}

# server_compare — "full<TAB>local<TAB>server<TAB>state" for every mod either
# side has, where state is ok, mismatch, unknown, local-only or server-only.
# The macOS-only loader packages are left out; the server has its own.
server_compare() {
	local managed="$1" want; want="$(mktemp -t vscmpw)"
	local full version
	desired_mods | while IFS=$'\t' read -r full version _; do
		[ -n "$full" ] || continue
		is_skipped "$full" && continue
		printf '%s\t%s\n' "$full" "$version"
	done > "$want"

	local srv; srv="$(mktemp -t vscmps)"
	while IFS=$'\t' read -r full version; do
		is_skipped "$full" && continue
		printf '%s\t%s\n' "$full" "$version"
	done < "$managed" > "$srv"

	awk -F'\t' -v OFS='\t' '
		FILENAME == ARGV[1] { loc[$1] = $2; order[++n] = $1; next }
		{ srv[$1] = $2; if (!($1 in loc)) extra[++m] = $1 }
		END {
			for (i = 1; i <= n; i++) {
				k = order[i]
				if (!(k in srv))            s = "local-only"
				else if (srv[k] == "?")     s = "unknown"
				else if (srv[k] == loc[k])  s = "ok"
				else                        s = "mismatch"
				print k, loc[k], ((k in srv) ? srv[k] : "-"), s
			}
			for (i = 1; i <= m; i++) print extra[i], "-", srv[extra[i]], "server-only"
		}' "$want" "$srv"
	rm -f "$want" "$srv"
}

server_state_label() {
	case "$1" in
		ok)          printf '%sok%s' "$C_GREEN" "$C_RESET";;
		mismatch)    printf '%sversion differs%s' "$C_RED" "$C_RESET";;
		unknown)     printf '%sserver version unknown%s' "$C_YELLOW" "$C_RESET";;
		local-only)  printf '%snot on server%s' "$C_RED" "$C_RESET";;
		server-only) printf '%sonly on server%s' "$C_YELLOW" "$C_RESET";;
	esac
}

# server_report COMPARISON LOOSE — print the table; returns 1 when anything
# is out of step.
server_report() {
	local cmp="$1" loose="$2" full lv sv state bad_n=0 n=0
	printf '\n%sServer%s  %s@%s  %s(/%s/plugins)%s\n\n' "$C_BOLD" "$C_RESET" \
		"$SERVER_USER" "$SERVER_HOST" "$C_DIM" "$SERVER_BEPINEX" "$C_RESET"
	printf '  %-38s %-10s %-10s %s\n' "MOD" "LOCAL" "SERVER" "STATE"
	while IFS=$'\t' read -r full lv sv state; do
		[ -n "$full" ] || continue
		n=$((n + 1))
		[ "$state" = ok ] || bad_n=$((bad_n + 1))
		printf '  %-38s %-10s %-10s %b\n' "$full" "$lv" "$sv" "$(server_state_label "$state")"
	done < "$cmp"

	if [ -s "$loose" ]; then
		printf '\n  %sin plugins/ but not a package:%s %s\n' \
			"$C_DIM" "$C_RESET" "$(tr '\n' ' ' < "$loose")"
	fi
	printf '\n'
	if [ "$bad_n" -eq 0 ]; then
		ok "all $n mod(s) match the server"
		return 0
	fi
	warn "$bad_n of $n differ — run: $PROG server sync"
	return 1
}

cmd_server_status() {
	have_profile || fetch_profile || die "could not fetch the profile"
	server_connect
	local managed loose cmp
	managed="$(mktemp -t vsmg)"; loose="$(mktemp -t vslo)"; cmp="$(mktemp -t vscm)"
	info "Reading the server over FTP"
	if ! server_inventory "$managed" "$loose"; then
		rm -f "$managed" "$loose" "$cmp"; return 2
	fi
	server_compare "$managed" > "$cmp"
	local rc=0
	server_report "$cmp" "$loose" || rc=$?
	rm -f "$managed" "$loose" "$cmp"
	return $rc
}

# ------------------------------------------------------------------ syncing ----

# stage_package FULL VERSION ZIP DIR — lay a package out exactly as install
# would, but under DIR, so it can be uploaded. Reuses install_package so the
# server ends up with the same tree a local install has.
stage_package() {
	(
		BEPINEX_DIR="$4/BepInEx"
		PLUGINS_DIR="$4/BepInEx/plugins"
		CONFIG_DIR="$4/BepInEx/config"
		OPT_DRY_RUN=0
		record_installed() { :; }
		strip_quarantine() { :; }
		install_package "$1" "$2" "$3"
	) >/dev/null
}

# upload_mod FULL VERSION — replace the server's copy with this version.
upload_mod() {
	local full="$1" version="$2" zip stage sub
	zip="$(package_zip "$full" "$version")" || return 1
	stage="$(mktemp -d -t vsstage)"
	if ! stage_package "$full" "$version" "$zip" "$stage"; then
		rm -rf "$stage"; bad "could not unpack $full $version"; return 1
	fi
	for sub in plugins patchers monomod; do
		[ -d "$stage/BepInEx/$sub/$full" ] || continue
		ftp_rm_tree "$SERVER_BEPINEX/$sub/$full" || { rm -rf "$stage"; return 1; }
		ftp_put_tree "$stage/BepInEx/$sub/$full" "$SERVER_BEPINEX/$sub/$full" ||
			{ rm -rf "$stage"; return 1; }
	done
	rm -rf "$stage"
	return 0
}

# delete_from_server FULL
delete_from_server() {
	local sub
	for sub in plugins patchers monomod; do
		ftp_rm_tree "$SERVER_BEPINEX/$sub/$1" || return 1
	done
}

# adopt_from_server FULL VERSION — make the server's version the local one.
# Checked against Thunderstore first: a version it cannot download would
# poison every later sync.
adopt_from_server() {
	local full="$1" version="$2"
	ts_package_json "${full%%-*}" "${full#*-}" "$version" >/dev/null || {
		bad "$full $version is not on Thunderstore, so it cannot be installed here"
		return 1
	}
	overlay_set "$full" "$version"
}

# ask_direction FULL LOCAL SERVER STATE — echo l, s or k.
ask_direction() {
	local full="$1" lv="$2" sv="$3" state="$4" reply
	case "$OPT_SERVER_DIR" in to) echo l; return;; from) echo s; return;; esac
	case "$state" in
		mismatch) say "  $full   local ${C_BOLD}$lv${C_RESET}   server ${C_BOLD}$sv${C_RESET}" >&2
		          say "    [l] upload local to the server   [s] install the server's version here   [k] skip" >&2;;
		unknown)  say "  $full   local ${C_BOLD}$lv${C_RESET}   server has it, version unknown" >&2
		          say "    [l] upload local to the server (makes it verifiable)   [k] skip" >&2;;
		local-only)  say "  $full $lv is only on this Mac" >&2
		          say "    [l] upload it to the server   [s] drop it locally   [k] skip" >&2;;
		server-only) say "  $full $sv is only on the server" >&2
		          say "    [s] install it here   [l] delete it from the server   [k] skip" >&2;;
	esac
	say "    (capital L or S applies that direction to everything left)" >&2
	while :; do
		printf '    > ' >&2
		read -r reply || { echo k; return; }
		case "$reply" in
			l|L|s|S|k|K|'') break;;
		esac
	done
	case "$reply" in
		L) OPT_SERVER_DIR=to;   echo l;;
		S) OPT_SERVER_DIR=from; echo s;;
		'') echo k;;
		*) echo "$reply" | tr 'A-Z' 'a-z';;
	esac
}

cmd_server_sync() {
	if [ "$OPT_YES" -eq 1 ] && [ -z "$OPT_SERVER_DIR" ]; then
		die "with --yes, say which way: --to-server or --from-server"
	fi
	[ -n "$OPT_SERVER_DIR" ] || [ -t 0 ] ||
		die "server sync asks which way to go — run it in a terminal, or pass --to-server / --from-server"

	have_profile || fetch_profile || die "could not fetch the profile"
	server_connect
	local managed loose cmp
	managed="$(mktemp -t vsmg)"; loose="$(mktemp -t vslo)"; cmp="$(mktemp -t vscm)"
	info "Reading the server over FTP"
	if ! server_inventory "$managed" "$loose"; then
		rm -f "$managed" "$loose" "$cmp"; return 2
	fi
	server_compare "$managed" > "$cmp"
	server_report "$cmp" "$loose" && { rm -f "$managed" "$loose" "$cmp"; return 0; }

	local full lv sv state choice up=0 down=0 skipped=0 failed=0 local_change=0
	while IFS=$'\t' read -r full lv sv state <&3; do
		[ -n "$full" ] && [ "$state" != ok ] || continue
		choice="$(ask_direction "$full" "$lv" "$sv" "$state")"
		case "$choice:$state" in
			k:*)
				skipped=$((skipped + 1));;
			l:mismatch|l:unknown|l:local-only)
				info "upload  $full  $lv"
				if upload_mod "$full" "$lv"; then up=$((up + 1)); else failed=$((failed + 1)); fi;;
			l:server-only)
				if confirm "Delete $full from the server?"; then
					info "delete  $full  (server)"
					if delete_from_server "$full"; then up=$((up + 1)); else failed=$((failed + 1)); fi
				else
					skipped=$((skipped + 1))
				fi;;
			s:mismatch|s:server-only)
				info "adopt   $full  $sv"
				if adopt_from_server "$full" "$sv"; then
					down=$((down + 1)); local_change=1
				else
					failed=$((failed + 1))
				fi;;
			s:local-only)
				info "drop    $full  (local)"
				drop_local "$full"; down=$((down + 1));;
			s:unknown)
				warn "$full: the server's version is unknown, so there is nothing to install — skipped"
				skipped=$((skipped + 1));;
			*)
				skipped=$((skipped + 1));;
		esac
	done 3< "$cmp"
	rm -f "$managed" "$loose" "$cmp"

	if [ "$local_change" -eq 1 ] && [ "$OPT_DRY_RUN" -eq 0 ]; then
		info "Installing the server's versions here"
		ensure_loader || die "could not prepare the BepInEx loader"
		if sync_packages; then ok "$SYNC_SUMMARY"; else bad "some mods failed to install — $SYNC_SUMMARY"; failed=$((failed + 1)); fi
	fi

	printf '\n'
	ok "$up on the server changed, $down here changed, $skipped skipped"
	[ "$up" -eq 0 ] || say "  Restart the game server (Host Havoc panel) for the uploaded mods to load."
	[ "$down" -eq 0 ] || say "  Your local list changed; to share it with the group: $PROG publish"
	[ "$failed" -eq 0 ] || { bad "$failed failed"; return 1; }
	return 0
}

cmd_server() {
	local sub="${1:-status}"
	[ "$#" -eq 0 ] || shift
	case "$sub" in
		add|login|setup) server_add;;
		status|check)    cmd_server_status;;
		sync)            cmd_server_sync;;
		tree|ls)
			server_connect
			local path="${1:-}" depth="${2:-2}"
			case "$depth" in ''|*[!0-9]*) die "depth must be a number";; esac
			printf '%s/%s%s\n' "$C_DIM" "$path" "$C_RESET"
			server_tree "$path" "$depth" "  ";;
		forget|logout)   server_forget;;
		*) die "unknown server command: $sub (add, status, sync, tree, forget)";;
	esac
}
