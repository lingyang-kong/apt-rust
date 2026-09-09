#!/usr/bin/env bash
# Shared helpers; callers enable errexit, nounset, pipefail and inherit_errexit.

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

require_command() {
	local command_name
	for command_name in "$@"; do
		if ! command -v "$command_name" >/dev/null; then
			die "missing required command: $command_name"
		fi
	done
}

sha256() {
	sha256sum -- "$1" | cut --delimiter=' ' --fields=1
}

tree_bytes() {
	if [[ -d $1 ]]; then
		find "$1" -type f -printf '%s\n' | awk '{ total += $1 } END { printf "%.0f\n", total }'
	else
		printf '0\n'
	fi
}

safe_extract() {
	local archive=$1 destination=$2 path target resolved
	mkdir --parents -- "$destination"
	destination=$(realpath -- "$destination")
	if [[ -n $(find "$destination" -mindepth 1 -print -quit) ]]; then
		die "extraction destination is not empty: $destination"
	fi
	# GNU tar's default link protections are intentional: never enable
	# --absolute-names or --keep-directory-symlink for upstream archives.
	if ! tar --list --xz --quoting-style=escape --file="$archive" |
		awk '/^\// || /(^|\/)\.\.(\/|$)/ || /\\/ { bad=1 }
             END { exit bad }'; then
		die 'unsafe archive member name'
	fi
	if ! tar --extract --xz --file="$archive" --directory="$destination" \
		--no-same-owner --no-same-permissions --delay-directory-restore --keep-old-files; then
		die 'archive extraction failed'
	fi
	while IFS= read -r -d '' path; do
		target=$(readlink -- "$path")
		case $target in
		/* | *$'\n'* | *$'\r'* | *$'\t'*) die "unsafe archive link: $path" ;;
		esac
		resolved=$(realpath --canonicalize-missing -- "${path%/*}/$target")
		case $resolved in
		"$destination"/*) ;;
		*) die "escaping archive link: $path" ;;
		esac
	done < <(find "$destination" -type l -print0)
}
