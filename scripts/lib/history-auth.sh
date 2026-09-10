#!/usr/bin/env bash

history__fetch() {
	local location=$1 relative=$2 output=$3 base source
	case $location in
	https://*)
		base=${location%/*}
		if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
			--retry 3 --connect-timeout 30 --max-time 120 --output "$output" "$base/$relative"; then
			die "cannot retrieve signed history metadata: $relative"
		fi
		;;
	*://*) die 'history metadata requires HTTPS or a local manifest path' ;;
	*)
		base=$(realpath -- "$(dirname -- "$location")")
		source=$(realpath --canonicalize-missing -- "$base/$relative")
		case $source in
		"$base"/*) ;;
		*) die 'history metadata escapes its archive directory' ;;
		esac
		if [[ ! -f $source ]] || ! cp -- "$source" "$output"; then
			die "cannot read signed history metadata: $relative"
		fi
		;;
	esac
}

history__require_bootstrap() {
	local location=$1 marker status
	case $location in
	https://*)
		marker="${location%/*}/dists/jammy/InRelease"
		if ! status=$(curl --silent --show-error --location --proto '=https' --proto-redir '=https' \
			--retry 3 --connect-timeout 30 --max-time 120 --output /dev/null \
			--write-out '%{http_code}' "$marker"); then
			die 'cannot determine whether a previous signed archive exists'
		fi
		case $status in
		404) ;;
		200) die 'empty history catalog for an existing signed archive' ;;
		*) die "signed history probe returned HTTP $status; refusing to bootstrap" ;;
		esac
		;;
	*://*) die 'history metadata requires HTTPS or a local manifest path' ;;
	*)
		marker="$(dirname -- "$location")/dists/jammy/InRelease"
		if [[ -e $marker || -L $marker ]]; then
			die 'empty history catalog for an existing signed archive'
		fi
		;;
	esac
}

verify_history_catalog() (
	set -o errexit -o nounset -o pipefail
	local manifest=$1 location=$2 keyring=$3 scratch hash size
	if jq --exit-status '(.packages // [] | length) == 0 and (.releases // [] | length) == 0' \
		"$manifest" >/dev/null; then
		# An unsigned empty (or missing) catalog cannot erase signed history.
		history__require_bootstrap "$location"
		return
	fi
	scratch=$(mktemp --directory)
	trap 'rm --recursive --force -- "$scratch"' EXIT
	history__fetch "$location" dists/jammy/InRelease "$scratch/InRelease"
	if ! gpgv --homedir "$scratch" --keyring "$(realpath -- "$keyring")" \
		--output "$scratch/Release" "$scratch/InRelease" >&2; then
		die 'previous archive signature is not valid under the archive signing key'
	fi
	if ! awk '
        /^[^ ]/ { sha=($0 == "SHA256:") }
        sha && $3 == "main/binary-amd64/Packages" { print $1, $2; count++ }
        END { exit count != 1 }
    ' "$scratch/Release" >"$scratch/expected"; then
		die 'signed history Release must authenticate the package index'
	fi
	read -r hash size <"$scratch/expected"
	history__fetch "$location" dists/jammy/main/binary-amd64/Packages "$scratch/Packages"
	if [[ $(sha256 "$scratch/Packages") != "$hash" || $(stat --format='%s' "$scratch/Packages") != "$size" ]]; then
		die 'previous package index does not match the signed Release'
	fi
	if ! awk '
        BEGIN { RS=""; FS="\n"; OFS="\t" }
        {
            name=version=arch=filename=hash=size=""
            for (i=1; i<=NF; i++) {
                split($i, pair, ": "); value=substr($i, index($i, ": ")+2)
                if (pair[1] == "Package") name=value
                if (pair[1] == "Version") version=value
                if (pair[1] == "Architecture") arch=value
                if (pair[1] == "Filename") filename=value
                if (pair[1] == "SHA256") hash=value
                if (pair[1] == "Size") size=value
            }
            if (filename == "" || hash == "" || name == "" || version == "" || arch == "" || size == "") exit 1
            print filename, hash, size, name, version, arch
        }
    ' "$scratch/Packages" >"$scratch/index.tsv"; then
		die 'signed history index contains incomplete package records'
	fi
	jq --raw-input --slurp '
        split("\n") | map(select(length > 0) | split("\t") |
            {key:.[0], value:{filename:.[0], sha256:.[1], size:(.[2]|tonumber),
                             package:.[3], debian_version:.[4], architecture:.[5]}}) | from_entries
    ' "$scratch/index.tsv" >"$scratch/index.json"
	if ! jq --exit-status --slurpfile index "$scratch/index.json" '
        .releases as $releases
        | ([$releases[].packages[]]) as $packages
        | ([$packages[].filename] | sort) == ($index[0] | keys | sort) and
          (.packages | map({filename,sha256}) | sort_by(.filename)) ==
          ($packages | map({filename,sha256}) | sort_by(.filename)) and
          all($releases[]; . as $release | all(.packages[];
            . as $p | $index[0][$p.filename] as $trusted |
            $trusted != null and
            ($p.sha256 | ascii_downcase) == $trusted.sha256 and
            ($p.size == null or $p.size == $trusted.size) and
            ($p.package == null or $p.package == $trusted.package) and
            ($p.architecture == null or $p.architecture == $trusted.architecture) and
            ($p.debian_version // $release.debian_version) == $trusted.debian_version))
    ' "$manifest" >/dev/null; then
		die 'history catalog does not match its signed package index'
	fi
)
