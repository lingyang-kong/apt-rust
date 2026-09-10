#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

die() {
	printf 'jammy-smoke: %s\n' "$*" >&2
	exit 1
}

progress() {
	printf '\n== %s ==\n' "$*"
}

mode=release
if [[ ${1:-} == '--mode' ]]; then
	if (($# < 2)); then
		die "usage: $0 [--mode release|full] ARCHIVE [PREVIOUS]"
	fi
	mode=$2
	shift 2
fi
if [[ $mode != release && $mode != full ]]; then
	die "unknown smoke mode: $mode"
fi
if (($# < 1 || $# > 2)); then
	die "usage: $0 [--mode release|full] ARCHIVE [PREVIOUS]"
fi
repo=$1
previous=${2:-}
if [[ $mode == release && -n $previous ]]; then
	die 'release mode does not accept a previous archive'
fi
if [[ ${JAMMY_SMOKE_ALLOW_SYSTEM_CHANGES:-} != 1 ]]; then
	die 'set JAMMY_SMOKE_ALLOW_SYSTEM_CHANGES=1 when invoking this system-mutating test'
fi
if ((EUID != 0)); then
	die 'Jammy smoke test must run as root'
fi
if ! repo=$(realpath -- "$repo"); then
	die "cannot resolve archive path: $repo"
fi
if [[ ! -d $repo ]]; then
	die "archive directory does not exist: $repo"
fi
if [[ ! -f "$repo/releases.json" ]]; then
	die "archive has no releases.json: $repo"
fi
if [[ -n $previous ]]; then
	if ! previous=$(realpath -- "$previous"); then
		die "cannot resolve previous archive path: $previous"
	fi
	if [[ ! -d $previous ]]; then
		die "previous archive directory does not exist: $previous"
	fi
	if [[ ! -f "$previous/releases.json" ]]; then
		die "previous archive has no releases.json: $previous"
	fi
fi

if [[ "$(dpkg --print-architecture)" != amd64 ]]; then
	die 'Jammy smoke test requires amd64'
fi
# shellcheck disable=SC1091
. /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 22.04 ]]; then
	die 'must run on Ubuntu 22.04 (Jammy)'
fi

work=$(mktemp -d /tmp/rust-apt-smoke.XXXXXX)

# The native wrapper clears the environment, but keep the smoke test safe when
# called directly as well. These variables can select a rustup compiler,
# wrapper, target directory, or inherited compiler flags.
unset CARGO_BUILD_RUSTC CARGO_BUILD_RUSTC_WRAPPER CARGO_ENCODED_RUSTFLAGS \
	CARGO_HOME CARGO_NET_OFFLINE CARGO_TARGET_DIR RUSTC RUSTC_WRAPPER \
	RUSTDOC RUSTDOCFLAGS RUSTFLAGS RUSTUP_DIST_SERVER RUSTUP_HOME \
	RUSTUP_TOOLCHAIN RUSTUP_UPDATE_ROOT
export CARGO_HOME="$work/cargo-home"
mkdir --mode=0700 -- "$CARGO_HOME"

keyring=/usr/share/keyrings/rust-archive-keyring.gpg
source_file=/etc/apt/sources.list.d/rust-archive.sources
source_backup="$work/rust-archive.sources.original"
keyring_backup="$work/rust-archive-keyring.original"
had_source=false
had_keyring=false
if [[ -e $source_file || -L $source_file ]]; then
	cp --archive -- "$source_file" "$source_backup"
	had_source=true
	rm --force -- "$source_file"
fi
if [[ -e $keyring || -L $keyring ]]; then
	cp --archive -- "$keyring" "$keyring_backup"
	had_keyring=true
fi
cleanup() {
	local status=$?
	rm --force -- "$source_file"
	if [[ $had_source == true ]]; then
		mv --force -- "$source_backup" "$source_file"
	fi
	rm --force -- "$keyring"
	if [[ $had_keyring == true ]]; then
		mv --force -- "$keyring_backup" "$keyring"
	fi
	rm --recursive --force -- "$work"
	exit "$status"
}
trap cleanup EXIT

apt_options=(-o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-unsafe-io)

apt_update() {
	apt "${apt_options[@]}" \
		-o "Dir::Etc::sourcelist=$source_file" \
		-o 'Dir::Etc::sourceparts=-' \
		-o 'APT::Get::List-Cleanup=false' update
}

apt_install() {
	apt "${apt_options[@]}" install --assume-yes --no-install-recommends "$@"
}

apt_upgrade() {
	apt_install --no-remove "$@"
}

write_source() {
	local path=$1
	local uri=$2
	printf '%s\n' \
		'Types: deb' \
		"URIs: $uri" \
		'Suites: jammy' \
		'Components: main' \
		'Architectures: amd64' \
		"Signed-By: $keyring" >"$path"
}

if ! install -D -m 0644 -- "$repo/rust-archive-keyring.gpg" "$keyring"; then
	die 'cannot install archive keyring'
fi

metadata_rows() {
	local manifest=$1
	local output=$2
	local base name digest size package real actual
	base=$(cd -- "$(dirname -- "$manifest")" && pwd -P)
	: >"$output"
	while IFS=$'\t' read -r name digest size version; do
		if [[ -z $name || -z $digest || -z $version ]]; then
			die "manifest package entry is incomplete"
		fi
		case "$name" in
		/* | .. | ../* | */../* | */..) die "unsafe package path: $name" ;;
		esac
		package=$base/$name
		real=$(readlink -f -- "$package" 2>/dev/null || true)
		case "$real" in
		"$base"/*) ;;
		*) die "package is outside archive: $name" ;;
		esac
		if [[ ! -f $real ]]; then
			die "package is missing from archive: $name"
		fi
		if [[ -n $size && "$(stat -c '%s' -- "$real")" != "$size" ]]; then
			die "package size mismatch: $name"
		fi
		actual=$(sha256sum -- "$real" | awk '{print $1}')
		if [[ $actual != "$digest" ]]; then
			die "package checksum mismatch: $name"
		fi
		printf '%s\t%s\n' "$real" "$version" >>"$output"
	done < <(
		jq -e -r '
            . as $manifest |
            (.debian_version // empty) as $version |
            if ($version | type) != "string" or ($version | length) == 0
            then error("manifest has no debian_version") else . end |
            (if has("releases") then
                if (.releases | type) != "array" then
                    error("manifest releases is not an array")
                else
                    (.releases |
                        map(select(.version == $manifest.version and
                                   .debian_version == $manifest.debian_version))) as $current |
                    if ($current | length) != 1 then
                        error("manifest has no unique current release")
                    else
                        $current[0].packages
                    end
                end
             else .packages end) |
            if (type != "array" or length == 0)
            then error("manifest has no package entries") else . end |
            .[] |
            if (.filename | type) != "string" or (.sha256 | type) != "string"
               or (.sha256 | test("^[0-9a-f]{64}$") | not)
            then error("manifest package entry is incomplete") else . end |
            [.filename, .sha256, (if has("size") then (.size | tostring) else "" end), $version]
            | @tsv
        ' "$manifest"
	)
}

metadata_history_rows() {
	local manifest=$1
	local output=$2
	jq -r '
        . as $manifest |
        if has("releases") then
            if (.releases | type) != "array" then
                error("manifest releases is not an array")
            else
                .releases[] |
                select(.version != $manifest.version or
                       .debian_version != $manifest.debian_version) |
                (.debian_version // empty) as $version |
                if ($version | type) != "string" or ($version | length) == 0
                then error("historical release has no debian_version") else . end |
                if (.packages | type) != "array" or (.packages | length) == 0
                then error("historical release has no package entries") else . end |
                .packages[] |
                if (.filename | type) != "string" or (.sha256 | type) != "string"
                   or (.sha256 | test("^[0-9a-f]{64}$") | not)
                then error("historical package entry is incomplete") else . end |
                [.filename, .sha256, (if has("size") then (.size | tostring) else "" end), $version]
                | @tsv
            end
        else empty end
    ' "$manifest" >"$output"
}

verify_historical_files() {
	local manifest=$1
	local rows=$2
	local base name digest size version package real actual key
	local count=0
	local names=${rows%.rows}.historical-names
	base=$(cd -- "$(dirname -- "$manifest")" && pwd -P)
	if ! jq -e '
        if has("releases") then
            (.releases | type == "array") and
            all(.releases[]; (.packages | type == "array" and length == 12) and
                ([.packages[].filename] | length == (unique | length)))
        else true end
    ' "$manifest" >/dev/null; then
		die "historical release does not contain a complete package set: $manifest"
	fi
	metadata_history_rows "$manifest" "$rows"
	: >"$names"
	while IFS=$'\t' read -r name digest size version; do
		if [[ -z $name || -z $digest || -z $version ]]; then
			die "malformed historical manifest row: $manifest"
		fi
		case "$name" in
		/* | .. | ../* | */../* | */..) die "unsafe historical package path: $name" ;;
		esac
		package=$base/$name
		real=$(readlink -f -- "$package" 2>/dev/null || true)
		case "$real" in
		"$base"/*) ;;
		*) die "historical package is outside archive: $name" ;;
		esac
		if [[ ! -f $real ]]; then
			die "historical package is missing from archive: $name"
		fi
		if [[ -n $size && "$(stat -c '%s' -- "$real")" != "$size" ]]; then
			die "historical package size mismatch: $name"
		fi
		actual=$(sha256sum -- "$real" | awk '{print $1}')
		if [[ $actual != "$digest" ]]; then
			die "historical package checksum mismatch: $name"
		fi
		package=$(dpkg-deb --field "$real" Package)
		if [[ "$(dpkg-deb --field "$real" Version)" != "$version" ]]; then
			die "historical package version disagrees with releases.json: $package"
		fi
		key="$package	$version"
		if grep -Fqx "$key" "$names"; then
			die "duplicate historical package in releases.json: $package ($version)"
		fi
		printf '%s\n' "$key" >>"$names"
		count=$((count + 1))
	done <"$rows"
	if ((count > 0)); then
		printf 'Verified %d historical package checksums and exact Debian versions from %s\n' \
			"$count" "$manifest"
	fi
}

verify_archive() {
	local manifest=$1
	local rows=$2
	local checked=$3
	local names=$4
	local deb expected package architecture
	local runtime=
	local count=0
	local history_rows=${rows%.rows}.history.rows

	metadata_rows "$manifest" "$rows"
	verify_historical_files "$manifest" "$history_rows"
	if [[ ! -s $rows ]]; then
		die "manifest yielded no packages: $manifest"
	fi
	: >"$checked"
	: >"$names"
	while IFS=$'\t' read -r deb expected; do
		if [[ -z $deb || -z $expected ]]; then
			die "malformed manifest row: $manifest"
		fi
		package=$(dpkg-deb --field "$deb" Package)
		if [[ -z $package ]]; then
			die "package has no name: $deb"
		fi
		if [[ "$(dpkg-deb --field "$deb" Version)" != "$expected" ]]; then
			die "package version disagrees with releases.json: $package"
		fi
		architecture=$(dpkg-deb --field "$deb" Architecture)
		case "$architecture" in
		amd64 | all) ;;
		*) die "unexpected package architecture for $package: $architecture" ;;
		esac
		if grep -Fqx "$package" "$names"; then
			die "duplicate package in releases.json: $package"
		fi
		case "$package" in
		rustc | cargo | libstd-rust-dev | rustfmt | rust-clippy | rust-gdb | rust-lldb | rust-doc | cargo-doc | rust-src | rust-all) ;;

		libstd-rust-[0-9]*.[0-9]*)
			if [[ -n $runtime ]]; then
				die "multiple runtime packages in $manifest"
			fi
			runtime=$package
			;;
		*) die "unexpected package in archive: $package" ;;
		esac
		printf '%s\n' "$package" >>"$names"
		printf '%s\t%s\t%s\n' "$deb" "$package" "$expected" >>"$checked"
		count=$((count + 1))
	done <"$rows"

	for package in rustc cargo libstd-rust-dev rustfmt rust-clippy rust-gdb rust-lldb rust-doc cargo-doc rust-src rust-all; do
		if ! grep -Fqx "$package" "$names"; then
			die "archive is missing package: $package"
		fi
	done
	if [[ -z $runtime ]]; then
		die "archive is missing its versioned runtime package"
	fi
	if [[ $count -ne 12 ]]; then
		die "expected 12 packages, found $count in $manifest"
	fi
	printf 'Verified %d package checksums and exact Debian versions from %s\n' "$count" "$manifest"
}

file_uri() {
	local path=$1
	if ! jq --null-input --raw-output --arg path "$path" \
		'$path | split("/") | map(@uri) | join("/")'; then
		die "cannot encode archive path as a file URI: $path"
	fi
}

verify_apt_readability() {
	local archive=$1 checked=$2 history_rows=$3
	local base name digest size version deb package expected
	base=$(cd -- "$(dirname -- "$archive/releases.json")" && pwd -P)
	for name in dists/jammy/main/binary-amd64/Packages \
		dists/jammy/main/binary-amd64/Packages.gz; do
		if ! /usr/sbin/runuser --user _apt -- test -r "$archive/$name"; then
			die "APT user _apt cannot read $archive/$name; check archive directory permissions"
		fi
	done
	while IFS=$'\t' read -r deb package expected; do
		if ! /usr/sbin/runuser --user _apt -- test -r "$deb"; then
			die "APT user _apt cannot read package $deb; check archive directory permissions"
		fi
	done <"$checked"
	while IFS=$'\t' read -r name digest size version; do
		if [[ -z $name ]]; then
			continue
		fi
		if ! /usr/sbin/runuser --user _apt -- test -r "$base/$name"; then
			die "APT user _apt cannot read historical package $base/$name; check archive directory permissions"
		fi
	done <"$history_rows"
}

assert_installed() {
	local checked=$1
	local deb package expected status installed
	while IFS=$'\t' read -r deb package expected; do
		if [[ -z $package ]]; then
			continue
		fi
		if ! status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null); then
			status=
		fi
		if ! installed=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null); then
			installed=
		fi
		if [[ $status != installed || $installed != "$expected" ]]; then
			die "$package is $installed ($status), expected $expected"
		fi
	done <"$checked"
	printf 'All selected archive packages are installed at their metadata version\n'
}

verify_release_signature() {
	local archive=$1
	if [[ ! -f "$archive/dists/jammy/Release" ]]; then
		die "archive has no Release file: $archive"
	fi
	if [[ ! -f "$archive/dists/jammy/Release.gpg" ]]; then
		die "archive has no detached Release signature: $archive"
	fi
	gpgv --keyring "$keyring" \
		"$archive/dists/jammy/Release.gpg" "$archive/dists/jammy/Release"
	if [[ ! -f "$archive/dists/jammy/InRelease" ]]; then
		die "archive has no InRelease file: $archive"
	fi
	gpgv --keyring "$keyring" "$archive/dists/jammy/InRelease"
	printf 'Verified detached and inline APT signatures for %s\n' "$archive"
}

current_rows=$work/current.rows
current_checked=$work/current.checked
current_names=$work/current.names
verify_release_signature "$repo"
verify_archive "$repo/releases.json" "$current_rows" "$current_checked" "$current_names"
verify_apt_readability "$repo" "$current_checked" "${current_rows%.rows}.history.rows"
if [[ -n $previous ]]; then
	previous_rows=$work/previous.rows
	previous_checked=$work/previous.checked
	previous_names=$work/previous.names
	verify_release_signature "$previous"
	verify_archive "$previous/releases.json" "$previous_rows" "$previous_checked" "$previous_names"
	verify_apt_readability "$previous" "$previous_checked" "${previous_rows%.rows}.history.rows"
fi

install_checked=$current_checked
if [[ $mode == release ]]; then
	install_checked=$work/release.checked
	awk -F '\t' '$2 != "rust-doc" && $2 != "cargo-doc" && $2 != "rust-src"' \
		"$current_checked" >"$install_checked"
fi
mapfile -t current_all_specs < <(awk -F '\t' '{print $2 "=" $3}' "$current_checked")
mapfile -t current_specs < <(awk -F '\t' '{print $2 "=" $3}' "$install_checked")
if [[ -n $previous ]]; then
	mapfile -t previous_specs < <(awk -F '\t' '{print $2 "=" $3}' "$previous_checked")
fi

if [[ $mode == full ]]; then
	progress 'Installing compiler build and validation prerequisites'
	apt_install ca-certificates gnupg build-essential gdb pkg-config libssl-dev jq
	progress 'Installing Jammy distro Rust packages for the ownership baseline'
	apt_install rust-all rust-doc cargo-doc rust-src

	if ! old_runtime_line=$(
		dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' 2>/dev/null |
			awk -F '\t' '$1 ~ /^libstd-rust-[0-9]/ && $3 == "installed" { print $1 "\t" $2; exit }'
	); then
		old_runtime_line=
	fi
	if [[ -z $old_runtime_line ]]; then
		die 'could not find the Jammy baseline libstd-rust runtime'
	fi
	old_runtime_package=${old_runtime_line%%$'\t'*}
	old_runtime_version=${old_runtime_line#*$'\t'}
	progress "Retaining baseline runtime $old_runtime_package through the upgrade"
	keepalive=$work/runtime-keepalive
	mkdir --parents -- "$keepalive/DEBIAN"
	printf '%s\n' \
		'Package: rust-apt-runtime-keepalive' \
		'Version: 0.0.1' \
		'Architecture: all' \
		'Maintainer: Rust APT Test <test@example.invalid>' \
		"Depends: $old_runtime_package (= $old_runtime_version)" \
		'Description: Keep the Jammy Rust runtime during an upgrade test' \
		' A temporary reverse dependency used only by the integration test.' \
		>"$keepalive/DEBIAN/control"
	dpkg-deb --build --root-owner-group "$keepalive" "$work/runtime-keepalive.deb" >/dev/null
	dpkg --install "$work/runtime-keepalive.deb" >/dev/null
fi

write_source "$source_file" "file:$(file_uri "$repo")"
if [[ $mode == release ]]; then
	progress 'Updating package lists from the signed archive only'
	apt_update
	progress 'Installing the exact current archive packages and validation prerequisites'
	apt_install ca-certificates gnupg build-essential gdb pkg-config libssl-dev jq \
		"${current_specs[@]}"
elif [[ -n $previous ]]; then
	progress 'Installing the previous archive as the intermediate toolchain'
	write_source "$source_file" "file:$(file_uri "$previous")"
	apt_update
	apt_install "${previous_specs[@]}"
	assert_installed "$previous_checked"
	if [[ "$(dpkg-query -W -f='${Version}' "$old_runtime_package" 2>/dev/null)" != "$old_runtime_version" ]]; then
		die "baseline runtime $old_runtime_package was lost during intermediate installation"
	fi

	progress 'Upgrading the previous archive to the current archive packages'
	write_source "$source_file" "file:$(file_uri "$repo")"
	apt_update
	apt_upgrade "${current_all_specs[@]}"
else
	progress 'Updating package lists from the signed archive only'
	apt_update
	progress 'Upgrading the Jammy baseline archive packages through APT'
	apt_upgrade "${current_all_specs[@]}"
fi
assert_installed "$install_checked"
if [[ $mode == full ]]; then
	if [[ "$(dpkg-query -W -f='${Version}' "$old_runtime_package" 2>/dev/null)" != "$old_runtime_version" ]]; then
		die "baseline runtime $old_runtime_package was not retained through the archive upgrade"
	fi
	printf 'Baseline runtime %s remains installed through the upgrade\n' "$old_runtime_package"
fi

release_version=$(jq -er '.version' "$repo/releases.json")

if [[ $mode == full ]]; then
	progress 'Checking executable discovery, sysroot, source, and documentation links'
fi
if [[ "$(/usr/bin/rustc --print sysroot)" != /usr ]]; then
	die '/usr/bin/rustc does not report /usr as sysroot'
fi
if [[ $mode == full ]]; then
	source_target=$(readlink -f /usr/lib/rustlib/src/rust)
	if [[ $source_target != "/usr/src/rustc-$release_version" ]]; then
		die "source symlink points to $source_target, expected /usr/src/rustc-$release_version"
	fi
	if [[ ! -f /usr/lib/rustlib/src/rust/library/std/src/lib.rs ]]; then
		die 'standard-library source is missing'
	fi
	if [[ ! -L /usr/share/doc/rust/html/cargo ]]; then
		die 'Rust documentation cargo directory is not a symlink'
	fi
	if [[ "$(readlink -f /usr/share/doc/rust/html/cargo/index.html)" != /usr/share/doc/cargo/index.html ]]; then
		die 'Rust documentation cargo index does not resolve to local cargo-doc'
	fi
fi

progress 'Compiling a hello program and a local procedural macro workspace offline'
printf '%s\n' 'fn main() { println!("jammy-rust-ok"); }' >"$work/hello.rs"
/usr/bin/rustc "$work/hello.rs" -o "$work/hello"
hello_output=$("$work/hello")
if [[ $hello_output != jammy-rust-ok ]]; then
	die 'compiled hello program returned the wrong output'
fi
/usr/bin/rustc -C prefer-dynamic "$work/hello.rs" -o "$work/hello-dynamic"
if [[ "$(env --unset=LD_LIBRARY_PATH "$work/hello-dynamic")" != jammy-rust-ok ]]; then
	die 'dynamically linked Rust runtime was not resolved by the system loader'
fi

workspace=$work/workspace
cargo new --quiet --vcs none --bin "$workspace"
cargo new --quiet --vcs none --lib "$workspace/proc-macro"
printf '%s\n' \
	'[workspace]' \
	'members = ["proc-macro"]' \
	'resolver = "2"' \
	'' \
	'[package]' \
	'name = "jammy-workspace"' \
	'version = "0.1.0"' \
	'edition = "2021"' \
	'' \
	'[dependencies]' \
	'jammy-macro = { path = "proc-macro" }' \
	>"$workspace/Cargo.toml"
printf '%s\n' \
	'[package]' \
	'name = "jammy-macro"' \
	'version = "0.1.0"' \
	'edition = "2021"' \
	'' \
	'[lib]' \
	'proc-macro = true' \
	>"$workspace/proc-macro/Cargo.toml"
printf '%s\n' \
	'use proc_macro::TokenStream;' \
	'' \
	'#[proc_macro]' \
	'pub fn make_answer(_input: TokenStream) -> TokenStream {' \
	'    "fn answer() -> u32 { 42 }"' \
	'        .parse()' \
	'        .expect("generated tokens")' \
	'}' \
	>"$workspace/proc-macro/src/lib.rs"
printf '%s\n' \
	'use jammy_macro::make_answer;' \
	'' \
	'make_answer!();' \
	'' \
	'fn main() {' \
	'    assert_eq!(answer(), 42);' \
	'}' \
	'' \
	'#[cfg(test)]' \
	'mod tests {' \
	'    #[test]' \
	'    fn generated_function_works() {' \
	'        assert_eq!(super::answer(), 42);' \
	'    }' \
	'}' \
	>"$workspace/src/main.rs"
(cd "$workspace" && cargo test --offline --workspace)
(cd "$workspace" && cargo doc --offline --workspace --no-deps)
(cd "$workspace" && cargo fmt --check --all)
(cd "$workspace" && cargo clippy --offline --workspace --all-targets -- -D warnings)

progress 'Checking Cargo compiler override and explicit rustc with a rustup-like shim present'
wrapper=$work/logging-rustc
wrapper_log=$work/logging-rustc.log
printf '%s\n' \
	'#!/bin/sh' \
	"printf '%s\\n' invoked >> '$wrapper_log'" \
	'exec /usr/bin/rustc "$@"' \
	>"$wrapper"
chmod 0755 "$wrapper"
mkdir -p "$workspace/.cargo"
printf '[build]\nrustc = "%s"\n' "$wrapper" >"$workspace/.cargo/config.toml"
(cd "$workspace" && cargo check --offline --workspace)
if [[ ! -s $wrapper_log ]]; then
	die 'Cargo did not honor its configured compiler override'
fi

fake_bin=$work/fake-bin
mkdir -p "$fake_bin"
rustup_log=$work/rustup-shim.log
printf '%s\n' \
	'#!/bin/sh' \
	"printf '%s\\n' called >> '$rustup_log'" \
	'exit 97' \
	>"$fake_bin/rustup"
chmod 0755 "$fake_bin/rustup"
PATH="$fake_bin:$PATH" /usr/bin/rustc --version >"$work/rustc-version"
if [[ -e $rustup_log ]]; then
	die 'explicit /usr/bin/rustc consulted the rustup-like shim'
fi

progress 'Loading GDB and LLDB Python helpers without attaching to a process'
for helper in gdb_lookup.py gdb_load_rust_pretty_printers.py gdb_providers.py rust_types.py lldb_lookup.py lldb_providers.py; do
	if [[ ! -f "/usr/lib/rustlib/etc/$helper" ]]; then
		die "missing debugger helper: $helper"
	fi
done
/usr/bin/rust-gdb --batch \
	-ex 'python import gdb_lookup; assert gdb_lookup.__file__.startswith("/usr/lib/rustlib/etc/")' \
	-ex quit
/usr/bin/rust-lldb --batch \
	-o 'script import sys; sys.path.insert(0, "/usr/lib/rustlib/etc"); import lldb_lookup; assert lldb_lookup.__file__.startswith("/usr/lib/rustlib/etc/")' \
	-o quit

if [[ $mode == full ]]; then
	progress 'Checking that a corrupted InRelease is rejected'
	bad_repo=$work/bad-repo
	mkdir --parents -- "$bad_repo"
	cp --archive -- "$repo/dists" "$bad_repo/"
	sed -i '0,/^Origin:/s/^Origin:.*$/Origin: Deliberate-smoke-test-corruption/' \
		"$bad_repo/dists/jammy/InRelease"
	if ! grep --fixed-strings --line-regexp --quiet 'Origin: Deliberate-smoke-test-corruption' \
		<(sed --quiet '/^Origin:/p' "$bad_repo/dists/jammy/InRelease"); then
		die 'could not mutate the copied InRelease metadata'
	fi
	chmod a+rx "$work"
	chmod --recursive a+rX "$bad_repo"
	bad_source=$work/rust-archive-bad.sources
	saved_source=$work/rust-archive.sources.saved
	mv -- "$source_file" "$saved_source"
	write_source "$bad_source" "file:$(file_uri "$bad_repo")"
	bad_log=$work/bad-update.log
	if apt "${apt_options[@]}" \
		-o "Dir::Etc::sourcelist=$bad_source" -o 'Dir::Etc::sourceparts=-' \
		-o 'APT::Get::List-Cleanup=false' \
		-o APT::Update::Error-Mode=any update >"$bad_log" 2>&1; then
		mv -- "$saved_source" "$source_file"
		rm --force -- "$bad_source"
		die 'APT accepted the deliberately corrupted InRelease'
	fi
	rm --force -- "$bad_source"
	mv -- "$saved_source" "$source_file"
	if ! grep --extended-regexp --ignore-case --quiet \
		'not signed|invalid signature|clearsigned|badsig|hash sum' "$bad_log"; then
		sed --quiet '1,80p' "$bad_log" >&2
		die 'APT rejected corrupted metadata without an identifiable signature error'
	fi
	printf 'APT rejected corrupted InRelease with Error-Mode=any\n'
	apt_update

	progress 'Purging Rust packages and checking ordinary commands are gone'
	mapfile -t current_packages <"$current_names"
	apt "${apt_options[@]}" purge --assume-yes "${current_packages[@]}"
	dpkg --purge rust-apt-runtime-keepalive >/dev/null
	if ! apt-mark auto "$old_runtime_package" >/dev/null 2>&1; then
		printf 'warning: could not mark baseline runtime automatic for autoremove\n' >&2
	fi
	apt "${apt_options[@]}" autoremove --assume-yes
	hash -r
	for command in rustc rustdoc cargo rustfmt cargo-fmt clippy-driver cargo-clippy rust-gdb rust-lldb; do
		if command -v "$command" >/dev/null 2>&1; then
			die "ordinary Rust command remains after purge: $command"
		fi
	done
	printf 'Rust tool commands are absent after purge and autoremove\n'
fi

printf '\nJammy smoke test passed.\n'
