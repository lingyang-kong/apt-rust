#!/usr/bin/env bash

# Live archive retention.  This library deliberately treats a release as one
# unit: all twelve packages are validated and copied before the release is
# considered for the deployment size limit.

retention__valid_path() {
	local path=$1 part
	if [[ -z $path || $path == /* || $path == *\\* || $path == *$'\n'* ||
		$path == *$'\r'* || $path == *$'\t'* ]]; then
		return 1
	fi
	IFS='/' read -r -a parts <<<"$path"
	if [[ ${#parts[@]} -eq 0 ]]; then
		return 1
	fi
	for part in "${parts[@]}"; do
		if [[ -z $part || $part == '.' || $part == '..' ]]; then
			return 1
		fi
	done
}

retention__manifest_base() {
	local location=$1
	case $location in
	https://*)
		[[ $location == */* ]] || return 1
		printf '%s/\n' "${location%/*}"
		;;
	*)
		dirname -- "$location"
		;;
	esac
}

retention__validate_release_shape() {
	local release=$1 version debian_version revision
	if ! jq --exit-status '
        type == "object" and
        (.version | type == "string" and length > 0) and
        (.debian_version | type == "string" and length > 0) and
        (.packages | type == "array" and length == 12) and
        (([.packages[].filename] | unique | length) ==
            ([.packages[].filename] | length)) and
        all(.packages[];
            type == "object" and
            (.filename | type == "string") and
            (.sha256 | type == "string" and test("^[0-9a-fA-F]{64}$")) and
            ((.size == null) or (.size | type == "number" and . >= 0 and floor == .)) and
            ((.package == null) or (.package | type == "string" and length > 0)) and
            ((.debian_version == null) or (.debian_version | type == "string" and length > 0)) and
            ((.architecture == null) or (.architecture | type == "string" and length > 0)))
    ' <<<"$release" >/dev/null; then
		return 1
	fi
	version=$(jq --raw-output '.version' <<<"$release")
	debian_version=$(jq --raw-output '.debian_version' <<<"$release")
	if [[ ! $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ||
		$debian_version != "$version-"* ]]; then
		return 1
	fi
	revision=${debian_version#"$version-"}
	if [[ ! $revision =~ ^[1-9][0-9]*$ ]]; then
		return 1
	fi
}

retention__read_previous_releases() {
	local manifest=$1 output=$2
	if ! jq --compact-output '
        if type != "object" then error("published manifest is not an object")
        elif (.releases | type) == "array" then .releases[]
        elif (.packages | type) == "array" then
            . as $manifest |
            ($manifest | del(.packages,.releases,.signing_fingerprint,.generated_at,
                .deployment_bytes,.max_bytes))
            + {
                version: ($manifest.version // $manifest.release.version //
                    $manifest.identity.release.version // ""),
                debian_version: ($manifest.debian_version //
                    $manifest.identity.debian_version // ""),
                packages: $manifest.packages
            }
        elif length == 0 then empty
        else error("published manifest has no release catalog")
        end
    ' "$manifest" >"$output"; then
		die "invalid published manifest: $manifest"
	fi
}

retention__same_identity() {
	local first=$1 second=$2
	jq --exit-status -n --argjson first "$first" --argjson second "$second" '
        ([$first.packages[] | {key:.filename,value:(.sha256 | ascii_downcase)}] | from_entries) ==
        ([$second.packages[] | {key:.filename,value:(.sha256 | ascii_downcase)}] | from_entries)
    ' >/dev/null
}

retention__sort_releases() {
	local input=$1 output=$2 line version previous_version index path
	local -a sorted=()
	while IFS= read -r line; do
		[[ -n $line ]] || continue
		if ! retention__validate_release_shape "$line"; then
			die 'invalid retained release metadata'
		fi
		while IFS= read -r path; do
			if ! retention__valid_path "$path"; then
				die "unsafe retained package path: $path"
			fi
		done < <(jq --raw-output '.packages[].filename' <<<"$line")
		version=$(jq --raw-output '.debian_version' <<<"$line")
		index=${#sorted[@]}
		while ((index > 0)); do
			previous_version=$(jq --raw-output '.debian_version' <<<"${sorted[index - 1]}")
			if dpkg --compare-versions "$version" gt "$previous_version"; then
				index=$((index - 1))
				continue
			fi
			if dpkg --compare-versions "$version" eq "$previous_version"; then
				if ! retention__same_identity "$line" "${sorted[index - 1]}"; then
					die "published package bytes changed at $version"
				fi
				line=''
			fi
			break
		done
		if [[ -n $line ]]; then
			local -a before=("${sorted[@]:0:index}") after=("${sorted[@]:index}")
			sorted=("${before[@]}" "$line" "${after[@]}")
		fi
	done <"$input"
	: >"$output"
	printf '%s\n' "${sorted[@]}" | sed '/^$/d' >"$output"
}

retention__record_from_file() {
	local expected=$1 file=$2 output=$3
	local fields package version architecture size digest expected_value
	if ! digest=$(sha256 "$file"); then
		return 1
	fi
	expected_value=$(jq --raw-output '.sha256' <<<"$expected")
	if [[ ${digest,,} != "${expected_value,,}" ]]; then
		return 1
	fi
	size=$(stat --format='%s' "$file")
	if jq --exit-status '.size != null' <<<"$expected" >/dev/null; then
		expected_value=$(jq --raw-output '.size | tostring' <<<"$expected")
		if [[ $size != "$expected_value" ]]; then
			return 1
		fi
	fi
	if ! fields=$(dpkg-deb --field "$file" Package Version Architecture 2>/dev/null); then
		return 1
	fi
	package=$(printf '%s\n' "$fields" | sed --quiet 's/^Package: //p')
	version=$(printf '%s\n' "$fields" | sed --quiet 's/^Version: //p')
	architecture=$(printf '%s\n' "$fields" | sed --quiet 's/^Architecture: //p')
	if [[ -z $package || -z $version || -z $architecture ]]; then
		return 1
	fi
	for field in package debian_version architecture; do
		expected_value=$(jq --raw-output --arg field "$field" '.[$field] // empty' <<<"$expected")
		case $field in
		package) actual=$package ;;
		debian_version) actual=$version ;;
		architecture) actual=$architecture ;;
		esac
		if [[ -n $expected_value && $expected_value != "$actual" ]]; then
			return 1
		fi
	done
	jq --arg package "$package" --arg debian_version "$version" \
		--arg architecture "$architecture" --argjson size "$size" \
		--arg sha256 "${digest,,}" \
		'. + {package:$package,debian_version:$debian_version,architecture:$architecture,
              sha256:$sha256,size:$size}' \
		<<<"$expected" >"$output"
}

