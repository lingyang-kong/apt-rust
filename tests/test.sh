#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK_DIR=$(mktemp -d /tmp/rust-apt-shell-tests.XXXXXX)
export ROOT_DIR WORK_DIR
export DEB_MAINTAINER='Shell Test <test@example.invalid>'
export TARGET='x86_64-unknown-linux-gnu'
export MULTIARCH='x86_64-linux-gnu'
trap 'rm -rf -- "$WORK_DIR"' EXIT

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/package.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/upstream.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/cache.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/archive.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/history-auth.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/retention.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/test_helpers.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/test-retention.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/test-fingerprints.sh"
# shellcheck source=tests/test-apt-policy.sh
source "$ROOT_DIR/tests/test-apt-policy.sh"
# shellcheck source=tests/test-discovery.sh
source "$ROOT_DIR/tests/test-discovery.sh"
# shellcheck source=tests/test-activation.sh
source "$ROOT_DIR/tests/test-activation.sh"

test_layout_and_versioning() {
	local expected_names expected_depends
	init_layout '1.91.1'
	assert_eq '1.91.1' "$RUST_VERSION" 'Rust version'
	assert_eq '1.91' "$RUST_MINOR" 'Rust minor version'
	assert_eq '1.91.1-1' "$DEB_VERSION" 'Debian version'
	assert_eq 'libstd-rust-1.91' "$RUNTIME_PACKAGE" 'runtime package'
	if [[ $DEB_VERSION == *'+'* || $DEB_VERSION == *'~'* ]]; then
		printf 'version contains an upstream or distribution suffix: %s\n' "$DEB_VERSION" >&2
		return 1
	fi
	expected_names='rustc cargo libstd-rust-1.91 libstd-rust-dev rustfmt rust-clippy rust-gdb rust-lldb rust-doc cargo-doc rust-src rust-all'
	assert_eq "$expected_names" "${PACKAGE_NAMES[*]}" 'complete package order'
	expected_depends="libstd-rust-dev (= $DEB_VERSION), $RUNTIME_PACKAGE (= $DEB_VERSION), gcc, libc6-dev, binutils"
	assert_eq "$expected_depends" "$(package_dependencies rustc)" 'rustc dependencies'
	assert_eq "rustc (= $DEB_VERSION), gcc | clang | c-compiler, binutils" \
		"$(package_dependencies cargo)" 'Cargo dependencies'
	assert_eq 'amd64' "$(package_architecture rustc)" 'compiler architecture'
	assert_eq 'all' "$(package_architecture rust-src)" 'source architecture'
	init_layout '1.91.1' '2'
	assert_eq '1.91.1-2' "$DEB_VERSION" 'packaging revision increment'
	init_layout '1.92.0'
	assert_eq '1.92.0-1' "$DEB_VERSION" 'new upstream resets revision'
	expect_failure 'short Rust version' init_layout '1.91'
	expect_failure 'non-numeric revision' init_layout '1.91.1' '1x'
	expect_failure 'zero revision' init_layout '1.91.1' '0'
	expect_failure 'leading-zero revision' init_layout '1.91.1' '01'
}

test_debian_version_ordering() {
	dpkg --compare-versions '1.91.1-2' gt '1.91.1-1'
	dpkg --compare-versions '1.92.0-1' gt '1.91.1-2'
	# Ubuntu's same-upstream +dfsg candidate is newer by ordinary APT rules.
	# A repository pin (for example, origin priority 600) is the policy choice
	# to override that candidate when a same-upstream replacement is desired.
	dpkg --compare-versions '1.91.1+dfsg' gt '1.91.1-1'
}

