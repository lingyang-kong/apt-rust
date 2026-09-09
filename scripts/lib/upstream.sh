#!/usr/bin/env bash

RUST_RELEASE_FINGERPRINT='108F66205EAEB0AAA8DD5E1C85AB96E6FA1BE5FE'
RUST_DIST='https://static.rust-lang.org/dist'
TARGET='x86_64-unknown-linux-gnu'
MULTIARCH='x86_64-linux-gnu'
export TARGET MULTIARCH

download_upstream() {
	local url=$1 output=$2
	case $url in
	https://static.rust-lang.org/*) ;;
	*) die "unexpected upstream URL: $url" ;;
	esac
	mkdir --parents -- "${output%/*}"
	if ! curl --fail --silent --show-error --location --proto '=https' \
		--proto-redir '=https' --retry 3 --connect-timeout 30 --max-time 1800 \
		--output "$output.partial" "$url"; then
		rm --force -- "$output.partial"
		die "download failed: $url"
	fi
	mv -- "$output.partial" "$output"
}

verify_signature() (
	set -o errexit -o nounset -o pipefail
	local_file=$1 signature=$2 key=$3
	verify_home=$(mktemp --directory)
	trap 'rm --recursive --force -- "$verify_home"' EXIT
	fingerprint=$(gpg --batch --homedir "$verify_home" --with-colons --show-keys "$key" |
		awk -F: '$1 == "fpr" && !seen++ { print $10 }')
	if [[ $fingerprint != "$RUST_RELEASE_FINGERPRINT" ]]; then
		die 'Rust release key does not match the pinned fingerprint'
	fi
	gpg --batch --homedir "$verify_home" --dearmor --output "$verify_home/rust.gpg" "$key"
	if ! gpgv --homedir "$verify_home" --keyring "$verify_home/rust.gpg" --status-fd 1 \
		"$signature" "$local_file" >"$verify_home/status"; then
		die "invalid upstream signature: $local_file"
	fi
	if ! awk -v fingerprint="$fingerprint" \
		'$2 == "VALIDSIG" && ($3 == fingerprint || $NF == fingerprint) { valid=1 }
         END { exit !valid }' "$verify_home/status"; then
		die 'signature does not match the pinned Rust release key'
	fi
)

