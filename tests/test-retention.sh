#!/usr/bin/env bash

# Retention tests are sourced by tests/test.sh after the package/archive
# fixtures have been loaded.  They deliberately use the real Debian builder,
# apt-ftparchive, GnuPG, and APT clients against disposable directories.

retention__metadata() {
	local release=$1
	local output=$2
	local version=$3
	local revision=$4
	local debian_version="$version-$revision"
	jq --arg version "$version" --arg debian_version "$debian_version" \
		--arg revision "$revision" \
		'. + {
            version:$version,
            debian_version:$debian_version,
            suite:"jammy",
            architecture:"amd64",
            identity:{version:$version,debian_version:$debian_version,
                       recipe_sha256:("retention-fixture-" + $version + "-" + $revision)}
        }' "$release" >"$output"
}

retention__index_has() {
	local index=$1
	local package=$2
	local version=$3
	awk -v package="$package" -v version="$version" '
        BEGIN { RS=""; FS="\n" }
        {
            has_package=0
            has_version=0
            for (field = 1; field <= NF; field++) {
                if ($field == "Package: " package) has_package=1
                if ($field == "Version: " version) has_version=1
            }
            if (has_package && has_version) found=1
        }
        END { exit found ? 0 : 1 }
    ' "$index"
}

retention__assert_previous_bytes() {
	local first=$1
	local second=$2
	local filename expected actual
	while IFS= read -r filename; do
		assert_file "$second/$filename" "retained historical package $filename"
		expected=$(sha256sum -- "$first/$filename" | awk '{print $1}')
		actual=$(sha256sum -- "$second/$filename" | awk '{print $1}')
		assert_eq "$expected" "$actual" "unchanged historical bytes for $filename"
	done < <(jq --raw-output '.packages[].filename' "$first/releases.json")
}

retention__write_dependency_repo() {
	local root=$1
	local package build_root deb
	mkdir --parents "$root/dists/jammy/main/binary-amd64"
	mkdir --parents "$root/pool/main/f/fake"
	for package in gcc libc6-dev binutils gdb lldb-14 python3-lldb-14 liblldb-14-dev; do
		build_root="$root/build-$package"
		deb="$root/pool/main/f/fake/${package}_1_amd64.deb"
		mkdir --parents "$build_root/DEBIAN"
		printf 'Package: %s\nVersion: 1\nArchitecture: amd64\nMaintainer: Retention Test <test@example.invalid>\nDescription: APT retention dependency fixture\n' \
			"$package" >"$build_root/DEBIAN/control"
		dpkg-deb --build --root-owner-group "$build_root" "$deb" >/dev/null
		rm --recursive --force -- "$build_root"
	done
	(
		cd "$root" || exit
		apt-ftparchive packages pool
	) >"$root/dists/jammy/main/binary-amd64/Packages"
	(cd "$root/dists/jammy" && apt-ftparchive \
		-o 'APT::FTPArchive::Release::Origin=Retention dependency fixture' \
		-o 'APT::FTPArchive::Release::Codename=jammy' \
		-o 'APT::FTPArchive::Release::Architectures=amd64' \
		-o 'APT::FTPArchive::Release::Components=main' release .) >"$root/dists/jammy/Release"
}