retention__source_local() {
	local root=$1 relative=$2 output=$3 resolved
	root=$(realpath -- "$root") || return 1
	resolved=$(realpath --canonicalize-missing -- "$root/$relative") || return 1
	case $resolved in
	"$root"/*) ;;
	*) return 1 ;;
	esac
	if [[ ! -f $resolved || -L $resolved ]]; then
		return 1
	fi
	printf '%s\n' "$resolved" >"$output"
}

retention__source_cache() {
	local cache=$1 digest=$2 version=$3 filename=$4 output=$5 candidate
	for candidate in "$cache/history/$digest.deb" "$cache/history/$digest" \
		"$cache/packages/$version/${filename##*/}"; do
		if [[ -f $candidate && ! -L $candidate ]]; then
			printf '%s\n' "$candidate" >"$output"
			return 0
		fi
	done
	return 1
}

retention__source_https() {
	local url=$1 cache=$2 digest=$3 output=$4 temporary output_path
	if ! mkdir --parents -- "$cache/history"; then
		return 1
	fi
	if ! temporary=$(mktemp "$cache/history/.download.XXXXXX"); then
		return 1
	fi
	if ! curl --silent --show-error --location --proto '=https' --proto-redir '=https' \
		--retry 3 --connect-timeout 30 --max-time 1800 --output "$temporary" "$url"; then
		rm --force -- "$temporary"
		return 1
	fi
	if [[ $(sha256 "$temporary") != "$digest" ]]; then
		rm --force -- "$temporary"
		return 1
	fi
	output_path="$cache/history/$digest.deb"
	if ! mv -- "$temporary" "$output_path"; then
		rm --force -- "$temporary"
		return 1
	fi
	printf '%s\n' "$output_path" >"$output"
}

