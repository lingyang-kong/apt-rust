#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

usage() {
	printf 'usage: %s [--full] [--allow-system-changes] DIST [PREVIOUS_DIST]\n' "${0##*/}" >&2
	exit 2
}

mode=release
allow_system_changes=false
while (($# > 0)); do
	case $1 in
	--full)
		mode=full
		shift
		;;
	--allow-system-changes)
		allow_system_changes=true
		shift
		;;
	--)
		shift
		break
		;;
	-*) usage ;;
	*) break ;;
	esac
done
if (($# < 1 || $# > 2)); then
	usage
fi
if (($# == 2)) && [[ $mode != full ]]; then
	printf 'PREVIOUS_DIST requires --full\n' >&2
	exit 2
fi

if [[ $allow_system_changes != true ]] &&
	[[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted || ${RUNNER_OS:-} != Linux ]]; then
	printf 'Use --allow-system-changes only on a disposable Jammy machine; this test installs system packages.\n' >&2
	exit 2
fi

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
archives=()
for archive in "$@"; do
	archive=$(realpath -- "$archive")
	if [[ ! -d $archive || ! -f $archive/releases.json ]]; then
		printf 'archive has no releases.json: %s\n' "$archive" >&2
		exit 1
	fi
	archives+=("$archive")
done

printf 'Running native Jammy %s validation for %s\n' "$mode" "${archives[0]}"
exec sudo env --ignore-environment PATH=/usr/sbin:/usr/bin:/sbin:/bin \
	JAMMY_SMOKE_ALLOW_SYSTEM_CHANGES=1 \
	/bin/bash "$test_dir/jammy-smoke.sh" --mode "$mode" "${archives[@]}"
