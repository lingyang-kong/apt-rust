#!/usr/bin/env bash

revision_for_version() {
	local version=$1 revisions=$2 revision
	revision=$(awk -v version="$version" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        NF != 2 || $1 !~ /^[0-9]+\.[0-9]+\.[0-9]+$/ || $2 !~ /^[1-9][0-9]*$/ {
            print "invalid packaging revision entry" > "/dev/stderr"; bad=1; next
        }
        seen[$1]++ { print "duplicate upstream version in revisions" > "/dev/stderr"; bad=1 }
        $1 == version { revision=$2 }
        END { if (bad) exit 1; print revision == "" ? "1" : revision }
    ' "$revisions")
	if [[ -n ${DEB_REVISION+x} ]]; then
		if [[ ${RUST_CHANNEL:-stable} != "$version" ]]; then
			die 'DEB_REVISION requires an explicit RUST_CHANNEL=X.Y.Z; use packaging/revisions.tsv for stable polling'
		fi
		revision=$DEB_REVISION
	fi
	if [[ ! $revision =~ ^[1-9][0-9]*$ ]]; then
		die 'packaging revision must be a positive integer'
	fi
	printf '%s\n' "$revision"
}

recipe_digest() {
	local root=${1:-$ROOT_DIR}
	(
		if ! cd -- "$root"; then
			die 'cannot enter repository directory'
		fi
		# These files construct package bytes. Release inputs and tool versions
		# are recorded separately in the package identity. Polling, retention,
		# signing and workflow changes must not force a packaging revision.
		sha256sum scripts/lib/common.sh scripts/lib/package.sh
		printf '%s\n' "$DEB_MAINTAINER"
	) | sha256sum | cut --delimiter=' ' --fields=1
}

publisher_digest() {
	local root=${1:-$ROOT_DIR}
	(
		if ! cd -- "$root"; then
			die 'cannot enter repository directory'
		fi
		sha256sum scripts/poll-release.sh scripts/sync-apt-repo.sh \
			scripts/lib/activation.sh \
			packaging/rust.pref scripts/lib/cache.sh scripts/lib/upstream.sh scripts/lib/archive.sh \
			scripts/lib/retention.sh scripts/lib/history-auth.sh \
			keys/rust-release.asc .github/workflows/publish.yml \
			tests/test-jammy.sh tests/jammy-smoke.sh
	) | sha256sum | cut --delimiter=' ' --fields=1
}

check_package_cache() {
	local directory=$1 identity=$2 name digest
	PACKAGE_CACHE_HIT=false
	export PACKAGE_CACHE_HIT
	if [[ ! -f $directory/metadata.json ]]; then
		return
	fi
	if ! jq --exit-status '
        (.packages | length == 12) and
        all(.packages[]; (.name | test("^[a-z0-9][a-z0-9.+_-]*\\.deb$")) and
            (.sha256 | test("^[0-9a-f]{64}$")))
    ' "$directory/metadata.json" >/dev/null; then
		die 'invalid package cache inventory'
	fi
	if ! jq --exit-status --slurpfile identity "$identity" '.identity == $identity[0]' \
		"$directory/metadata.json" >/dev/null; then
		die 'package inputs changed at an existing version; increment the packaging revision'
	fi
	while IFS=$'\t' read -r name digest; do
		if [[ ! -f $directory/$name ]] || [[ $(sha256 "$directory/$name") != "$digest" ]]; then
			return
		fi
	done < <(jq --raw-output '.packages[] | [.name,.sha256] | @tsv' "$directory/metadata.json")
	PACKAGE_CACHE_HIT=true
}

record_package_cache() {
	local built=$1 directory=$2 identity=$3 inventory=$4 deb
	: >"$inventory"
	for deb in "$built"/*.deb; do
		jq --null-input --compact-output --arg name "${deb##*/}" --arg hash "$(sha256 "$deb")" \
			'{name:$name,sha256:$hash}' >>"$inventory"
	done
	if [[ -f $directory/metadata.json ]]; then
		if ! jq --exit-status --slurpfile actual "$inventory" \
			'(.packages | map({name,sha256}) | sort_by(.name)) == ($actual | sort_by(.name))' \
			"$directory/metadata.json" >/dev/null; then
			die 'rebuild changed package bytes; increment the packaging revision'
		fi
	fi
	mkdir --parents -- "$directory"
	cp -- "$built"/*.deb "$directory/"
	jq --null-input --slurpfile identity "$identity" --slurpfile packages "$inventory" \
		'{identity:$identity[0], packages:$packages}' >"$directory/metadata.json"
}

prune_cache() {
	local cache=$1 current=$2 release=$3 keep=$4 catalog=$5 old
	jq --raw-output '.assets[] | select(.component != "rustc-src") | .sha256 + ".tar.xz"' \
		"$release" >"$keep"
	printf 'rustc-%s-src.tar.xz\nrustc-%s-src.tar.xz.asc\n' "$RUST_VERSION" "$RUST_VERSION" >>"$keep"
	for old in "$cache/downloads"/*; do
		if [[ -f $old ]] && ! grep --fixed-strings --line-regexp --quiet "${old##*/}" "$keep"; then
			rm --force -- "$old"
		fi
	done
	for old in "$cache/packages"/*; do
		if [[ -d $old && $old != "$current" ]]; then
			if ! jq --exit-status --arg version "${old##*/}" \
				'any(.releases[]; .debian_version == $version)' "$catalog" >/dev/null; then
				rm --recursive --force -- "$old"
			fi
		fi
	done
	jq --raw-output '.packages[].sha256 + ".deb"' "$catalog" >"$keep"
	for old in "$cache/history"/*.deb; do
		if [[ -f $old ]] && ! grep --fixed-strings --line-regexp --quiet "${old##*/}" "$keep"; then
			rm --force -- "$old"
		fi
	done
}
