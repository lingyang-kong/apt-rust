#!/usr/bin/env bash
set -Eeuo pipefail

assert_eq() {
	local expected=$1
	local actual=$2
	local message=${3:-values differ}
	if [[ $expected != "$actual" ]]; then
		printf 'assertion failed: %s\nexpected: %s\nactual: %s\n' \
			"$message" "$expected" "$actual" >&2
		return 1
	fi
}

assert_file() {
	local path=$1
	local message=${2:-expected a regular file}
	if [[ ! -f $path ]]; then
		printf 'assertion failed: %s: %s\n' "$message" "$path" >&2
		return 1
	fi
}

assert_symlink() {
	local path=$1
	local message=${2:-expected a symbolic link}
	if [[ ! -L $path ]]; then
		printf 'assertion failed: %s: %s\n' "$message" "$path" >&2
		return 1
	fi
}

assert_public_archive() {
	local archive=$1 inaccessible
	inaccessible=$(find "$archive" \( -type d ! -perm -0005 -o -type f ! -perm -0004 \) -print -quit)
	if [[ -n $inaccessible ]]; then
		printf 'archive is not readable by an unrelated APT user: %s\n' "$inaccessible" >&2
		return 1
	fi
}

setup_apt_test_root() {
	local root=$1
	mkdir --parents "$root/lists/partial" "$root/cache/archives/partial" "$root/preferences.d"
	: >"$root/status"
	: >"$root/preferences"
	# shellcheck disable=SC2034
	APT_TEST_OPTIONS=(
		-o "Dir::State::lists=$root/lists" -o "Dir::State::status=$root/status"
		-o "Dir::Cache=$root/cache" -o 'Dir::Cache::pkgcache=' -o 'Dir::Cache::srcpkgcache='
		-o "Dir::Etc::sourcelist=$root/sources.list" -o 'Dir::Etc::sourceparts=-'
		-o "Dir::Etc::preferences=$root/preferences" -o "Dir::Etc::preferencesparts=$root/preferences.d"
		-o 'Dir::Etc::main=-' -o 'Dir::Etc::parts=-' -o "APT::Sandbox::User=$(id --user --name)"
		-o 'APT::Architecture=amd64' -o 'Acquire::Languages=none'
	)
}

expect_failure() {
	local label=$1
	shift
	local output
	if output=$("$@" 2>&1); then
		printf 'assertion failed: %s unexpectedly succeeded\n%s\n' "$label" "$output" >&2
		return 1
	fi
}

fixture_file() {
	local path=$1
	local content=$2
	local mtime=$3
	mkdir -p -- "$(dirname -- "$path")"
	printf '%s' "$content" >"$path"
	touch -d "@$mtime" -- "$path"
}

fixture_release() {
	local output=$1
	local version=${2:-1.91.1}
	local hash
	hash=$(printf '%064d' 0)
	jq -n \
		--arg version "$version" \
		--arg hash "$hash" \
		'{
            version:$version,
            date:"2025-01-01",
            manifest_url:"https://static.rust-lang.org/dist/channel-rust-stable.toml",
            manifest_sha256:$hash,
            assets:[
                {component:"rustc", url:"https://static.rust-lang.org/dist/rustc-fixture.tar.xz", sha256:$hash},
                {component:"cargo", url:"https://static.rust-lang.org/dist/cargo-fixture.tar.xz", sha256:$hash},
                {component:"rust-std", url:"https://static.rust-lang.org/dist/rust-std-fixture.tar.xz", sha256:$hash},
                {component:"rustfmt-preview", url:"https://static.rust-lang.org/dist/rustfmt-fixture.tar.xz", sha256:$hash},
                {component:"clippy-preview", url:"https://static.rust-lang.org/dist/clippy-fixture.tar.xz", sha256:$hash},
                {component:"rust-docs", url:"https://static.rust-lang.org/dist/rust-docs-fixture.tar.xz", sha256:$hash},
                {component:"rustc-src", url:"https://static.rust-lang.org/dist/rustc-1.91.1-src.tar.xz", sha256:$hash}
            ]
        }' >"$output"
}

