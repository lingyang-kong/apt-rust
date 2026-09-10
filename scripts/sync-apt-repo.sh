#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
shopt -s inherit_errexit
export LC_ALL=C TZ=UTC

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/upstream.sh
source "$ROOT_DIR/scripts/lib/upstream.sh"
# shellcheck source=scripts/lib/package.sh
source "$ROOT_DIR/scripts/lib/package.sh"
# shellcheck source=scripts/lib/cache.sh
source "$ROOT_DIR/scripts/lib/cache.sh"
# shellcheck source=scripts/lib/archive.sh
source "$ROOT_DIR/scripts/lib/archive.sh"
# shellcheck source=scripts/lib/history-auth.sh
source "$ROOT_DIR/scripts/lib/history-auth.sh"
# shellcheck source=scripts/lib/retention.sh
source "$ROOT_DIR/scripts/lib/retention.sh"

poll=false
previous_location=${PUBLISHED_MANIFEST_URL:-}
case $# in
0) ;;
1)
	if [[ $1 == --help ]]; then
		printf 'usage: %s [--check-newest-release MANIFEST_URL]\n' "${0##*/}"
		exit
	fi
	die 'expected --check-newest-release MANIFEST_URL'
	;;
2)
	if [[ $1 != --check-newest-release ]]; then
		die 'expected --check-newest-release MANIFEST_URL'
	fi
	poll=true
	previous_location=$2
	;;
*) die 'expected --check-newest-release MANIFEST_URL' ;;
esac

require_command jq curl gpg gpgv sha256sum dpkg flock awk date
DEB_MAINTAINER=${DEB_MAINTAINER:-Unofficial Rust APT <noreply@example.invalid>}
OUT_DIR=$(realpath --canonicalize-missing --no-symlinks -- "${OUT_DIR:-$ROOT_DIR/dist}")
if [[ $poll == false ]]; then
	check_archive_output "$OUT_DIR"
fi
CACHE_DIR=$(realpath --canonicalize-missing -- "${CACHE_DIR:-$ROOT_DIR/.build/cache}")
# actions/deploy-pages v4 defines ONE_GIGABYTE as 1073741824 bytes.
MAX_BYTES=${MAX_BYTES:-1073741824}
if [[ ! $MAX_BYTES =~ ^[1-9][0-9]*$ ]]; then
	die 'MAX_BYTES must be a positive integer'
fi
if [[ $(dpkg --print-architecture) != amd64 ]]; then
	die 'only amd64 is supported'
fi
mkdir --parents -- "$CACHE_DIR"
exec {cache_lock}>"$CACHE_DIR/.lock"
flock --exclusive "$cache_lock"
WORK_DIR=$(mktemp --directory "$CACHE_DIR/work.XXXXXX")
stage=''
cleanup() {
	rm --recursive --force -- "$WORK_DIR"
	if [[ -n $stage && -d $stage ]]; then
		rm --recursive --force -- "$stage"
	fi
}
trap cleanup EXIT
start=$SECONDS

discover_release "$WORK_DIR" "$ROOT_DIR/keys/rust-release.asc" "${RUST_CHANNEL:-stable}"
version=$(jq --raw-output '.version' "$WORK_DIR/release.json")
revision=$(revision_for_version "$version" "$ROOT_DIR/packaging/revisions.tsv")
init_layout "$version" "$revision"
recipe=$(recipe_digest "$ROOT_DIR")
publisher=$(publisher_digest "$ROOT_DIR")
jq --null-input --slurpfile release "$WORK_DIR/release.json" --arg recipe "$recipe" \
	--arg version "$DEB_VERSION" \
	'{package_recipe_format:2,release:$release[0],recipe_sha256:$recipe,debian_version:$version}' \
	>"$WORK_DIR/identity.json"
previous_location=${previous_location:-$OUT_DIR/releases.json}
case $previous_location in
https://*) ;;
*) previous_location=$(realpath --canonicalize-missing -- "$previous_location") ;;
esac
fetch_published_metadata "$previous_location" "$WORK_DIR/previous.json"
if [[ $poll == true ]]; then
	if jq --exit-status --slurpfile current "$WORK_DIR/identity.json" --arg publisher "$publisher" \
		'.identity == $current[0] and .publisher_sha256 == $publisher' \
		"$WORK_DIR/previous.json" >/dev/null; then
		printf 'false\n'
	else
		printf 'true\n'
	fi
	exit
fi
require_command apt-ftparchive dpkg-deb dpkg-shlibdeps readelf patchelf tar gzip find stat gpgconf
if ! grep --fixed-strings --line-regexp --quiet 'VERSION_ID="22.04"' /etc/os-release; then
	die 'build on Ubuntu 22.04 to derive Jammy system dependencies'