test_package_build_and_reproducibility() {
	local first_packages second_packages package deb architecture depends expected
	local first_names second_names
	build_toy_packages 'first' '1'
	first_packages=$TOY_PACKAGES
	validate_packages "$first_packages"
	mapfile -t first_names < <(find "$first_packages" -maxdepth 1 -type f -name '*.deb' -printf '%f\n' | sort)
	assert_eq '12' "${#first_names[@]}" 'twelve package artifacts'
	if [[ ! -x $TOY_ROOTS/rust-lldb/usr/bin/rust-lldb ]]; then
		printf 'patched rust-lldb launcher lost its executable mode\n' >&2
		return 1
	fi
	for package in "${PACKAGE_NAMES[@]}"; do
		deb=$(find "$first_packages" -maxdepth 1 -type f -name "${package}_${DEB_VERSION}_*.deb" -print)
		assert_file "$deb" "package artifact for $package"
		architecture=$(dpkg-deb --field "$deb" Architecture)
		assert_eq "$(package_architecture "$package")" "$architecture" "$package architecture"
		assert_eq "$DEB_VERSION" "$(dpkg-deb --field "$deb" Version)" "$package version"
		if depends=$(dpkg-deb --field "$deb" Depends); then
			expected=$(package_dependencies "$package")
			assert_eq "$expected" "$depends" "$package dependencies"
		else
			expected=$(package_dependencies "$package")
			if [[ -n $expected ]]; then
				printf 'missing dependencies for %s: %s\n' "$package" "$expected" >&2
				return 1
			fi
		fi
	done
	assert_symlink "$TOY_ROOTS/rust-src/usr/lib/rustlib/src/rust" 'source link'
	assert_eq "$TOY_ROOTS/rust-src/usr/src/rustc-$RUST_VERSION" \
		"$(readlink -f -- "$TOY_ROOTS/rust-src/usr/lib/rustlib/src/rust")" 'source link target'
	assert_file "$TOY_ROOTS/rust-src/usr/lib/rustlib/src/rust/library/std/src/lib.rs" \
		'standard-library source payload'
	assert_file "$TOY_ROOTS/rust-src/usr/lib/rustlib/src/rust/compiler/rustc/src/lib.rs" \
		'compiler source payload'
	assert_symlink "$TOY_ROOTS/$RUNTIME_PACKAGE/usr/lib/rustlib/$TARGET/lib/libstd.so" \
		'target runtime link'
	assert_file "$TOY_ROOTS/$RUNTIME_PACKAGE/usr/lib/$MULTIARCH/libstd.so" \
		'multiarch runtime library'

	build_toy_packages 'second' '2000000000'
	second_packages=$TOY_PACKAGES
	mapfile -t second_names < <(find "$second_packages" -maxdepth 1 -type f -name '*.deb' -printf '%f\n' | sort)
	assert_eq "${first_names[*]}" "${second_names[*]}" 'artifact names across input mtimes'
	for package in "${first_names[@]}"; do
		assert_eq "$(sha256sum -- "$first_packages/$package" | awk '{print $1}')" \
			"$(sha256sum -- "$second_packages/$package" | awk '{print $1}')" \
			"reproducible bytes for $package"
	done

	deb=$(find "$first_packages" -maxdepth 1 -type f -name 'rustc_*.deb' -print)
	mv -- "$deb" "$deb.saved"
	expect_failure 'incomplete package set' validate_packages "$first_packages"
	mv -- "$deb.saved" "$deb"
	validate_packages "$first_packages"

	local overlap_base="$WORK_DIR/overlap"
	local overlap_roots="$overlap_base/roots"
	local overlap_packages="$overlap_base/packages"
	local overlap_release="$overlap_base/releases.json"
	mkdir -p -- "$overlap_base"
	make_toy_fixture "$overlap_roots" "$overlap_release" '7'
	fixture_file "$overlap_roots/cargo/usr/bin/rustc" $'#!/bin/sh\nexit 0\n' '7'
	build_packages "$overlap_roots" "$overlap_packages" "$overlap_release"
	expect_failure 'duplicate filesystem ownership' validate_packages "$overlap_packages"
}

test_manifest_and_cached_asset() {
	local directory="$WORK_DIR/manifest"
	local manifest="$directory/channel.toml"
	local parsed="$directory/release.json"
	local payload="$directory/payload"
	local cached="$directory/cached.tar.xz"
	local digest
	mkdir -p -- "$directory"
	write_channel_manifest "$manifest"
	parse_manifest "$manifest" 'https://static.rust-lang.org/dist/channel-rust-stable.toml' "$parsed"
	jq -e '
        .version == "1.91.1" and
        .date == "2025-01-01" and
        (.manifest_url | startswith("https://static.rust-lang.org/")) and
        (.assets | length == 6) and
        ([.assets[].component] | index("rustc")) != null
    ' "$parsed" >/dev/null
	printf 'offline fixture asset\n' >"$payload"
	digest=$(sha256sum -- "$payload" | awk '{print $1}')
	cp -- "$payload" "$cached"
	fetch_asset 'https://static.rust-lang.org/dist/asset-fixture.tar.xz' "$digest" "$cached"
	assert_eq "$digest" "$(sha256sum -- "$cached" | awk '{print $1}')" 'cached asset checksum'
}