test_retained_archive() {
	local directory="$WORK_DIR/retention"
	local private="$directory/private.asc"
	local old_metadata="$directory/old-metadata.json"
	local new_metadata="$directory/new-metadata.json"
	local old_stage="$directory/old-stage"
	local retained_stage="$directory/retained-stage"
	local legacy_stage="$directory/legacy-stage"
	local https_stage="$directory/https-stage"
	local cached_stage="$directory/cached-stage"
	local invalid_shape_stage="$directory/invalid-shape-stage"
	local wrong_prefix_stage="$directory/wrong-prefix-stage"
	local current_stage="$directory/current-stage"
	local boundary_stage="$directory/boundary-stage"
	local below_boundary_stage="$directory/below-boundary-stage"
	local evicted_stage="$directory/evicted-stage"
	local empty_json="$directory/empty.json"
	local old_json="$directory/old.json"
	local legacy_json="$directory/legacy.json"
	local cache="$directory/cache"
	local legacy_cache="$directory/legacy-cache"
	local https_cache="$directory/https-cache"
	local normal_cache="$directory/normal-cache"
	local eviction_cache="$directory/eviction-cache"
	local invalid_shape_json="$directory/invalid-shape.json"
	local wrong_prefix_previous="$directory/wrong-prefix-previous"
	local wrong_prefix_json="$directory/wrong-prefix.json"
	local old_packages new_packages collision_packages
	local old_version='1.91.1' old_revision='1' old_debian='1.91.1-1'
	local new_version='1.92.0' new_revision='1' new_debian='1.92.0-1'
	local current_bytes eviction_limit candidate madison old_download simulation
	local package
	mkdir --parents "$directory" "$cache" "$legacy_cache" "$https_cache" \
		"$normal_cache" "$eviction_cache"
	printf '%s\n' '{}' >"$empty_json"
	make_test_key "$directory/gnupg" "$private"

	build_toy_packages 'retention-old' '101' "$old_version" "$old_revision"
	old_packages=$TOY_PACKAGES
	retention__metadata "$TOY_RELEASE" "$old_metadata" "$old_version" "$old_revision"
	build_retained_archive "$old_packages" "$old_stage" "$old_metadata" "$private" \
		'1000000000' "$empty_json" '' "$cache"
	assert_file "$old_stage/releases.json" 'initial retained archive metadata'
	assert_file "$old_stage/dists/jammy/InRelease" 'initial retained archive signature'
	assert_file "$old_stage/dists/jammy/Release.gpg" 'initial detached archive signature'

	build_toy_packages 'retention-new' '102' "$new_version" "$new_revision"
	new_packages=$TOY_PACKAGES
	retention__metadata "$TOY_RELEASE" "$new_metadata" "$new_version" "$new_revision"
	cp -- "$old_stage/releases.json" "$old_json"
	mkdir --mode=0700 -- "$retained_stage"
	build_retained_archive "$new_packages" "$retained_stage" "$new_metadata" "$private" \
		'1000000000' "$old_json" "$old_stage/releases.json" "$cache"
	assert_public_archive "$retained_stage"
	assert_file "$retained_stage/releases.json" 'merged retained archive metadata'
	gpgv --keyring "$retained_stage/rust-archive-keyring.gpg" \
		"$retained_stage/dists/jammy/Release.gpg" "$retained_stage/dists/jammy/Release" \
		>/dev/null 2>&1
	gpgv --keyring "$retained_stage/rust-archive-keyring.gpg" \
		"$retained_stage/dists/jammy/InRelease" >/dev/null 2>&1

	jq -e --arg version "$new_version" --arg debian_version "$new_debian" '
        .version == $version and
        .debian_version == $debian_version and
        .identity.version == $version and
        (.releases | type == "array" and length == 2) and
        ([.releases[] | select(.version == "1.91.1" and .debian_version == "1.91.1-1")] | length == 1) and
        ([.releases[] | select(.version == $version and .debian_version == $debian_version)] | length == 1) and
        (.packages | type == "array" and length == 24)
    ' "$retained_stage/releases.json" >/dev/null
	assert_eq '12' "$(grep --count '^Version: 1.91.1-1$' \
		"$retained_stage/dists/jammy/main/binary-amd64/Packages")" \
		'twelve old package records in the merged index'
	assert_eq '12' "$(grep --count '^Version: 1.92.0-1$' \
		"$retained_stage/dists/jammy/main/binary-amd64/Packages")" \
		'twelve current package records in the merged index'
	assert_eq '24' "$(grep --count '^Package: ' \
		"$retained_stage/dists/jammy/main/binary-amd64/Packages")" \
		'all retained package records in the merged index'
	retention__index_has "$retained_stage/dists/jammy/main/binary-amd64/Packages" rustc "$old_debian"
	retention__index_has "$retained_stage/dists/jammy/main/binary-amd64/Packages" rustc "$new_debian"
	retention__assert_previous_bytes "$old_stage" "$retained_stage"

	# A pre-retention manifest had one top-level release.  Keep this path
	# covered because published archives may be upgraded from that format.
	jq 'del(.releases)' "$old_stage/releases.json" >"$legacy_json"
	build_retained_archive "$new_packages" "$legacy_stage" "$new_metadata" "$private" \
		'1000000000' "$legacy_json" "$old_stage/releases.json" "$legacy_cache"
	jq -e --arg version "$new_version" '
        (.releases | type == "array" and length == 2) and
        any(.releases[]; .version == "1.91.1") and
        any(.releases[]; .version == $version) and
        (.packages | length == 24)
    ' "$legacy_stage/releases.json" >/dev/null
	retention__assert_previous_bytes "$old_stage" "$legacy_stage"

	# Exercise the remote retrieval branch without contacting the network.
	# The curl shim serves exactly the files in the local previous archive.
	curl() {
		local output='' url='' option
		while (($# > 0)); do
			option=$1
			case "$option" in
			--output | --proto | --proto-redir | --retry | --connect-timeout | --max-time)
				if (($# < 2)); then
					return 2
				fi
				if [[ $option == '--output' ]]; then
					output=$2
				fi
				shift 2
				;;
			--*) shift ;;
			*)
				url=$option
				shift
				;;
			esac
		done
		if [[ -z $output || -z $url ]]; then
			return 2
		fi
		case "$url" in
		https://fixtures.invalid/dists/jammy/InRelease)
			cp -- "$old_stage/dists/jammy/InRelease" "$output"
			;;
		https://fixtures.invalid/dists/jammy/Release)
			cp -- "$old_stage/dists/jammy/Release" "$output"
			;;
		https://fixtures.invalid/dists/jammy/Release.gpg)
			cp -- "$old_stage/dists/jammy/Release.gpg" "$output"
			;;
		https://fixtures.invalid/dists/jammy/main/binary-amd64/Packages)
			cp -- "$old_stage/dists/jammy/main/binary-amd64/Packages" "$output"
			;;
		https://fixtures.invalid/dists/jammy/main/binary-amd64/Packages.gz)
			cp -- "$old_stage/dists/jammy/main/binary-amd64/Packages.gz" "$output"
			;;
		https://fixtures.invalid/pool/*)
			local relative=${url#https://fixtures.invalid/}
			cp -- "$old_stage/$relative" "$output"
			;;
		*) return 22 ;;
		esac
	}
	build_retained_archive "$new_packages" "$https_stage" "$new_metadata" "$private" \
		'1000000000' "$old_json" 'https://fixtures.invalid/releases.json' "$https_cache"
	retention__assert_previous_bytes "$old_stage" "$https_stage"
	unset -f curl

	# A normal package cache is sufficient when the original publication is
	# unavailable.  This is intentionally a cold history cache: only the
	# per-release package cache is populated.
	mkdir --parents "$normal_cache/packages/$old_debian"
	while IFS= read -r package; do
		cp -- "$old_stage/$package" "$normal_cache/packages/$old_debian/${package##*/}"
	done < <(jq --raw-output '.packages[].filename' "$old_stage/releases.json")
	chmod 0600 -- "$normal_cache/packages/$old_debian"/*.deb
	curl() {
		local output='' url='' option
		while (($# > 0)); do
			option=$1
			case "$option" in
			--output | --proto | --proto-redir | --retry | --connect-timeout | --max-time)
				if (($# < 2)); then
					return 2
				fi
				if [[ $option == '--output' ]]; then
					output=$2
				fi
				shift 2
				;;
			--*) shift ;;
			*)
				url=$option
				shift
				;;
			esac
		done
		if [[ -z $output || -z $url ]]; then
			return 2
		fi
		case "$url" in
		https://fixtures.invalid/dists/jammy/InRelease)
			cp -- "$old_stage/dists/jammy/InRelease" "$output"
			;;
		https://fixtures.invalid/dists/jammy/Release)
			cp -- "$old_stage/dists/jammy/Release" "$output"
			;;
		https://fixtures.invalid/dists/jammy/Release.gpg)
			cp -- "$old_stage/dists/jammy/Release.gpg" "$output"
			;;
		https://fixtures.invalid/dists/jammy/main/binary-amd64/Packages)
			cp -- "$old_stage/dists/jammy/main/binary-amd64/Packages" "$output"
			;;
		https://fixtures.invalid/dists/jammy/main/binary-amd64/Packages.gz)
			cp -- "$old_stage/dists/jammy/main/binary-amd64/Packages.gz" "$output"
			;;
		*) return 22 ;;
		esac
	}
	build_retained_archive "$new_packages" "$cached_stage" "$new_metadata" "$private" \
		'1000000000' "$old_json" 'https://fixtures.invalid/releases.json' "$normal_cache"
	retention__assert_previous_bytes "$old_stage" "$cached_stage"
	assert_public_archive "$cached_stage"
	unset -f curl

	# Twelve records with arbitrary package identities are not a valid Rust
	# release, even though the count and checksums look superficially right.
	jq '.releases[0].packages |= map(.package = "arbitrary-retention-package")' \
		"$old_stage/releases.json" >"$invalid_shape_json"
	expect_failure 'invalid retained package shape' build_retained_archive "$new_packages" \
		"$invalid_shape_stage" "$new_metadata" "$private" '1000000000' \
		"$invalid_shape_json" "$old_stage/releases.json" "$normal_cache"
	if [[ -e "$invalid_shape_stage/releases.json" ]]; then
		printf '%s\n' 'invalid retained package shape left a partial output' >&2
		return 1
	fi

	# A package path outside pool/main is not part of the published APT index
	# and must never be silently retained as an unindexed artifact.
	cp --archive "$old_stage" "$wrong_prefix_previous"
	package=$(jq --raw-output '.packages[0].filename' "$old_stage/releases.json")
	wrong_filename="outside/${package##*/}"
	mkdir --parents "$wrong_prefix_previous/outside"
	cp -- "$wrong_prefix_previous/$package" "$wrong_prefix_previous/$wrong_filename"
	jq --arg old "$package" --arg wrong "$wrong_filename" '
        (.releases[0].packages[] | select(.filename == $old) | .filename) = $wrong |
        (.packages[] | select(.filename == $old) | .filename) = $wrong
    ' "$wrong_prefix_previous/releases.json" >"$wrong_prefix_json"
	expect_failure 'retained package outside pool' build_retained_archive "$new_packages" \
		"$wrong_prefix_stage" "$new_metadata" "$private" '1000000000' \
		"$wrong_prefix_json" "$wrong_prefix_previous/releases.json" "$normal_cache"
	if [[ -e "$wrong_prefix_stage/releases.json" ]]; then
		printf '%s\n' 'retained package outside pool left a partial output' >&2
		return 1
	fi

	# The size bound is chosen from a real current-only archive.  It leaves
	# enough room for metadata churn while making the complete old set exceed
	# the bound, so eviction must remove all twelve old packages together.
	build_retained_archive "$new_packages" "$current_stage" "$new_metadata" "$private" \
		'1000000000' "$empty_json" '' "$eviction_cache"
	current_bytes=$(measure_pages_artifact_bytes "$current_stage")
	assert_eq "$current_bytes" "$(jq -er '.deployment_bytes' "$current_stage/measurements.json")" \
		'deployment measurement matches the Pages tar artifact'
	build_retained_archive "$new_packages" "$boundary_stage" "$new_metadata" "$private" \
		"$current_bytes" "$empty_json" '' "$eviction_cache"
	expect_failure 'one byte below newest artifact size' build_retained_archive "$new_packages" \
		"$below_boundary_stage" "$new_metadata" "$private" "$((current_bytes - 1))" \
		"$empty_json" '' "$eviction_cache"
	eviction_limit=$((current_bytes + 4096))
	build_retained_archive "$new_packages" "$evicted_stage" "$new_metadata" "$private" \
		"$eviction_limit" "$old_json" "$old_stage/releases.json" "$eviction_cache"
	jq -e --arg version "$new_version" --arg debian_version "$new_debian" '
        (.releases | length == 1) and
        .releases[0].version == $version and
        .releases[0].debian_version == $debian_version and
        (.packages | length == 12)
    ' "$evicted_stage/releases.json" >/dev/null
	if find "$evicted_stage/pool" -type f -name '*_1.91.1-1_*.deb' -print -quit | grep --quiet .; then
		printf '%s\n' 'old package files survived whole-release eviction' >&2
		return 1
	fi
	package=rustc
	assert_file "$evicted_stage/pool/main/r/rust-upstream/${package}_${new_debian}_amd64.deb" \
		'current package survives whole-release eviction'

	# Build an isolated repository and ask APT to inspect both versions.  The
	# only download is the selected old rustc .deb; package installation is
	# never attempted and status is an empty disposable file.
	local apt_root="$directory/apt"
	local dependency_repo="$directory/dependencies"
	local download_dir="$apt_root/downloads"
	setup_apt_test_root "$apt_root"
	mkdir --parents "$download_dir"
	retention__write_dependency_repo "$dependency_repo"
	printf 'deb [signed-by=%s] file:%s jammy main\ndeb [trusted=yes] file:%s jammy main\n' \
		"$retained_stage/rust-archive-keyring.gpg" \
		"$retained_stage" "$dependency_repo" >"$apt_root/sources.list"
	apt-get "${APT_TEST_OPTIONS[@]}" update >"$apt_root/update.log" 2>&1
	candidate=$(apt-cache "${APT_TEST_OPTIONS[@]}" policy rustc | awk '/Candidate:/ { print $2 }')
	assert_eq "$new_debian" "$candidate" 'latest retained package is the default APT candidate'
	madison=$(apt-cache "${APT_TEST_OPTIONS[@]}" madison rustc)
	if [[ $madison != *"$old_debian"* || $madison != *"$new_debian"* ]]; then
		printf 'APT madison omitted one retained rustc version:\n%s\n' "$madison" >&2
		return 1
	fi
	old_download=$(find "$download_dir" -maxdepth 1 -type f -name "rustc_*${old_debian}_*.deb" -print -quit)
	if [[ -n $old_download ]]; then
		rm --force -- "$old_download"
	fi
	(cd "$download_dir" && apt-get "${APT_TEST_OPTIONS[@]}" download "rustc=$old_debian") \
		>"$apt_root/download.log" 2>&1
	old_download=$(find "$download_dir" -maxdepth 1 -type f -name "rustc_*${old_debian}_*.deb" -print -quit)
	assert_file "$old_download" 'APT downloads an explicitly selected historical rustc'
	assert_eq "$old_debian" "$(dpkg-deb --field "$old_download" Version)" \
		'downloaded historical rustc has the requested version'
	for package in gcc libc6-dev binutils gdb lldb-14 python3-lldb-14 liblldb-14-dev; do
		candidate=$(apt-cache "${APT_TEST_OPTIONS[@]}" policy "$package" |
			awk '/Candidate:/ { print $2 }')
		assert_eq '1' "$candidate" "matching dependency candidate for $package"
	done
	simulation=$(apt-get "${APT_TEST_OPTIONS[@]}" --simulate --no-download install --no-remove \
		"rustc=$old_debian" "cargo=$old_debian" \
		"libstd-rust-1.91=$old_debian" "libstd-rust-dev=$old_debian" \
		"rustfmt=$old_debian" "rust-clippy=$old_debian" "rust-gdb=$old_debian" \
		"rust-lldb=$old_debian" "rust-doc=$old_debian" "cargo-doc=$old_debian" \
		"rust-src=$old_debian" "rust-all=$old_debian" 2>&1)
	if [[ $simulation != *'Conf rustc ('* || $simulation != *"$old_debian"* ]]; then
		printf 'APT could not resolve the complete old package set:\n%s\n' "$simulation" >&2
		return 1
	fi
}