make_toy_fixture() {
	local roots=$1
	local release=$2
	local mtime=$3
	local version=${4:-1.91.1}
	local revision=${5:-1}
	local package
	init_layout "$version" "$revision"
	mkdir -p -- "$roots"
	for package in "${PACKAGE_NAMES[@]}"; do
		mkdir -p -- "$roots/$package"
	done

	fixture_file "$roots/rustc/usr/bin/rustc" $'#!/bin/sh\nexit 0\n' "$mtime"
	fixture_file "$roots/rustc/usr/bin/rustdoc" $'#!/bin/sh\nexit 0\n' "$mtime"
	fixture_file "$roots/rustc/usr/share/doc/rustc/upstream/LICENSE-MIT" $'MIT\n' "$mtime"
	fixture_file "$roots/cargo/usr/bin/cargo" $'#!/bin/sh\nexit 0\n' "$mtime"
	fixture_file "$roots/rustfmt/usr/bin/rustfmt" $'#!/bin/sh\nexit 0\n' "$mtime"
	fixture_file "$roots/rust-clippy/usr/bin/clippy-driver" $'#!/bin/sh\nexit 0\n' "$mtime"
	fixture_file "$roots/rust-gdb/usr/bin/rust-gdb" $'#!/bin/sh\nexit 0\n' "$mtime"
	fixture_file "$roots/rust-lldb/usr/bin/rust-lldb" $'#!/bin/sh\nlldb=lldb\nexit 0\n' "$mtime"
	find "$roots" -path '*/usr/bin/*' -type f -exec chmod 0755 {} +
	fixture_file "$roots/$RUNTIME_PACKAGE/usr/lib/rustlib/$TARGET/lib/libstd.so" \
		$'synthetic shared library (intentionally non-ELF)\n' "$mtime"
	fixture_file "$roots/libstd-rust-dev/usr/lib/rustlib/$TARGET/lib/libstd.rlib" \
		$'synthetic standard library archive\n' "$mtime"
	fixture_file "$roots/rust-src/usr/src/rustc-$RUST_VERSION/library/std/src/lib.rs" \
		$'pub fn synthetic() {}\n' "$mtime"
	fixture_file "$roots/rust-src/usr/src/rustc-$RUST_VERSION/compiler/rustc/src/lib.rs" \
		$'pub fn compiler_fixture() {}\n' "$mtime"
	fixture_file "$roots/cargo-doc/usr/share/doc/cargo/index.html" \
		$'<html>cargo</html>\n' "$mtime"
	fixture_file "$roots/rust-doc/usr/share/doc/rust/html/index.html" \
		$'<html>rust</html>\n' "$mtime"
	fixture_release "$release" "$RUST_VERSION"
}

build_toy_packages() {
	local name=$1
	local mtime=$2
	local version=${3:-1.91.1}
	local revision=${4:-1}
	local base="$WORK_DIR/$name"
	local roots="$base/roots"
	local output="$base/packages"
	local release="$base/releases.json"
	mkdir -p -- "$base"
	make_toy_fixture "$roots" "$release" "$mtime" "$version" "$revision"
	build_packages "$roots" "$output" "$release"
	# These values are consumed by the test functions in test.sh.
	# shellcheck disable=SC2034
	TOY_ROOTS=$roots
	# shellcheck disable=SC2034
	TOY_PACKAGES=$output
	# shellcheck disable=SC2034
	TOY_RELEASE=$release
}

write_channel_manifest() {
	local output=$1
	local hash
	hash=$(printf '%064d' 0)
	printf '%s\n' \
		'manifest-version = "2"' \
		'date = "2025-01-01"' \
		'' \
		'[pkg.rust]' \
		'version = "1.91.1 (fixture)"' \
		'' \
		'[pkg.rustc.target.x86_64-unknown-linux-gnu]' \
		'available = true' \
		'xz_url = "https://static.rust-lang.org/dist/rustc-fixture.tar.xz"' \
		"xz_hash = \"$hash\"" \
		'' \
		'[pkg.cargo.target.x86_64-unknown-linux-gnu]' \
		'available = true' \
		'xz_url = "https://static.rust-lang.org/dist/cargo-fixture.tar.xz"' \
		"xz_hash = \"$hash\"" \
		'' \
		'[pkg.rust-std.target.x86_64-unknown-linux-gnu]' \
		'available = true' \
		'xz_url = "https://static.rust-lang.org/dist/rust-std-fixture.tar.xz"' \
		"xz_hash = \"$hash\"" \
		'' \
		'[pkg.rustfmt-preview.target.x86_64-unknown-linux-gnu]' \
		'available = true' \
		'xz_url = "https://static.rust-lang.org/dist/rustfmt-fixture.tar.xz"' \
		"xz_hash = \"$hash\"" \
		'' \
		'[pkg.clippy-preview.target.x86_64-unknown-linux-gnu]' \
		'available = true' \
		'xz_url = "https://static.rust-lang.org/dist/clippy-fixture.tar.xz"' \
		"xz_hash = \"$hash\"" \
		'' \
		'[pkg.rust-docs.target.x86_64-unknown-linux-gnu]' \
		'available = true' \
		'xz_url = "https://static.rust-lang.org/dist/rust-docs-fixture.tar.xz"' \
		"xz_hash = \"$hash\"" >"$output"
}

make_test_key() {
	local home=$1
	local private=$2
	local params="$home/params"
	mkdir -p -- "$home"
	chmod 0700 -- "$home"
	printf '%s\n' \
		'Key-Type: RSA' \
		'Key-Length: 2048' \
		'Name-Real: Shell Archive Test' \
		'Name-Email: shell-test@example.invalid' \
		'Expire-Date: 0' \
		'%no-protection' \
		'%commit' >"$params"
	gpg --batch --homedir "$home" --generate-key "$params" >/dev/null 2>&1
	gpg --batch --homedir "$home" --armor --export-secret-keys >"$private"
}

make_bad_archives() {
	local directory=$1
	local source="$directory/source"
	mkdir -p -- "$source"
	mkdir -p -- "$directory/outside-write"
	printf 'outside marker\n' >"$directory/outside-write/marker"
	printf 'payload\n' >"$source/payload"
	tar --create --xz --file "$directory/traversal.tar.xz" -C "$source" \
		--transform='s|^payload$|../traversal-write|' payload >/dev/null
	ln -s '../outside-write' "$source/escaping-link"
	tar --create --xz --file "$directory/symlink.tar.xz" -C "$source" escaping-link \
		--transform='s|^payload$|escaping-link/payload|' payload
}
