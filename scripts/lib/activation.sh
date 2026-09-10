#!/usr/bin/env bash

# The output is a pointer into a sibling store. None of these files are added
# to the served archive, whose exact Pages size has already been checked.
archive__store_path() {
	printf '%s/.%s.generations\n' "$(dirname -- "$1")" "$(basename -- "$1")"
}

archive__check_store() {
	local store=$1
	if [[ -L $store || ! -d $store || ! -f $store/owner || -L $store/owner ]] ||
		[[ $(cat -- "$store/owner") != 'apt-rust archive generations v1' ]]; then
		die "refusing to use an unmanaged archive store: $store"
	fi
}

archive__prepare_store() {
	local store=$1
	if [[ ! -e $store && ! -L $store ]]; then
		if ! mkdir --parents -- "$(dirname -- "$store")" || ! mkdir -- "$store" ||
			! printf 'apt-rust archive generations v1\n' >"$store/owner"; then
			die "cannot create archive store: $store"
		fi
	fi
	archive__check_store "$store"

	if ! chmod 0755 -- "$store"; then
		die "cannot make archive store traversable: $store"
	fi
}

archive__generation_target() {
	local output=$1 store=$2 target leaf
	archive__check_store "$store"
	target=$(readlink -- "$output")
	leaf=${target#"${store##*/}/"}
	if [[ $target != "${store##*/}/"* || $leaf != generation-* || $leaf == */* ||
		-L $store/$leaf || ! -d $store/$leaf || ! -f $store/$leaf/releases.json ]]; then
		die "refusing to replace an unmanaged archive pointer: $output"
	fi
	printf '%s\n' "$store/$leaf"
}

check_archive_output() {
	local output=$1 store
	store=$(archive__store_path "$output")
	if [[ -L $output ]]; then
		archive__generation_target "$output" "$store" >/dev/null
	elif [[ -e $output ]]; then
		die "refusing to replace an unmanaged archive path: $output"
	elif [[ -e $store || -L $store ]]; then
		archive__check_store "$store"
	fi
}

activate_archive() (
	set -o errexit -o nounset -o pipefail
	local stage=$1 output=$2 parent store generation='' switch_dir='' target='' old=''
	local generation_lock
	output=$(realpath --canonicalize-missing --no-symlinks -- "$output")
	parent=$(dirname -- "$output")
	store=$(archive__store_path "$output")
	check_archive_output "$output"
	if [[ -L $stage || ! -d $stage || ! -f $stage/releases.json ]]; then
		die 'archive activation requires a complete staging directory'
	fi
	stage=$(realpath -- "$stage")
	# Staging beside the output guarantees that the final pointer rename cannot
	# fall back to a cross-filesystem copy, even with stock Jammy coreutils.
	if [[ $(dirname -- "$stage") != $(realpath -- "$parent") ]]; then
		die 'archive staging must be a sibling of the output'
	fi
	archive__prepare_store "$store"
	if ! exec {generation_lock}>"$store/lock" || ! flock --exclusive "$generation_lock"; then
		die 'cannot lock archive store'
	fi
	check_archive_output "$output"
	if [[ -L $output ]]; then
		old=$(archive__generation_target "$output" "$store")
	fi
	cleanup_activation() {
		local status=$? published=''
		if [[ -L $output ]]; then published=$(readlink -- "$output"); fi
		# A signal after the rename must never remove the committed generation.
		if [[ -n $generation && -d $generation && $published != "$target" ]]; then
			rm --recursive --force -- "$generation"
		fi
		if [[ -n $switch_dir ]]; then rm --recursive --force -- "$switch_dir"; fi
		exit "$status"
	}
	trap cleanup_activation EXIT
	trap 'exit 143' TERM
	trap 'exit 130' INT
	trap 'exit 129' HUP
	if ! generation=$(mktemp --directory "$store/generation-XXXXXX"); then
		die 'cannot allocate archive generation'
	fi
	target="${store##*/}/${generation##*/}"
	if ! mv --no-target-directory -- "$stage" "$generation"; then
		die 'cannot prepare archive generation'
	fi
	if ! switch_dir=$(mktemp --directory "$parent/.rust-archive-switch-XXXXXX") ||
		! ln --symbolic -- "$target" "$switch_dir/current"; then
		die 'cannot prepare archive pointer'
	fi
	if ! mv --force --no-target-directory -- "$switch_dir/current" "$output"; then
		die 'archive pointer switch failed; current archive was preserved'
	fi
	# Cleanup is after the atomic commit. Interrupted cleanup can leave unused
	# generations, but the public pointer always resolves to a complete archive.
	if [[ -n $old && $old != "$generation" ]]; then
		rm --recursive --force -- "$old"
	fi
)