fi
if [[ -z ${APT_GPG_PRIVATE_KEY:-} ]]; then
	die 'APT_GPG_PRIVATE_KEY is required; see docs/maintaining.md for local test keys'
fi
printf '%s\n' "$APT_GPG_PRIVATE_KEY" >"$WORK_DIR/archive-private.asc"
chmod 600 "$WORK_DIR/archive-private.asc"
downloads="$CACHE_DIR/downloads"
package_cache="$CACHE_DIR/packages/$DEB_VERSION"
mkdir --parents -- "$downloads"
fetch_source "$RUST_VERSION" "$downloads" "$ROOT_DIR/keys/rust-release.asc" "$WORK_DIR/source.json"
jq --arg dpkg "$(dpkg-deb --version | sed -n '1p')" --arg patchelf "$(patchelf --version)" \
	--slurpfile source "$WORK_DIR/source.json" \
	'. + {source:$source[0],build_tools:{"dpkg-deb":$dpkg,patchelf:$patchelf}}' \
	"$WORK_DIR/identity.json" >"$WORK_DIR/cache-identity.json"
check_package_cache "$package_cache" "$WORK_DIR/cache-identity.json"
jq --slurpfile source "$WORK_DIR/source.json" '.assets += $source | .source=$source[0]' \
	"$WORK_DIR/release.json" >"$WORK_DIR/complete-release.json"
build_work_bytes=0
if [[ $PACKAGE_CACHE_HIT == false ]]; then
	while IFS=$'\t' read -r component url digest; do
		printf 'Packaging %s...\n' "$component" >&2
		asset="$downloads/$digest.tar.xz"
		fetch_asset "$url" "$digest" "$asset"
		stage_component "$component" "$asset" "$WORK_DIR/roots"
	done < <(jq --raw-output '.assets[] | [.component,.url,.sha256] | @tsv' "$WORK_DIR/release.json")
	printf 'Packaging full compiler sources...\n' >&2
	stage_component rustc-src "$downloads/rustc-$RUST_VERSION-src.tar.xz" "$WORK_DIR/roots"
	build_packages "$WORK_DIR/roots" "$WORK_DIR/packages" "$WORK_DIR/complete-release.json"
	build_work_bytes=$(tree_bytes "$WORK_DIR")
	record_package_cache "$WORK_DIR/packages" "$package_cache" "$WORK_DIR/cache-identity.json" \
		"$WORK_DIR/inventory.ndjson"
fi
validate_packages "$package_cache"
jq --slurpfile identity "$WORK_DIR/identity.json" --slurpfile cache "$WORK_DIR/cache-identity.json" \
	--arg publisher "$publisher" \
	'. + {identity:$identity[0],debian_version:$identity[0].debian_version,
          recipe_sha256:$identity[0].recipe_sha256,build_tools:$cache[0].build_tools,
          publisher_sha256:$publisher,suite:"jammy",architecture:"amd64"}' \
	"$WORK_DIR/complete-release.json" >"$WORK_DIR/metadata.json"
mkdir --parents -- "${OUT_DIR%/*}"
stage=$(mktemp --directory "${OUT_DIR%/*}/.rust-archive-XXXXXX")
jq --null-input --argjson elapsed "$((SECONDS - start))" --argjson hit "$PACKAGE_CACHE_HIT" \
	--argjson cache "$(($(tree_bytes "$downloads") + $(tree_bytes "$package_cache")))" \
	--argjson work "$build_work_bytes" \
	'{elapsed_seconds:$elapsed,package_cache_hit:$hit,cache_bytes:$cache,build_work_bytes:$work}' \
	>"$stage/measurements.json"
build_retained_archive "$package_cache" "$stage" "$WORK_DIR/metadata.json" \
	"$WORK_DIR/archive-private.asc" "$MAX_BYTES" "$WORK_DIR/previous.json" "$previous_location" "$CACHE_DIR"
check_identities "$WORK_DIR/previous.json" "$stage/releases.json"
activate_archive "$stage" "$OUT_DIR"
stage=''
prune_cache "$CACHE_DIR" "$package_cache" "$WORK_DIR/complete-release.json" \
	"$WORK_DIR/keep-downloads" "$OUT_DIR/releases.json"
printf 'Published archive candidate: %s packages, %s releases in %s (%s bytes)\n' \
	"$(jq '.packages | length' "$OUT_DIR/releases.json")" \
	"$(jq '.releases | length' "$OUT_DIR/releases.json")" "$OUT_DIR" "$(tree_bytes "$OUT_DIR/")"