test_history_bootstrap() (
	local directory="$WORK_DIR/history-bootstrap" probe_status transport=0
	local catalog="$directory/catalog.json" marker="$directory/archive/dists/jammy/InRelease"
	mkdir --parents "$directory"
	printf '{}\n' >"$catalog"
	verify_history_catalog "$catalog" "$directory/archive/releases.json" "$directory/unused-keyring"

	mkdir --parents "${marker%/*}"
	printf 'existing signed metadata\n' >"$marker"
	fetch_published_metadata "$directory/archive/releases.json" "$catalog"
	expect_failure 'missing local catalog cannot erase existing history' \
		verify_history_catalog "$catalog" "$directory/archive/releases.json" "$directory/unused-keyring"

	# The manifest can return 404 independently of the signed archive. Only
	# a 404 for InRelease permits bootstrap; errors are not evidence of absence.
	curl() {
		local output='' url=${!#}
		while (($# > 0)); do
			case $1 in
			--output)
				output=$2
				shift 2
				;;
			*) shift ;;
			esac
		done
		case $url in
		https://fixtures.invalid/releases.json)
			printf 'missing\n' >"$output"
			printf '404'
			;;
		https://fixtures.invalid/dists/jammy/InRelease)
			printf '%s' "$probe_status"
			return "$transport"
			;;
		*) return 22 ;;
		esac
	}
	fetch_published_metadata https://fixtures.invalid/releases.json "$catalog"
	probe_status=404
	verify_history_catalog "$catalog" https://fixtures.invalid/releases.json "$directory/unused-keyring"
	for probe_status in 200 403 500 000; do
		expect_failure "HTTP $probe_status must not permit bootstrap" verify_history_catalog \
			"$catalog" https://fixtures.invalid/releases.json "$directory/unused-keyring"
	done
	probe_status=404
	transport=28
	expect_failure 'transport failure must not permit bootstrap' verify_history_catalog \
		"$catalog" https://fixtures.invalid/releases.json "$directory/unused-keyring"
)

