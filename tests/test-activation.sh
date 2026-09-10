#!/usr/bin/env bash

activation__fixture() {
	local directory=$1 version=$2
	mkdir --parents -- "$directory"
	printf '{"version":"%s"}\n' "$version" >"$directory/releases.json"
	printf '%s package bytes\n' "$version" >"$directory/package.deb"
}

# Inject failure in the same shell as activation, immediately before/after the
# actual rename. The signal targets only that activation subshell.
activation__with_fault() (
	local operation=$1 stage=$2 output=$3 fault=$4 armed=true
	mv() {
		local destination=${!#}
		if [[ $destination == "$output" && $armed == true ]]; then
			armed=false
			case $fault in
			before-term) kill -TERM "$BASHPID" ;;
			before-kill) kill -KILL "$BASHPID" ;;
			rename-failure) return 1 ;;
			esac
			command mv "$@"
			case $fault in
			after-term) kill -TERM "$BASHPID" ;;
			after-kill) kill -KILL "$BASHPID" ;;
			esac
		else
			command mv "$@"
		fi
	}
	case $operation in
	activate) activate_archive "$stage" "$output" ;;
	migrate) migrate_archive_offline "$output" ;;
	esac
)

test_atomic_activation() (
	set -o errexit -o nounset -o pipefail
	local directory="$WORK_DIR/activation" output stage old fault expected status
	local store
	mkdir --parents -- "$directory"
	output="$directory/current"
	stage="$directory/first"
	(
		umask 0077
		activation__fixture "$stage" old
		archive__set_public_permissions "$stage"
		activate_archive "$stage" "$output"
	)
	assert_symlink "$output" 'first publication uses managed pointer'
	assert_eq old "$(jq --raw-output '.version' "$output/releases.json")" 'first publication'
	store=$(archive__store_path "$output")
	assert_eq 755 "$(stat --format='%a' "$store")" 'private build umask does not hide archive store'
	old=$(realpath -- "$output")
	assert_public_archive "$old"
	assert_eq "$(measure_pages_artifact_bytes "$old")" "$(measure_pages_artifact_bytes "$output")" \
		'Pages tar follows the archive pointer'
	assert_eq "$(tree_bytes "$old")" "$(tree_bytes "$output/")" \
		'published size report follows the archive pointer'
	tar --dereference --hard-dereference --directory "$output" --create --file="$directory/pages.tar" .
	assert_eq 'old package bytes' "$(tar --extract --to-stdout --file="$directory/pages.tar" ./package.deb)" \
		'Pages artifact contains archive files through the pointer'
	stage="$directory/second"
	activation__fixture "$stage" new
	chmod 0700 -- "$store"
	activate_archive "$stage" "$output"
	assert_eq 755 "$(stat --format='%a' "$store")" 'existing archive store becomes traversable'
	assert_eq new "$(jq --raw-output '.version' "$output/releases.json")" 'second publication'
	if [[ -e $old || -e $stage ]]; then
		die 'activation did not clean the previous generation and staging path'
	fi
	assert_eq 1 "$(find "$store" -mindepth 1 -maxdepth 1 -type d -name 'generation-*' | wc --lines)" \
		'normal activation keeps one generation'

	for fault in rename-failure before-term after-term before-kill after-kill; do
		output="$directory/$fault"
		activation__fixture "$directory/initial-$fault" old
		activate_archive "$directory/initial-$fault" "$output"
		old=$(realpath -- "$output")
		stage="$directory/stage-$fault"
		activation__fixture "$stage" new
		status=0
		if activation__with_fault activate "$stage" "$output" "$fault" >"$directory/$fault.log" 2>&1; then
			die "$fault unexpectedly succeeded"
		else
			status=$?
		fi
		case $fault in
		rename-failure)
			expected=old
			assert_eq 1 "$status" 'rename failure status'
			;;
		before-term)
			expected=old
			assert_eq 143 "$status" 'interruption before commit'
			;;
		after-term)
			expected=new
			assert_eq 143 "$status" 'interruption after commit'
			;;
		before-kill)
			expected=old
			assert_eq 137 "$status" 'kill before commit'
			;;
		after-kill)
			expected=new
			assert_eq 137 "$status" 'kill after commit'
			;;
		esac
		assert_symlink "$output" "$fault preserves output pointer"
		assert_eq "$expected" "$(jq --raw-output '.version' "$output/releases.json")" "$fault active metadata"
		assert_eq "$expected package bytes" "$(cat -- "$output/package.deb")" "$fault active package"
		if [[ $expected == old ]]; then
			assert_eq "$old" "$(realpath -- "$output")" "$fault preserves exact generation"
		fi
		# A subsequent normal publish remains usable after either side of commit.
		activation__fixture "$directory/retry-$fault" retry
		activate_archive "$directory/retry-$fault" "$output"
		assert_eq retry "$(jq --raw-output '.version' "$output/releases.json")" "$fault retry"
	done

	output="$directory/legacy"
	activation__fixture "$output" legacy
	activation__fixture "$directory/legacy-stage" new
	expect_failure 'normal activation requires offline directory migration' activate_archive \
		"$directory/legacy-stage" "$output"
	assert_eq legacy "$(jq --raw-output '.version' "$output/releases.json")" 'legacy output preserved'
	assert_file "$directory/legacy-stage/releases.json" 'legacy refusal preserves staging'
	expect_failure 'publisher refuses legacy output before creating a cache' env \
		OUT_DIR="$output" CACHE_DIR="$directory/unused-cache" "$ROOT_DIR/scripts/sync-apt-repo.sh"
	if [[ -e $directory/unused-cache ]]; then
		die 'legacy output refusal created a build cache'
	fi
	ln --symbolic -- legacy "$directory/foreign-pointer"
	expect_failure 'foreign symlink refused' activate_archive "$directory/legacy-stage" "$directory/foreign-pointer"
	assert_eq legacy "$(readlink -- "$directory/foreign-pointer")" 'foreign pointer preserved'
)

test_offline_migration() (
	set -o errexit -o nounset -o pipefail
	local directory="$WORK_DIR/migration" output before fault expected status
	mkdir --parents -- "$directory"
	output="$directory/current"
	activation__fixture "$output" old
	before=$(sha256 "$output/package.deb")
	"$ROOT_DIR/scripts/migrate-archive.sh" --offline "$output"
	assert_symlink "$output" 'offline migration creates managed pointer'
	assert_eq "$before" "$(sha256 "$output/package.deb")" 'migration preserves package bytes'
	before=$(readlink -- "$output")
	"$ROOT_DIR/scripts/migrate-archive.sh" --offline "$output"
	assert_eq "$before" "$(readlink -- "$output")" 'migration is idempotent'
	expect_failure 'offline mode must be explicit' "$ROOT_DIR/scripts/migrate-archive.sh" "$output"

	for fault in rename-failure before-term after-term; do
		output="$directory/$fault"
		activation__fixture "$output" old
		status=0
		if activation__with_fault migrate '' "$output" "$fault" >"$directory/$fault.log" 2>&1; then
			die "$fault migration unexpectedly succeeded"
		else
			status=$?
		fi
		case $fault in
		rename-failure) expected=1 ;;
		*) expected=143 ;;
		esac
		assert_eq "$expected" "$status" "$fault migration exit status"
		assert_eq old "$(jq --raw-output '.version' "$output/releases.json")" "$fault migration preserves archive"
		if [[ $fault == after-term ]]; then
			assert_symlink "$output" 'committed migration survives interruption'
		elif [[ -L $output ]]; then
			die 'uncommitted migration did not restore the directory'
		fi
	done
)
