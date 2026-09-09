#!/usr/bin/env bash

# These fixtures exercise the signed channel-selection and immutable release
# manifest pair without contacting static.rust-lang.org.  The toy package
# builds at the end ensure that the manifest URL/hash are part of the same
# bytes and cache identity for both discovery routes.

discovery__write_manifest() {
	local output=$1 version=$2 hash_char=${3:-0}
	local hash
	hash=$(printf '%064d' 0 | sed "s/0/$hash_char/g")
	write_channel_manifest "$output"
	sed -i "s/version = \"1.91.1 (fixture)\"/version = \"$version (fixture)\"/" "$output"
	sed -i "s/[0-9a-f]\{64\}/$hash/g" "$output"
}

discovery__sign_manifest() {
	local key_home=$1 manifest=$2
	rm --force -- "$manifest.asc"
	gpg --batch --homedir "$key_home" --pinentry-mode loopback --passphrase '' \
		--armor --output "$manifest.asc" --detach-sign "$manifest"
}

discovery__curl() {
	local output='' url='' option
	while (( $# > 0 )); do
		option=$1
		case $option in
		--output|--proto|--proto-redir|--retry|--connect-timeout|--max-time)
			if (( $# < 2 )); then
				return 2
			fi
			if [[ $option == '--output' ]]; then
				output=$2
			fi
			shift 2
			;;
		--fail|--silent|--show-error|--location)
			shift
			;;
		--*)
			shift
			;;
		*)
			url=$option
			shift
			;;
		esac
	done
	if [[ -z $output || -z $url ]]; then
		return 2
	fi
	printf '%s\n' "$url" >>"$DISCOVERY_CURL_LOG"
	case $url in
	https://static.rust-lang.org/dist/channel-rust-stable.toml)
		cp -- "$DISCOVERY_FIXTURES/stable.toml" "$output"
		;;
	https://static.rust-lang.org/dist/channel-rust-stable.toml.asc)
		cp -- "$DISCOVERY_FIXTURES/stable.toml.asc" "$output"
		;;
	https://static.rust-lang.org/dist/channel-rust-1.98.1.toml)
		cp -- "$DISCOVERY_FIXTURES/canonical.toml" "$output"
		;;
	https://static.rust-lang.org/dist/channel-rust-1.98.1.toml.asc)
		cp -- "$DISCOVERY_FIXTURES/canonical.toml.asc" "$output"
		;;
	*)
		return 22
		;;
	esac
}

discovery__assert_call_count() {
	local expected=$1 url=$2 actual
	if ! actual=$(grep --fixed-strings --line-regexp --count "$url" "$DISCOVERY_CURL_LOG"); then
		assert_eq 0 "$actual" 'missing download count'
	fi
	assert_eq "$expected" "$actual" "download count for $url"
}

discovery__write_identity() {
	local release=$1 output=$2
	local recipe
	recipe=$(recipe_digest "$ROOT_DIR")
	jq --null-input --slurpfile release "$release" --arg recipe "$recipe" \
		--arg version "$DEB_VERSION" \
		'{package_recipe_format:2,release:$release[0],recipe_sha256:$recipe,debian_version:$version}' \
		>"$output"
}