parse_manifest() {
	local input=$1 url=$2 output=$3 rows
	rows=$(mktemp)
	# Parse only the scalar subset of the signed Rust v2 schema we consume.
	# Unknown tables are ignored; duplicate or non-scalar selected values fail.
	if ! awk -v target="$TARGET" '
        function fail(message) { print message > "/dev/stderr"; bad=1; exit 1 }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /^\[/ { section=$0; sub(/\r$/, "", section); next }
        {
            line=$0; sub(/\r$/, "", line)
            if (line !~ /^[A-Za-z0-9_-]+[[:space:]]*=/) next
            key=line; sub(/[[:space:]]*=.*/, "", key)
            name=""
            if (section == "" && (key == "date" || key == "manifest-version")) name=key
            if (section == "[pkg.rust]" && key == "version") name="version"
            split("rustc cargo rust-std rustfmt-preview clippy-preview rust-docs", components, " ")
            for (i=1; i<=6; i++) {
                if (section == "[pkg." components[i] ".target." target "]" &&
                    (key == "available" || key == "xz_url" || key == "xz_hash"))
                    name=components[i] "." key
            }
            if (name == "") next
            if (seen[name]++) fail("duplicate Rust manifest key: " name)
            value=line; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value)
            if (key == "available") {
                if (value != "true") fail("unavailable upstream component: " name)
            } else {
                if (value !~ /^"[^"\\]*"$/) fail("unsupported Rust manifest scalar: " name)
                value=substr(value, 2, length(value)-2)
            }
            if (name == "version") sub(/ .*/, "", value)
            print name "\t" value
        }
        END { if (bad) exit 1 }
    ' "$input" >"$rows"; then
		rm --force -- "$rows"
		die 'cannot parse Rust release manifest'
	fi
	if ! jq --raw-input --slurp --exit-status --arg url "$url" --arg hash "$(sha256 "$input")" '
        split("\n") | map(select(length > 0) | split("\t") | {(.[0]): .[1]}) | add
        | . as $m
        | if .["manifest-version"] != "2" or
             (.date | type != "string" or length == 0) or
             (.version | type != "string" or
              (test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$") | not))
          then error("unsupported manifest version, date, or release version") else . end
        | {version, date, manifest_url: $url, manifest_sha256: $hash,
           assets: ["rustc", "cargo", "rust-std", "rustfmt-preview", "clippy-preview", "rust-docs"]
             | map(. as $c | {component: $c, url: $m[$c+".xz_url"], sha256: $m[$c+".xz_hash"]}
                 | if $m[$c+".available"] != "true" or
                      (.sha256 | test("^[0-9a-f]{64}$") | not) or
                      (.url | startswith("https://static.rust-lang.org/") | not)
                   then error("missing or invalid upstream component") else . end)}
    ' "$rows" >"$output"; then
		rm --force -- "$rows"
		die 'invalid Rust release manifest'
	fi
	rm --force -- "$rows"
	if ! date --utc --date="$(jq --raw-output '.date' "$output")" '+%s' >/dev/null; then
		die 'invalid Rust release manifest date'
	fi
}

discover_release() {
	local work=$1 key=$2 channel=${3:-stable}
	local discovery_url canonical_url discovery_manifest discovery_signature
	local canonical_manifest canonical_signature discovered_version canonical_version
	if [[ $channel != stable && ! $channel =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
		die 'RUST_CHANNEL must be stable or an X.Y.Z release'
	fi
	discovery_url="$RUST_DIST/channel-rust-$channel.toml"
	discovery_manifest="$work/channel-selection.toml"
	discovery_signature="$work/channel-selection.toml.asc"
	download_upstream "$discovery_url" "$discovery_manifest"
	download_upstream "$discovery_url.asc" "$discovery_signature"
	if ! verify_signature "$discovery_manifest" "$discovery_signature" "$key"; then
		die 'invalid Rust release discovery signature'
	fi
	if ! parse_manifest "$discovery_manifest" "$discovery_url" "$work/discovery.json"; then
		die 'invalid Rust release discovery manifest'
	fi
	if ! discovered_version=$(jq --raw-output --exit-status '.version' "$work/discovery.json"); then
		die 'Rust release discovery manifest has no version'
	fi
	if [[ $channel != stable && $discovered_version != "$channel" ]]; then
		die "requested Rust release $channel does not match manifest version $discovered_version"
	fi

	canonical_url="$RUST_DIST/channel-rust-$discovered_version.toml"
	canonical_manifest="$work/channel.toml"
	canonical_signature="$work/channel.toml.asc"
	if [[ $discovery_url == "$canonical_url" ]]; then
		# An explicit X.Y.Z request is already the immutable canonical manifest.
		cp -- "$discovery_manifest" "$canonical_manifest"
		cp -- "$discovery_signature" "$canonical_signature"
	else
		download_upstream "$canonical_url" "$canonical_manifest"
		download_upstream "$canonical_url.asc" "$canonical_signature"
	fi
	if ! verify_signature "$canonical_manifest" "$canonical_signature" "$key"; then
		die 'invalid canonical Rust release signature'
	fi
	if ! parse_manifest "$canonical_manifest" "$canonical_url" "$work/release.json"; then
		die 'invalid canonical Rust release manifest'
	fi
	if ! canonical_version=$(jq --raw-output --exit-status '.version' "$work/release.json"); then
		die 'canonical Rust release manifest has no version'
	fi
	if [[ $canonical_version != "$discovered_version" ]]; then
		die "canonical Rust release $canonical_version differs from discovered release $discovered_version"
	fi
}

fetch_asset() {
	local url=$1 digest=$2 path=$3
	if [[ ! $digest =~ ^[0-9a-f]{64}$ ]]; then
		die 'invalid component checksum'
	fi
	if [[ ! -f $path ]] || [[ $(sha256 "$path") != "$digest" ]]; then
		download_upstream "$url" "$path"
	fi
	if [[ $(sha256 "$path") != "$digest" ]]; then
		rm --force -- "$path"
		die "checksum mismatch: $url"
	fi
}

fetch_source() {
	local version=$1 cache=$2 key=$3 output=$4 source url
	source="$cache/rustc-$version-src.tar.xz"
	url="$RUST_DIST/rustc-$version-src.tar.xz"
	if [[ ! -f $source ]]; then
		download_upstream "$url" "$source"
	fi
	download_upstream "$url.asc" "$source.asc"
	verify_signature "$source" "$source.asc" "$key"
	jq --null-input --arg url "$url" --arg hash "$(sha256 "$source")" \
		'{component: "rustc-src", url: $url, sha256: $hash}' >"$output"
}
