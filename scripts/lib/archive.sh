#!/usr/bin/env bash

# shellcheck source=scripts/lib/activation.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/activation.sh"

fetch_published_metadata() {
	local location=$1 output=$2 status
	case $location in
	https://*)
		status=$(curl --silent --show-error --location --proto '=https' --proto-redir '=https' \
			--retry 3 --connect-timeout 30 --max-time 120 --output "$output" \
			--write-out '%{http_code}' "$location")
		case $status in
		200) ;;
		404) printf '{}\n' >"$output" ;;
		*) die "published manifest returned HTTP $status" ;;
		esac
		;;
	*)
		if [[ -f $location ]]; then
			cp -- "$location" "$output"
		else
			printf '{}\n' >"$output"
		fi
		;;
	esac
	jq --exit-status 'type == "object"' "$output" >/dev/null
}

check_identities() {
	local previous=$1 current=$2 old_version new_version
	if ! jq --exit-status --slurp '
        (.[0].packages // [] | map({key: .filename, value: .sha256}) | from_entries) as $old
        | all(.[1].packages[]; ($old[.filename] == null or $old[.filename] == .sha256))
    ' "$previous" "$current" >/dev/null; then
		die 'published package bytes changed; increment the packaging revision'
	fi
	old_version=$(jq --raw-output '.debian_version // empty' "$previous")
	new_version=$(jq --raw-output '.debian_version' "$current")
	if [[ -n $old_version ]] && ! dpkg --compare-versions "$new_version" ge "$old_version"; then
		die "refusing archive downgrade from $old_version to $new_version"
	fi
}

sign_archive() (
	set -o errexit -o nounset -o pipefail
	stage=$1 key_file=$2
	signing_home=$(mktemp --directory)
	trap 'gpgconf --homedir "$signing_home" --kill gpg-agent; rm --recursive --force -- "$signing_home"' EXIT
	if ! gpg --batch --homedir "$signing_home" --import "$key_file" >&2; then
		die 'cannot import archive signing key'
	fi
	if ! mapfile -t fingerprints < <(gpg --batch --homedir "$signing_home" --with-colons --list-secret-keys |
		awk -F: '$1 == "sec" { primary=1 } $1 == "fpr" && primary { print $10; primary=0 }'); then
		die 'cannot inspect archive signing key'
	fi
	if [[ ${#fingerprints[@]} != 1 ]]; then
		die 'provide exactly one archive signing key'
	fi
	fingerprint=${fingerprints[0]}
	rm --force -- "$stage/rust-archive-keyring.gpg" "$stage/dists/jammy/InRelease" \
		"$stage/dists/jammy/Release.gpg"
	if ! gpg --batch --homedir "$signing_home" --export-options export-minimal \
		--output "$stage/rust-archive-keyring.gpg" --export "$fingerprint"; then
		die 'cannot export archive signing key'
	fi
	options=(--batch --homedir "$signing_home" --pinentry-mode loopback --passphrase-fd 0
		--local-user "$fingerprint" --digest-algo SHA256)
	if ! gpg "${options[@]}" --output "$stage/dists/jammy/InRelease" \
		--clearsign "$stage/dists/jammy/Release" <<<"${APT_GPG_PASSPHRASE:-}"; then
		die 'cannot create inline archive signature'
	fi
	if ! gpg "${options[@]}" --armor --output "$stage/dists/jammy/Release.gpg" \
		--detach-sign "$stage/dists/jammy/Release" <<<"${APT_GPG_PASSPHRASE:-}"; then
		die 'cannot create detached archive signature'
	fi
	if ! gpgv --homedir "$signing_home" --keyring "$stage/rust-archive-keyring.gpg" \
		"$stage/dists/jammy/Release.gpg" "$stage/dists/jammy/Release" >&2; then
		die 'archive signature verification failed'
	fi
	printf '%s\n' "$fingerprint"
)

archive__package_record() {
	local deb=$1 filename=$2 fields package version architecture
	fields=$(dpkg-deb --field "$deb" Package Version Architecture) ||
		die "cannot inspect package: $deb"
	package=$(printf '%s\n' "$fields" | sed --quiet 's/^Package: //p')
	version=$(printf '%s\n' "$fields" | sed --quiet 's/^Version: //p')
	architecture=$(printf '%s\n' "$fields" | sed --quiet 's/^Architecture: //p')
	if [[ -z $package || -z $version || -z $architecture ]]; then
		die "package metadata is incomplete: $deb"
	fi
	if ! jq --null-input --compact-output \
		--arg package "$package" --arg debian_version "$version" \
		--arg architecture "$architecture" --arg filename "$filename" \
		--arg sha256 "$(sha256 "$deb")" --argjson size "$(stat --format='%s' "$deb")" \
		'{package:$package,debian_version:$debian_version,architecture:$architecture,
          filename:$filename,sha256:$sha256,size:$size}'; then
		die "cannot record package metadata: $deb"
	fi
}

archive__copy_current_packages() {
	local package_dir=$1 stage=$2 inventory=$3 deb filename
	: >"$inventory"
	mkdir --parents -- "$stage/pool/main/r/rust-upstream"
	for deb in "$package_dir"/*.deb; do
		filename="pool/main/r/rust-upstream/${deb##*/}"
		if ! cp -- "$deb" "$stage/$filename"; then
			die "cannot copy package into archive: $deb"
		fi
		archive__package_record "$deb" "$filename" >>"$inventory"
	done
}

archive__refresh_indexes() {
	local stage=$1
	# Never hash an earlier Release (or its signatures) into a replacement.
	rm --force -- "$stage/dists/jammy/Release" "$stage/dists/jammy/InRelease" \
		"$stage/dists/jammy/Release.gpg"
	if ! mkdir --parents -- "$stage/dists/jammy/main/binary-amd64"; then
		die 'cannot create APT index directory'
	fi
	if ! (cd -- "$stage" && apt-ftparchive packages pool) \
		>"$stage/dists/jammy/main/binary-amd64/Packages"; then
		die 'cannot generate APT package index'
	fi
	if ! gzip --no-name --stdout "$stage/dists/jammy/main/binary-amd64/Packages" \
		>"$stage/dists/jammy/main/binary-amd64/Packages.gz"; then
		die 'cannot compress APT package index'
	fi
	if ! (cd -- "$stage/dists/jammy" && apt-ftparchive \
		-o 'APT::FTPArchive::Release::Origin=Unofficial Rust APT' \
		-o 'APT::FTPArchive::Release::Label=Unofficial Rust APT' \
		-o 'APT::FTPArchive::Release::Suite=jammy' \
		-o 'APT::FTPArchive::Release::Codename=jammy' \
		-o 'APT::FTPArchive::Release::Architectures=amd64' \
		-o 'APT::FTPArchive::Release::Components=main' release .) >"$stage/Release.generated"; then
		die 'cannot generate APT release metadata'
	fi
	if ! mv -- "$stage/Release.generated" "$stage/dists/jammy/Release"; then
		die 'cannot install APT release metadata'
	fi
}

archive__write_static_files() {
	local stage=$1
	touch -- "$stage/.nojekyll"
	cat >"$stage/index.html" <<'HTML'
<!doctype html><html lang="en"><meta charset="utf-8"><title>Unofficial Rust APT</title>
<h1>Unofficial Rust APT repository</h1>
<p>Independent upstream Rust packages for Ubuntu 22.04 (Jammy), amd64.</p>
<p>This repository is not affiliated with the Rust project or Ubuntu.</p>
<p><a href="releases.json">Package checksums and provenance</a> ·
<a href="rust-archive-keyring.gpg">Archive signing key</a></p></html>
HTML
}

measure_pages_artifact_bytes() {
	local stage=$1
	tar --dereference --hard-dereference --directory "$stage" \
		--exclude=.git --exclude=.github --create --file=- . | wc --bytes
}

archive__set_public_permissions() {
	local stage=$1
	if ! find "$stage" -type d -exec chmod 0755 -- {} + ||
		! find "$stage" -type f -exec chmod 0644 -- {} +; then
		die 'cannot make completed archive publicly readable'
	fi
}

build_archive() {
	local package_dir=$1 stage=$2 metadata=$3 key_file=$4 max_bytes=$5
	local fingerprint bytes inventory
	mkdir --parents -- "$stage/pool/main/r/rust-upstream" "$stage/dists/jammy/main/binary-amd64"
	inventory="$stage/packages.ndjson"
	archive__copy_current_packages "$package_dir" "$stage" "$inventory"
	archive__refresh_indexes "$stage"
	# Stable-release polling leaves unchanged archives in place for weeks.
	# Release signatures are mandatory, with no short Valid-Until deadline.
	fingerprint=$(sign_archive "$stage" "$key_file")
	if ! jq --slurpfile packages "$inventory" --arg fingerprint "$fingerprint" \
		--arg now "$(date --utc --iso-8601=seconds)" \
		'. + {packages:$packages, signing_fingerprint:$fingerprint, generated_at:$now}' \
		"$metadata" >"$stage/releases.json"; then
		die 'cannot write release metadata'
	fi
	rm --force -- "$inventory"
	archive__write_static_files "$stage"
	if [[ ! -f $stage/measurements.json ]]; then
		printf '{}\n' >"$stage/measurements.json"
	fi
	# Iterate to include the encoded size of the measurement itself.
	for _ in 1 2 3; do
		if ! bytes=$(measure_pages_artifact_bytes "$stage"); then
			die 'cannot measure archive artifact'
		fi
		if ! jq --argjson bytes "$bytes" --argjson limit "$max_bytes" \
			'. + {deployment_bytes:$bytes, max_bytes:$limit}' \
			"$stage/measurements.json" >"$stage/measurements.tmp"; then
			die 'cannot update archive measurements'
		fi
		if ! mv -- "$stage/measurements.tmp" "$stage/measurements.json"; then
			die 'cannot install archive measurements'
		fi
	done
	if ! bytes=$(measure_pages_artifact_bytes "$stage"); then
		die 'cannot measure archive artifact'
	fi
	if ((bytes > max_bytes)); then
		die "archive is $bytes bytes; limit is $max_bytes"
	fi
	archive__set_public_permissions "$stage"
}
