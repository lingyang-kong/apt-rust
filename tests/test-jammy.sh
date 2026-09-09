#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	printf 'usage: %s DIST [PREVIOUS_DIST]\n' "${0##*/}" >&2
	exit 2
}

if (($# != 1 && $# != 2)); then
	usage
fi

dist=$(cd -- "$1" && pwd -P)
test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ! -f "$dist/releases.json" ]]; then
	printf 'archive has no releases.json: %s\n' "$dist" >&2
	exit 1
fi

docker_bin=${DOCKER:-docker}
if ! command -v "$docker_bin" >/dev/null 2>&1; then
	printf 'Docker executable not found: %s\n' "$docker_bin" >&2
	exit 1
fi

mounts=(
	--mount "type=bind,source=$dist,target=/repo,readonly"
	--mount "type=bind,source=$test_dir,target=/tests,readonly"
)
smoke_args=(/repo)
if (($# == 2)); then
	previous=$(cd -- "$2" && pwd -P)
	if [[ ! -f "$previous/releases.json" ]]; then
		printf 'previous archive has no releases.json: %s\n' "$previous" >&2
		exit 1
	fi
	mounts+=(--mount "type=bind,source=$previous,target=/previous,readonly")
	smoke_args+=(/previous)
fi

printf 'Running clean Ubuntu 22.04 Jammy smoke test for %s\n' "$dist"
"$docker_bin" run --rm \
	--env JAMMY_SMOKE_IN_CONTAINER=1 \
	"${mounts[@]}" \
	ubuntu:22.04 /tests/jammy-smoke.sh "${smoke_args[@]}"
