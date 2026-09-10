#!/usr/bin/env bash

test_package_and_publisher_fingerprints() (
	set -o errexit -o nounset -o pipefail
	local fixture_root="$WORK_DIR/fingerprints"
	mkdir --parents "$fixture_root/scripts/lib" "$fixture_root/keys" "$fixture_root/.github/workflows" \
		"$fixture_root/tests" "$fixture_root/packaging"
	local file recipe publisher
	for file in scripts/lib/common.sh scripts/lib/package.sh scripts/lib/cache.sh \
		scripts/lib/upstream.sh scripts/lib/archive.sh scripts/lib/retention.sh scripts/lib/history-auth.sh \
		scripts/sync-apt-repo.sh scripts/poll-release.sh keys/rust-release.asc \
		packaging/rust.pref scripts/lib/activation.sh \
		.github/workflows/publish.yml tests/test-jammy.sh tests/jammy-smoke.sh; do
		printf 'fixture %s\n' "$file" >"$fixture_root/$file"
	done
	recipe=$(recipe_digest "$fixture_root")
	publisher=$(publisher_digest "$fixture_root")
	for file in scripts/poll-release.sh scripts/lib/archive.sh scripts/lib/retention.sh \
		packaging/rust.pref scripts/lib/activation.sh \
		scripts/lib/cache.sh scripts/sync-apt-repo.sh .github/workflows/publish.yml \
		tests/test-jammy.sh tests/jammy-smoke.sh; do
		printf 'publishing change\n' >>"$fixture_root/$file"
		assert_eq "$recipe" "$(recipe_digest "$fixture_root")" "$file does not affect package identity"
		if [[ $(publisher_digest "$fixture_root") == "$publisher" ]]; then
			printf 'publisher fingerprint ignored %s\n' "$file" >&2
			return 1
		fi
		publisher=$(publisher_digest "$fixture_root")
	done
	printf 'package construction change\n' >>"$fixture_root/scripts/lib/package.sh"
	if [[ $(recipe_digest "$fixture_root") == "$recipe" ]]; then
		printf 'package construction change did not affect package identity\n' >&2
		return 1
	fi
	recipe=$(recipe_digest "$fixture_root")
	export DEB_MAINTAINER='Different Maintainer <different@example.invalid>'
	if [[ $(recipe_digest "$fixture_root") == "$recipe" ]]; then
		printf 'maintainer change did not affect package identity\n' >&2
		return 1
	fi
)

test_retained_cache_pruning() {
	local directory="$WORK_DIR/retained-cache" version file
	mkdir --parents "$directory/downloads" "$directory/history"
	for version in 1.90.0-1 1.91.1-1 1.92.0-1; do
		mkdir --parents "$directory/packages/$version"
	done
	for file in retained.deb current.deb expired.deb; do
		printf 'fixture\n' >"$directory/history/$file"
	done
	for file in current.tar.xz expired.tar.xz rustc-1.92.0-src.tar.xz rustc-1.92.0-src.tar.xz.asc; do
		printf 'fixture\n' >"$directory/downloads/$file"
	done
	printf '{"assets":[{"component":"rustc","sha256":"current"}]}\n' >"$directory/release.json"
	printf '{"releases":[{"debian_version":"1.92.0-1"},{"debian_version":"1.91.1-1"}],"packages":[{"sha256":"current"},{"sha256":"retained"}]}\n' \
		>"$directory/catalog.json"
	init_layout 1.92.0 1
	prune_cache "$directory" "$directory/packages/1.92.0-1" "$directory/release.json" \
		"$directory/keep" "$directory/catalog.json"
	if [[ ! -d $directory/packages/1.92.0-1 || ! -d $directory/packages/1.91.1-1 ||
		-d $directory/packages/1.90.0-1 || -f $directory/history/expired.deb ||
		-f $directory/downloads/expired.tar.xz ]]; then
		printf 'cache pruning did not preserve exactly the retained releases\n' >&2
		return 1
	fi
	assert_file "$directory/history/retained.deb" 'retained historical blob'
	assert_file "$directory/history/current.deb" 'current blob'
	assert_file "$directory/downloads/current.tar.xz" 'current component download'
	assert_file "$directory/downloads/rustc-1.92.0-src.tar.xz" 'current full sources'
}