test_canonical_discovery() (
	set -Eeuo pipefail
	local directory="$WORK_DIR/discovery"
	local key_home="$directory/gnupg"
	local private="$directory/private.asc"
	local public="$directory/public.asc"
	local version='1.98.1'
	local revision='2'
	local stable_work="$directory/stable-work"
	local explicit_work="$directory/explicit-work"
	local stable_roots="$directory/stable-roots"
	local explicit_roots="$directory/explicit-roots"
	local stable_release="$directory/stable-release.json"
	local explicit_release="$directory/explicit-release.json"
	local stable_packages="$directory/stable-packages"
	local explicit_packages="$directory/explicit-packages"
	local stable_identity="$directory/stable-identity.json"
	local explicit_identity="$directory/explicit-identity.json"
	local stable_cache="$directory/stable-cache"
	local explicit_cache="$directory/explicit-cache"
	local package deb filename fingerprint
	mkdir --parents "$directory" "$stable_work" "$explicit_work"

	make_test_key "$key_home" "$private"
	gpg --batch --homedir "$key_home" --armor --export >"$public"
	fingerprint=$(gpg --batch --homedir "$key_home" --with-colons --list-keys |
		awk -F: '$1 == "fpr" { print $10; exit }')
	# shellcheck disable=SC2034
	RUST_RELEASE_FINGERPRINT=$fingerprint

	discovery__write_manifest "$directory/stable.toml" "$version" 0
	discovery__write_manifest "$directory/canonical.toml" "$version" 1
	discovery__sign_manifest "$key_home" "$directory/stable.toml"
	discovery__sign_manifest "$key_home" "$directory/canonical.toml"
	: >"$directory/curl.log"
	# shellcheck disable=SC2034
	DISCOVERY_FIXTURES=$directory
	# shellcheck disable=SC2034
	DISCOVERY_CURL_LOG=$directory/curl.log
	curl() {
		discovery__curl "$@"
	}

	discover_release "$stable_work" "$public" stable
	discovery__assert_call_count 1 \
		'https://static.rust-lang.org/dist/channel-rust-stable.toml'
	discovery__assert_call_count 1 \
		'https://static.rust-lang.org/dist/channel-rust-stable.toml.asc'
	discovery__assert_call_count 1 \
		"https://static.rust-lang.org/dist/channel-rust-$version.toml"
	discovery__assert_call_count 1 \
		"https://static.rust-lang.org/dist/channel-rust-$version.toml.asc"
	: >"$DISCOVERY_CURL_LOG"
	discover_release "$explicit_work" "$public" "$version"
	discovery__assert_call_count 0 \
		'https://static.rust-lang.org/dist/channel-rust-stable.toml'
	discovery__assert_call_count 0 \
		'https://static.rust-lang.org/dist/channel-rust-stable.toml.asc'
	discovery__assert_call_count 1 \
		"https://static.rust-lang.org/dist/channel-rust-$version.toml"
	discovery__assert_call_count 1 \
		"https://static.rust-lang.org/dist/channel-rust-$version.toml.asc"
	cmp -- "$stable_work/release.json" "$explicit_work/release.json"
	assert_eq "$version" "$(jq --raw-output '.version' "$stable_work/release.json")" \
		'discovered canonical release version'
	assert_eq \
		"https://static.rust-lang.org/dist/channel-rust-$version.toml" \
		"$(jq --raw-output '.manifest_url' "$stable_work/release.json")" \
		'canonical manifest URL in release metadata'
	assert_eq "$(sha256 "$directory/canonical.toml")" \
		"$(jq --raw-output '.manifest_sha256' "$stable_work/release.json")" \
		'canonical manifest hash in release metadata'

	# The immutable manifest is the complete release input.  Building the same
	# toy roots from either route therefore produces twelve identical packages.
	init_layout "$version" "$revision"
	make_toy_fixture "$stable_roots" "$stable_release" '123' "$version" "$revision"
	cp -- "$stable_work/release.json" "$stable_release"
	make_toy_fixture "$explicit_roots" "$explicit_release" '123' "$version" "$revision"
	cp -- "$explicit_work/release.json" "$explicit_release"
	build_packages "$stable_roots" "$stable_packages" "$stable_release"
	build_packages "$explicit_roots" "$explicit_packages" "$explicit_release"
	for package in "${PACKAGE_NAMES[@]}"; do
		deb=$(find "$stable_packages" -maxdepth 1 -type f -name "${package}_${DEB_VERSION}_*.deb" -print)
		filename=${deb##*/}
		cmp -- "$deb" "$explicit_packages/$filename"
	done
	discovery__write_identity "$stable_release" "$stable_identity"
	discovery__write_identity "$explicit_release" "$explicit_identity"
	cmp -- "$stable_identity" "$explicit_identity"
	record_package_cache "$stable_packages" "$stable_cache" "$stable_identity" \
		"$directory/stable-inventory.ndjson"
	record_package_cache "$explicit_packages" "$explicit_cache" "$explicit_identity" \
		"$directory/explicit-inventory.ndjson"
	cmp -- "$stable_cache/metadata.json" "$explicit_cache/metadata.json"
	check_package_cache "$stable_cache" "$explicit_identity"
	assert_eq true "$PACKAGE_CACHE_HIT" 'explicit selection reuses stable package cache'
	check_package_cache "$explicit_cache" "$stable_identity"
	assert_eq true "$PACKAGE_CACHE_HIT" 'stable selection reuses explicit package cache'
	for package in "$stable_packages"/*.deb; do
		filename=${package##*/}
		cmp -- "$package" "$explicit_cache/$filename"
	done

	# A valid signature on the selection is required before canonical lookup.
	cp -- "$directory/stable.toml" "$directory/stable.toml.saved"
	printf 'tampered selection manifest\n' >>"$directory/stable.toml"
	expect_failure 'selection signature failure' discover_release "$directory/selection-fail" \
		"$public" stable
	mv -- "$directory/stable.toml.saved" "$directory/stable.toml"

	# The canonical signature is checked independently, even when selection was
	# authenticated successfully.
	cp -- "$directory/canonical.toml" "$directory/canonical.toml.saved"
	printf 'tampered canonical manifest\n' >>"$directory/canonical.toml"
	expect_failure 'canonical signature failure' discover_release "$directory/canonical-fail" \
		"$public" stable
	mv -- "$directory/canonical.toml.saved" "$directory/canonical.toml"

	# A signed canonical manifest with a different release is not an acceptable
	# replacement for the version selected by the signed stable manifest.
	discovery__write_manifest "$directory/canonical.toml" '1.98.2' 1
	discovery__sign_manifest "$key_home" "$directory/canonical.toml"
	expect_failure 'canonical version mismatch' discover_release "$directory/version-fail" \
		"$public" stable
	discovery__write_manifest "$directory/canonical.toml" "$version" 1
	discovery__sign_manifest "$key_home" "$directory/canonical.toml"

	# Signed schema changes remain failures, including a malformed component
	# hash.  This catches accidental URL-only canonicalization.
	discovery__write_manifest "$directory/canonical.toml" "$version" 1
	sed -i '0,/xz_hash = "[0-9a-f]\{64\}"/s//xz_hash = "000000000000000000000000000000000000000000000000000000000000000"/' \
		"$directory/canonical.toml"
	discovery__sign_manifest "$key_home" "$directory/canonical.toml"
	expect_failure 'canonical schema failure' discover_release "$directory/schema-fail" \
		"$public" stable
	discovery__write_manifest "$directory/canonical.toml" "$version" 1
	discovery__sign_manifest "$key_home" "$directory/canonical.toml"

	# Explicit requests must agree with the signed manifest they selected.
	discovery__write_manifest "$directory/canonical.toml" '1.98.2' 1
	discovery__sign_manifest "$key_home" "$directory/canonical.toml"
	expect_failure 'requested version mismatch' discover_release "$directory/request-fail" \
		"$public" "$version"
)