test_cache_identity_and_revision_registry() {
	local directory="$WORK_DIR/cache"
	local previous="$directory/previous.json"
	local current="$directory/current.json"
	local changed="$directory/changed.json"
	local lower="$directory/lower.json"
	local identity="$directory/identity.json"
	local built="$directory/built"
	local cache="$directory/package-cache"
	local inventory="$directory/inventory.ndjson"
	local revisions="$directory/revisions.tsv"
	local manifest="$directory/missing.json"
	local index
	mkdir -p -- "$directory" "$built"

	printf '%s\n' '{"debian_version":"1.91.1-1","packages":[{"filename":"x.deb","sha256":"old"}]}' >"$previous"
	printf '%s\n' '{"debian_version":"1.91.1-1","packages":[{"filename":"x.deb","sha256":"old"}]}' >"$current"
	check_identities "$previous" "$current"
	printf '%s\n' '{"debian_version":"1.91.1-1","packages":[{"filename":"x.deb","sha256":"new"}]}' >"$changed"
	expect_failure 'published bytes changed without revision' check_identities "$previous" "$changed"
	printf '%s\n' '{"debian_version":"1.91.0-1","packages":[]}' >"$lower"
	expect_failure 'published version downgrade' check_identities "$previous" "$lower"

	printf '%s\n' '{"recipe":"fixture"}' >"$identity"
	for index in $(seq -w 1 12); do
		printf 'toy package %s\n' "$index" >"$built/p${index}.deb"
	done
	record_package_cache "$built" "$cache" "$identity" "$inventory"
	check_package_cache "$cache" "$identity"
	if [[ ${PACKAGE_CACHE_HIT:-false} != true ]]; then
		printf 'complete package cache was not recognized\n' >&2
		return 1
	fi
	printf 'tampered bytes\n' >>"$cache/p01.deb"
	check_package_cache "$cache" "$identity"
	if [[ ${PACKAGE_CACHE_HIT:-true} == true ]]; then
		printf 'tampered package cache was accepted\n' >&2
		return 1
	fi
	cp -- "$built/p01.deb" "$cache/p01.deb"
	printf '%s\n' '{"recipe":"changed"}' >"$directory/changed-identity.json"
	expect_failure 'changed package recipe at existing revision' check_package_cache "$cache" \
		"$directory/changed-identity.json"

	printf '%s\n' '# upstream version<TAB>packaging revision' >"$revisions"
	assert_eq '1' "$(revision_for_version '1.91.1' "$revisions")" 'unlisted release starts at revision one'
	printf '1.91.1\t3\n' >>"$revisions"
	assert_eq '3' "$(revision_for_version '1.91.1' "$revisions")" 'registered packaging revision'
	assert_eq '1' "$(revision_for_version '1.92.0' "$revisions")" 'missing registry entry defaults to one'
	unset DEB_REVISION RUST_CHANNEL
	# revision_for_version intentionally reads these process globals.
	# shellcheck disable=SC2034
	DEB_REVISION='2'
	expect_failure 'stable revision override without matching channel' revision_for_version \
		'1.91.1' "$revisions"
	# shellcheck disable=SC2034
	RUST_CHANNEL='1.91.1'
	assert_eq '2' "$(revision_for_version '1.91.1' "$revisions")" \
		'explicit matching-channel revision override'
	unset DEB_REVISION RUST_CHANNEL
	printf 'invalid\tvalue\n' >>"$revisions"
	expect_failure 'invalid packaging registry entry' revision_for_version '1.91.1' "$revisions"

	fetch_published_metadata "$directory/does-not-exist.json" "$manifest"
	jq -e '. == {}' "$manifest" >/dev/null
}

test_upstream_signature_rejection() {
	local directory="$WORK_DIR/signature"
	local home="$directory/gnupg"
	local private="$directory/private.asc"
	local public="$directory/public.asc"
	local payload="$directory/payload"
	local signature="$directory/payload.asc"
	local fingerprint
	mkdir -p -- "$directory"
	make_test_key "$home" "$private"
	gpg --batch --homedir "$home" --armor --export >"$public"
	printf 'signed upstream fixture\n' >"$payload"
	gpg --batch --homedir "$home" --pinentry-mode loopback --passphrase '' \
		--armor --output "$signature" --detach-sign "$payload"
	fingerprint=$(gpg --batch --homedir "$home" --with-colons --list-keys |
		awk -F: '$1 == "fpr" { print $10; exit }')
	# The production key fingerprint is pinned; this isolated test key is
	# substituted only inside the child test process.
	# shellcheck disable=SC2034
	RUST_RELEASE_FINGERPRINT=$fingerprint
	verify_signature "$payload" "$signature" "$public"
	printf 'tampered upstream fixture\n' >"$payload"
	expect_failure 'tampered upstream signature' verify_signature "$payload" "$signature" "$public"
}