retention__retrieve_release() {
	local release=$1 destination=$2 previous_location=$3 cache=$4 base=$5
	local filename digest url url_lower source_file record_file target record history_file
	local local_root=''
	local https_base=''
	if [[ $previous_location != https://* ]]; then
		local_root=$(retention__manifest_base "$previous_location") ||
			die 'invalid local previous manifest location'
		local_root=$(realpath -- "$local_root") || die 'previous manifest parent does not exist'
	else
		https_base=$base
	fi
	mkdir --parents -- "$destination"
	while IFS= read -r record; do
		filename=$(jq --raw-output '.filename' <<<"$record")
		digest=$(jq --raw-output '.sha256' <<<"$record" | tr '[:upper:]' '[:lower:]')
		if ! retention__valid_path "$filename" || [[ $filename != pool/* || $filename != *.deb ]]; then
			die "unsafe retained package path: $filename"
		fi
		source_file="$destination/source"
		if [[ -n $local_root ]] && retention__source_local "$local_root" "$filename" "$source_file" &&
			[[ $(sha256 "$(<"$source_file")") == "$digest" ]]; then
			:
		elif retention__source_cache "$cache" "$digest" \
			"$(jq --raw-output '.debian_version' <<<"$release")" "$filename" "$source_file" &&
			[[ $(sha256 "$(<"$source_file")") == "$digest" ]]; then
			:
		else
			if [[ -z $https_base ]]; then
				die "retained package is unavailable: $filename"
			fi
			url=$(jq --raw-output '.url // .download_url // empty' <<<"$record")
			if [[ -n $url ]]; then
				case $url in
				"$https_base"*) ;;
				*) die "retained package URL escapes the previous manifest base: $url" ;;
				esac
			else
				url="$https_base$filename"
			fi
			url_lower=${url,,}
			if [[ $url == *'..'* || $url == *$'\n'* || $url == *$'\r'* ||
				$url == *'?'* || $url == *'#'* || $url_lower == *'%2e'* ||
				$url_lower == *'%2f'* || $url_lower == *'%5c'* || $url != https://* ]]; then
				die "unsafe retained package URL: $url"
			fi
			if ! retention__source_https "$url" "$cache" "$digest" "$source_file"; then
				die "cannot retrieve retained package: $filename"
			fi
		fi
		record_file="$destination/record-${filename##*/}.json"
		if ! retention__record_from_file "$record" "$(<"$source_file")" "$record_file"; then
			die "retained package failed identity validation: $filename"
		fi
		history_file="$cache/history/$digest.deb"
		if [[ "$(<"$source_file")" != "$history_file" ]]; then
			if [[ -e $history_file || -L $history_file ]]; then
				if [[ -L $history_file || ! -f $history_file ||
					$(sha256 "$history_file") != "$digest" ]]; then
					die "historical cache identity collision: $digest"
				fi
			else
				if ! cp -- "$(<"$source_file")" "$history_file"; then
					die "cannot cache historical package: $filename"
				fi
			fi
		fi
		target="$destination/$filename"
		if ! mkdir --parents -- "${target%/*}"; then
			die "cannot create retained package directory: $filename"
		fi
		if ! cp -- "$(<"$source_file")" "$target"; then
			die "cannot stage retained package: $filename"
		fi
		if ! jq --compact-output --arg filename "$filename" --slurpfile normalized "$record_file" \
			'(.packages[] | select(.filename == $filename)) = $normalized[0]' \
			<<<"$release" >"$destination/release.json"; then
			die 'cannot normalize retained package metadata'
		fi
		if ! mv -- "$destination/release.json" "$destination/release.current.json"; then
			die 'cannot install normalized retained metadata'
		fi
		release=$(<"$destination/release.current.json")
		rm --force -- "$record_file"
	done < <(jq --compact-output '.packages[]' <<<"$release")
	rm --force -- "$source_file" "$destination/release.current.json"
	if ! jq --exit-status --arg version "$(jq -r '.debian_version' <<<"$release")" '
        ("libstd-rust-" + (.version | split(".")[0:2] | join("."))) as $runtime |
        (.packages | length == 12) and
        (([.packages[].package] | unique | length) ==
            ([.packages[].package] | length)) and
        all(.packages[]; .debian_version == $version) and
        (([.packages[].package | select(test("^libstd-rust-[0-9]+\\.[0-9]+$"))] | length) == 1) and
        (all(.packages[];
            if .package == "rust-gdb" or .package == "rust-lldb" or
                .package == "rust-doc" or .package == "cargo-doc" or
                .package == "rust-src" or .package == "rust-all" then
                .architecture == "all"
            else .architecture == "amd64" end)) and
        (([.packages[].package] | sort) ==
            (["rustc","cargo","libstd-rust-dev","rustfmt","rust-clippy",
              "rust-gdb","rust-lldb","rust-doc","cargo-doc","rust-src","rust-all",$runtime] | sort))
    ' <<<"$release" >/dev/null; then
		die 'retained release does not contain a complete package set'
	fi
	printf '%s\n' "$release" >"$destination/release.json"
}

retention__copy_to_stage() {
	local release_dir=$1 release=$2 stage=$3 added=$4 record filename source target existing_digest
	: >"$added"
	while IFS= read -r record; do
		filename=$(jq --raw-output '.filename' <<<"$record")
		source="$release_dir/$filename"
		target="$stage/$filename"
		if ! mkdir --parents -- "${target%/*}"; then
			die "cannot create historical archive directory: $filename"
		fi
		if [[ -e $target || -L $target ]]; then
			if [[ -L $target || ! -f $target ]]; then
				die "archive path is not a regular package: $filename"
			fi
			existing_digest=$(sha256 "$target")
			if [[ $existing_digest != "$(jq -r '.sha256' <<<"$record")" ]]; then
				die "historical package path has changed bytes: $filename"
			fi
		else
			if ! cp -- "$source" "$target"; then
				die "cannot copy historical package into archive: $filename"
			fi
			printf '%s\n' "$target" >>"$added"
		fi
	done < <(jq --compact-output '.packages[]' <<<"$release")
}

retention__remove_added() {
	local added=$1 path
	while IFS= read -r path; do
		[[ -n $path ]] && rm --force -- "$path"
	done <"$added"
}

retention__declared_size_exceeds() {
	local release=$1 stage=$2 max_bytes=$3 current_bytes package_bytes
	if ! jq --exit-status 'all(.packages[]; (.size | type) == "number")' <<<"$release" >/dev/null; then
		return 1
	fi
	# Only payload bytes form a safe lower bound. A tar's existing end-of-file
	# padding can be reused by added entries, so adding its padded size could
	# prematurely reject a candidate that fits the exact limit.
	if ! current_bytes=$(tree_bytes "$stage/pool"); then
		die 'cannot measure retained package payload'
	fi
	package_bytes=$(jq --raw-output '[.packages[].size] | add' <<<"$release")
	if ((current_bytes + package_bytes > max_bytes)); then
		return 0
	fi
	return 1
}

retention__render() {
	local stage=$1 metadata=$2 selected=$3 key_file=$4 max_bytes=$5
	local fingerprint now bytes
	if ! archive__refresh_indexes "$stage"; then
		die 'cannot regenerate APT indexes for retained archive'
	fi
	if ! fingerprint=$(sign_archive "$stage" "$key_file"); then
		die 'cannot sign retained archive metadata'
	fi
	now=$(date --utc --iso-8601=seconds)
	if ! jq --slurpfile releases "$selected" --arg fingerprint "$fingerprint" --arg now "$now" \
		'. as $metadata
         | ($releases | map(.packages[])) as $packages
         | . + {
             version: (.version // .release.version // .identity.release.version),
             debian_version: (.debian_version // .identity.debian_version),
             packages: $packages,
             releases: $releases,
             signing_fingerprint: $fingerprint,
             generated_at: $now
           }' "$metadata" >"$stage/releases.json"; then
		die 'cannot write retained release metadata'
	fi
	if [[ ! -f $stage/measurements.json ]]; then
		printf '{}\n' >"$stage/measurements.json"
	fi
	for _ in 1 2 3; do
		if ! bytes=$(measure_pages_artifact_bytes "$stage"); then
			die 'cannot measure retained archive artifact'
		fi
		if ! jq --argjson bytes "$bytes" --argjson limit "$max_bytes" \
			'. + {deployment_bytes:$bytes,max_bytes:$limit}' \
			"$stage/measurements.json" >"$stage/measurements.tmp"; then
			die 'cannot update retained archive measurements'
		fi
		if ! mv -- "$stage/measurements.tmp" "$stage/measurements.json"; then
			die 'cannot install retained archive measurements'
		fi
	done
	if ! bytes=$(measure_pages_artifact_bytes "$stage"); then
		die 'cannot measure retained archive artifact'
	fi
	if ((bytes > max_bytes)); then
		return 1
	fi
}

build_retained_archive() (
	set -o errexit -o nounset -o pipefail
	local current_package_dir=$1 stage=$2 current_metadata=$3 key_file=$4 max_bytes=$5
	local previous_json=$6 previous_location=$7 cache_dir=$8
	local scratch current_release previous_releases sorted_releases selected
	local current_debian latest_debian candidate release_dir added index source_location

	if [[ -e $stage/releases.json || -e $stage/pool || -e $stage/dists ]]; then
		die 'retention requires a fresh staging directory'
	fi
	scratch=$(mktemp --directory "${stage%/*}/.retention-XXXXXX")
	retention__cleanup() {
		local status=$?
		rm --recursive --force -- "$scratch"
		if ((status != 0)); then
			rm --recursive --force -- "$stage"
		fi
		exit "$status"
	}
	trap retention__cleanup EXIT
	mkdir --parents -- "$cache_dir/history"

	# build_archive enforces the current-only limit, so an oversized newest
	# release fails before any historical bytes can affect the stage.
	build_archive "$current_package_dir" "$stage" "$current_metadata" "$key_file" "$max_bytes"
	current_release=$(mktemp "$scratch/current-release.XXXXXX")
	jq --compact-output '
        . as $manifest
        | ($manifest.debian_version // $manifest.identity.debian_version // "") as $deb
        | ($manifest.version // $manifest.release.version //
            $manifest.identity.release.version // "") as $version
        | ($manifest.packages // []) as $packages
        | ($manifest | del(.packages,.releases,.signing_fingerprint,.generated_at,
            .deployment_bytes,.max_bytes))
        + {version:$version,debian_version:$deb,packages:$packages}
    ' "$stage/releases.json" >"$current_release"
	if ! retention__validate_release_shape "$(<"$current_release")"; then
		die 'current archive has invalid release metadata'
	fi
	current_debian=$(jq --raw-output '.debian_version' "$current_release")
	source_location=${previous_location:-$previous_json}
	if ! verify_history_catalog "$previous_json" "$source_location" "$stage/rust-archive-keyring.gpg"; then
		die 'cannot authenticate the previous archive catalog'
	fi

	previous_releases=$(mktemp "$scratch/previous.XXXXXX")
	retention__read_previous_releases "$previous_json" "$previous_releases"
	sorted_releases=$(mktemp "$scratch/sorted.XXXXXX")
	retention__sort_releases "$previous_releases" "$sorted_releases"
	if [[ -s $sorted_releases ]]; then
		latest_debian=$(jq --raw-output '.debian_version' "$sorted_releases" | head --lines=1)
		if [[ -n $latest_debian ]] && ! dpkg --compare-versions "$current_debian" ge "$latest_debian"; then
			die "refusing archive downgrade from $latest_debian to $current_debian"
		fi
	fi

	selected=$(mktemp "$scratch/selected.XXXXXX")
	printf '%s\n' "$(<"$current_release")" >"$selected"
	index=0
	while IFS= read -r candidate; do
		[[ -n $candidate ]] || continue
		candidate_version=$(jq --raw-output '.debian_version' <<<"$candidate")
		if dpkg --compare-versions "$candidate_version" eq "$current_debian"; then
			if ! retention__same_identity "$candidate" "$(<"$current_release")"; then
				die "published package bytes changed at $candidate_version"
			fi
			continue
		fi
		if grep --fixed-strings --line-regexp --quiet "$candidate_version" \
			<(jq --raw-output '.debian_version' "$selected"); then
			continue
		fi
		index=$((index + 1))
		release_dir="$scratch/release-$index"
		if retention__declared_size_exceeds "$candidate" "$stage" "$max_bytes"; then
			break
		fi
		retention__retrieve_release "$candidate" "$release_dir" \
			"$source_location" "$cache_dir" "$(retention__manifest_base "$source_location")"
		candidate=$(<"$release_dir/release.json")
		printf '%s\n' "$candidate" >"$scratch/candidate-$index.json"
		retention__copy_to_stage "$release_dir" "$candidate" "$stage" "$scratch/added-$index"
		printf '%s\n' "$candidate" >>"$selected"
		if ! retention__render "$stage" "$current_metadata" "$selected" "$key_file" "$max_bytes"; then
			retention__remove_added "$scratch/added-$index"
			sed --in-place '$d' "$selected"
			break
		fi
	done <"$sorted_releases"

	if ! retention__render "$stage" "$current_metadata" "$selected" "$key_file" "$max_bytes"; then
		die 'current archive exceeds the deployment size limit'
	fi
)