test_retained_archive_failures() {
	local directory="$WORK_DIR/retention-failures"
	local private="$directory/private.asc"
	local empty_json="$directory/empty.json"
	local missing_json="$directory/missing.json"
	local corrupt_json="$directory/corrupt.json"
	local old_metadata="$directory/old-metadata.json"
	local new_metadata="$directory/new-metadata.json"
	local old_stage="$directory/old-stage"
	local collision_stage="$directory/collision-stage"
	local missing_stage="$directory/missing-stage"
	local corrupt_stage="$directory/corrupt-stage"
	local missing_package_stage="$directory/missing-package-stage"
	local corrupt_package_stage="$directory/corrupt-package-stage"
	local oversized_stage="$directory/oversized-stage"
	local missing_previous="$directory/missing-previous"
	local corrupt_previous="$directory/corrupt-previous"
	local tampered_previous="$directory/tampered-previous"
	local tampered_json="$directory/tampered.json"
	local tampered_stage="$directory/tampered-stage"
	local old_packages new_packages collision_packages
	local old_hash old_filename old_hash_new old_size_new new_rustc
	local cache="$directory/cache"
	mkdir --parents "$directory" "$cache"
	printf '%s\n' '{}' >"$empty_json"
	make_test_key "$directory/gnupg" "$private"

	build_toy_packages 'retention-failure-old' '111' '1.91.1' '1'
	old_packages=$TOY_PACKAGES
	retention__metadata "$TOY_RELEASE" "$old_metadata" '1.91.1' '1'
	build_retained_archive "$old_packages" "$old_stage" "$old_metadata" "$private" \
		'1000000000' "$empty_json" '' "$cache"
	old_hash=$(sha256sum -- "$old_stage/releases.json" | awk '{print $1}')

	expect_failure 'missing previous manifest' build_retained_archive "$old_packages" \
		"$missing_stage" "$old_metadata" "$private" '1000000000' "$missing_json" \
		"$missing_json" "$cache"
	if [[ -e "$missing_stage/releases.json" ]]; then
		printf '%s\n' 'missing previous manifest left a partial output' >&2
		return 1
	fi
	assert_eq "$old_hash" "$(sha256sum -- "$old_stage/releases.json" | awk '{print $1}')" \
		'missing previous manifest preserves the published archive'

	printf '%s\n' 'not-json' >"$corrupt_json"
	expect_failure 'corrupt previous manifest' build_retained_archive "$old_packages" \
		"$corrupt_stage" "$old_metadata" "$private" '1000000000' "$corrupt_json" \
		"$corrupt_json" "$cache"
	if [[ -e "$corrupt_stage/releases.json" ]]; then
		printf '%s\n' 'corrupt previous manifest left a partial output' >&2
		return 1
	fi
	assert_eq "$old_hash" "$(sha256sum -- "$old_stage/releases.json" | awk '{print $1}')" \
		'corrupt previous manifest preserves the published archive'

	build_toy_packages 'retention-failure-new' '112' '1.92.0' '1'
	new_packages=$TOY_PACKAGES
	retention__metadata "$TOY_RELEASE" "$new_metadata" '1.92.0' '1'

	old_filename=$(jq --raw-output '.packages[0].filename' "$old_stage/releases.json")
	cp --archive "$old_stage" "$missing_previous"
	rm --force -- "$missing_previous/$old_filename"
	expect_failure 'missing previous package' build_retained_archive "$new_packages" \
		"$missing_package_stage" "$new_metadata" "$private" '1000000000' \
		"$missing_previous/releases.json" "$missing_previous/releases.json" "$cache"
	if [[ -e "$missing_package_stage/releases.json" ]]; then
		printf '%s\n' 'missing previous package left a partial output' >&2
		return 1
	fi
	assert_eq "$old_hash" "$(sha256sum -- "$old_stage/releases.json" | awk '{print $1}')" \
		'missing previous package preserves the published archive'

	cp --archive "$old_stage" "$corrupt_previous"
	printf '%s\n' 'corrupted historical package bytes' >>"$corrupt_previous/$old_filename"
	expect_failure 'corrupt previous package' build_retained_archive "$new_packages" \
		"$corrupt_package_stage" "$new_metadata" "$private" '1000000000' \
		"$corrupt_previous/releases.json" "$corrupt_previous/releases.json" "$cache"
	if [[ -e "$corrupt_package_stage/releases.json" ]]; then
		printf '%s\n' 'corrupt previous package left a partial output' >&2
		return 1
	fi
	assert_eq "$old_hash" "$(sha256sum -- "$old_stage/releases.json" | awk '{print $1}')" \
		'corrupt previous package preserves the published archive'

	# Updating an unsigned catalog with a valid replacement .deb does not
	# bypass the signed InRelease -> Packages -> catalog chain.
	old_filename=$(jq --raw-output '.packages[] | select(.package == "rustc") | .filename' \
		"$old_stage/releases.json")
	new_rustc="$new_packages/rustc_1.92.0-1_amd64.deb"
	old_hash_new=$(sha256sum -- "$new_rustc" | awk '{print $1}')
	old_size_new=$(stat --format='%s' "$new_rustc")
	cp --archive "$old_stage" "$tampered_previous"
	cp -- "$new_rustc" "$tampered_previous/$old_filename"
	jq --arg old "$old_filename" --arg hash "$old_hash_new" --argjson size "$old_size_new" '
        (.releases[0].packages[] | select(.filename == $old) | .sha256) = $hash |
        (.releases[0].packages[] | select(.filename == $old) | .size) = $size |
        (.packages[] | select(.filename == $old) | .sha256) = $hash |
        (.packages[] | select(.filename == $old) | .size) = $size
    ' "$tampered_previous/releases.json" >"$tampered_json"
	expect_failure 'unsigned catalog replacement fails signed index chain' build_retained_archive "$new_packages" \
		"$tampered_stage" "$new_metadata" "$private" '1000000000' \
		"$tampered_json" "$tampered_previous/releases.json" "$cache"
	if [[ -e "$tampered_stage/releases.json" ]]; then
		printf '%s\n' 'unsigned catalog replacement left a partial output' >&2
		return 1
	fi
	assert_eq "$old_hash" "$(sha256sum -- "$old_stage/releases.json" | awk '{print $1}')" \
		'unsigned catalog replacement preserves the published archive'

	expect_failure 'oversized newest release' build_retained_archive "$new_packages" \
		"$oversized_stage" "$new_metadata" "$private" '1' "$empty_json" '' "$cache"
	if [[ -e "$oversized_stage/releases.json" ]]; then
		printf '%s\n' 'oversized newest release left a partial output' >&2
		return 1
	fi
	assert_eq "$old_hash" "$(sha256sum -- "$old_stage/releases.json" | awk '{print $1}')" \
		'oversized newest release preserves the published archive'

	build_toy_packages 'retention-failure-collision' '113' '1.91.1' '1'
	collision_packages=$TOY_PACKAGES
	retention__metadata "$TOY_RELEASE" "$new_metadata" '1.91.1' '1'
	printf '%s\n' 'same-version byte collision' >>"$collision_packages/rustc_1.91.1-1_amd64.deb"
	expect_failure 'same-version package byte collision' build_retained_archive "$collision_packages" \
		"$collision_stage" "$new_metadata" "$private" '1000000000' \
		"$old_stage/releases.json" "$old_stage/releases.json" "$cache"
	if [[ -e "$collision_stage/releases.json" ]]; then
		printf '%s\n' 'same-version collision left a partial output' >&2
		return 1
	fi
	assert_eq "$old_hash" "$(sha256sum -- "$old_stage/releases.json" | awk '{print $1}')" \
		'same-version collision preserves the published archive'

	expect_failure 'empty catalog cannot bypass same-version checks with a cold cache' \
		build_retained_archive "$collision_packages" "$directory/empty-catalog-stage" \
		"$new_metadata" "$private" '1000000000' "$empty_json" \
		"$old_stage/releases.json" "$directory/cold-cache"
	if [[ -e "$directory/empty-catalog-stage" ]]; then
		printf '%s\n' 'empty catalog left a partial output' >&2
		return 1
	fi
	assert_eq "$old_hash" "$(sha256sum -- "$old_stage/releases.json" | awk '{print $1}')" \
		'empty catalog preserves the published archive'
}