test_archive_safety() {
	local directory="$WORK_DIR/safety"
	local destination="$directory/destination"
	local roots="$directory/roots"
	mkdir -p -- "$destination" "$roots"
	make_bad_archives "$directory"
	expect_failure 'path traversal extraction' safe_extract "$directory/traversal.tar.xz" "$destination"
	if [[ -e "$directory/traversal-write" ]]; then
		printf 'path traversal wrote outside extraction root\n' >&2
		return 1
	fi
	expect_failure 'escaping symlink extraction' safe_extract "$directory/symlink.tar.xz" "$destination"
	if [[ -e "$directory/outside-write/payload" ]]; then
		printf 'escaping symlink wrote outside extraction root\n' >&2
		return 1
	fi
	expect_failure 'path traversal component staging' stage_component rustc \
		"$directory/traversal.tar.xz" "$roots"
	if [[ -e "$directory/traversal-write" ]]; then
		printf 'component staging wrote outside extraction root\n' >&2
		return 1
	fi
}

test_signed_archive_and_activation() {
	local directory="$WORK_DIR/archive"
	local private="$directory/private.asc"
	local metadata="$directory/metadata.json"
	local stage="$directory/stage"
	local current="$directory/current"
	local next="$directory/next"
	local unmanaged="$directory/unmanaged"
	local release_file package_count
	mkdir -p -- "$directory"
	build_toy_packages 'archive-input' '123'
	jq --arg deb "$DEB_VERSION" '. + {debian_version:$deb, suite:"jammy", architecture:"amd64"}' \
		"$TOY_RELEASE" >"$metadata"
	make_test_key "$directory/gnupg" "$private"
	build_archive "$TOY_PACKAGES" "$stage" "$metadata" "$private" '1000000000'
	assert_file "$stage/releases.json" 'archive release metadata'
	jq -e 'any(.assets[]; .component == "rustc-src")' "$stage/releases.json" >/dev/null
	assert_file "$stage/dists/jammy/InRelease" 'inline release signature'
	assert_file "$stage/dists/jammy/Release.gpg" 'detached release signature'
	gpgv --keyring "$stage/rust-archive-keyring.gpg" \
		"$stage/dists/jammy/InRelease" >/dev/null 2>&1
	package_count=$(grep -c '^Package: ' "$stage/dists/jammy/main/binary-amd64/Packages")
	assert_eq '12' "$package_count" 'package index count'

	cp -- "$stage/dists/jammy/InRelease" "$directory/InRelease.tampered"
	sed -i '0,/^Origin:/s/^Origin:.*$/Origin: Shell-test-tampering/' \
		"$directory/InRelease.tampered"
	expect_failure 'tampered signed metadata' gpgv --keyring "$stage/rust-archive-keyring.gpg" \
		"$directory/InRelease.tampered"
	expect_failure 'deployment size limit' build_archive "$TOY_PACKAGES" \
		"$directory/oversized" "$metadata" "$private" '1'

	mkdir -p -- "$current" "$next"
	printf '{"version":"old"}\n' >"$current/releases.json"
	printf '{"version":"new"}\n' >"$next/releases.json"
	migrate_archive_offline "$current"
	activate_archive "$next" "$current"
	assert_eq 'new' "$(jq -er '.version' "$current/releases.json")" 'active archive'
	if [[ -e "$current.previous" ]]; then
		printf '%s\n' 'successful archive activation left a persistent previous archive' >&2
		return 1
	fi

	mkdir -p -- "$unmanaged" "$directory/next-unmanaged"
	printf 'keep me\n' >"$unmanaged/user-file"
	printf '{"version":"replacement"}\n' >"$directory/next-unmanaged/releases.json"
	expect_failure 'unmanaged archive replacement' activate_archive \
		"$directory/next-unmanaged" "$unmanaged"
	assert_eq 'keep me' "$(<"$unmanaged/user-file")" 'unmanaged file preserved'
	release_file=$TOY_RELEASE
	assert_file "$release_file" 'fixture release metadata retained'
}

test_polling() {
	local workflow_root workflow_script poll_script
	local MANIFEST_URL='https://example.invalid/releases.json'
	workflow_root="$WORK_DIR/workflow-repo"
	mkdir --parents "$workflow_root/scripts"
	workflow_script="$workflow_root/scripts/sync-apt-repo.sh"
	cat >"$workflow_script" <<'EOF'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

if [[ $1 != --check-newest-release || $2 != "$POLL_EXPECTED_URL" ]]; then
    exit 43
fi

case ${POLL_MODE:-success} in
fail)
    exit 42
    ;;
success)
    printf '%s\n' "${POLL_RESULT:-false}"
    ;;
*)
    exit 44
    ;;
esac
EOF
	chmod 0755 "$workflow_script"
	poll_script="$workflow_root/scripts/poll-release.sh"
	cp "$ROOT_DIR/scripts/poll-release.sh" "$poll_script"
	chmod 0755 "$poll_script"

	run_poll() {
		local force_value=$1
		local poll_mode=$2
		local poll_result=$3

		: >"$WORK_DIR/workflow-output"
		PUBLISHED_MANIFEST_URL="$MANIFEST_URL" \
			FORCE_BUILD="$force_value" \
			POLL_EXPECTED_URL="$MANIFEST_URL" \
			POLL_MODE="$poll_mode" \
			POLL_RESULT="$poll_result" \
			"$poll_script" >"$WORK_DIR/workflow-output"
	}

	: >"$WORK_DIR/workflow-output"
	PUBLISHED_MANIFEST_URL='' \
		FORCE_BUILD='' \
		POLL_EXPECTED_URL='https://lingyang-kong.github.io/rust/releases.json' \
		POLL_MODE=success \
		POLL_RESULT=false \
		"$poll_script" >"$WORK_DIR/workflow-output"
	assert_eq 'false' "$(<"$WORK_DIR/workflow-output")" 'default URL and force value preserve an unchanged release'

	if run_poll true fail false; then
		printf '%s\n' 'FAIL: forced workflow poll masked API failure' >&2
		exit 1
	fi
	if [[ -s $WORK_DIR/workflow-output ]]; then
		printf '%s\n' 'FAIL: failed workflow poll wrote a changed output' >&2
		exit 1
	fi

	if ! run_poll true success false; then
		printf '%s\n' 'FAIL: forced workflow poll failed' >&2
		exit 1
	fi
	assert_eq 'true' "$(<"$WORK_DIR/workflow-output")" 'manual force input enables workflow build'

	if run_poll false success maybe; then
		printf '%s\n' 'FAIL: invalid poll result unexpectedly succeeded' >&2
		exit 1
	fi
	if [[ -s $WORK_DIR/workflow-output ]]; then
		printf '%s\n' 'FAIL: invalid poll result wrote a changed output' >&2
		exit 1
	fi
}

test_jammy_smoke_has_no_embedded_python() {
	if grep -En '\bpython3?[[:space:]]+-' "$ROOT_DIR/tests/jammy-smoke.sh"; then
		printf 'jammy smoke script still contains embedded Python execution\n' >&2
		return 1
	fi
}

test_deployment_budget_constant() {
	local configured one_gigabyte='1073741824' two_sets='1020000000'
	configured=$(sed --quiet --regexp-extended \
		's/^MAX_BYTES=\$\{MAX_BYTES:-([0-9]+)\}$/\1/p' \
		"$ROOT_DIR/scripts/sync-apt-repo.sh")
	assert_eq "$one_gigabyte" "$configured" 'deployment budget is one GiB'
	if ((two_sets >= one_gigabyte)); then
		printf '%s\n' 'two approximately 510 MB release sets exceed the one GiB budget' >&2
		return 1
	fi
}

if [[ ${1:-} == '--test' ]]; then
	if [[ $# -ne 2 ]]; then
		printf 'usage: %s --test TEST_NAME\n' "${0##*/}" >&2
		exit 2
	fi
	"$2"
	exit
fi

tests=(
	test_polling
	test_layout_and_versioning
	test_debian_version_ordering
	test_apt_candidate_selection
	test_package_build_and_reproducibility
	test_manifest_and_cached_asset
	test_canonical_discovery
	test_cache_identity_and_revision_registry
	test_upstream_signature_rejection
	test_archive_safety
	test_signed_archive_and_activation
	test_atomic_activation
	test_offline_migration
	test_retained_archive
	test_history_bootstrap
	test_retained_archive_failures
	test_package_and_publisher_fingerprints
	test_legacy_fingerprint_migration
	test_retained_cache_pruning
	test_jammy_smoke_has_no_embedded_python
	test_deployment_budget_constant
)
passed=0
failed=0
for test_name in "${tests[@]}"; do
	if "$ROOT_DIR/tests/test.sh" --test "$test_name"; then
		printf 'ok - %s\n' "$test_name"
		passed=$((passed + 1))
	else
		printf 'not ok - %s\n' "$test_name" >&2
		failed=$((failed + 1))
	fi
done
printf '\n%d passed, %d failed\n' "$passed" "$failed"
if ((failed != 0)); then
	exit 1
fi
