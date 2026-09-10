#!/usr/bin/env bash

test_native_jammy_wrapper() (
	set -o errexit -o nounset -o pipefail
	local directory="$WORK_DIR/native-wrapper" fixture runner archive previous
	fixture="$directory/tests"
	runner="$fixture/test-jammy.sh"
	archive="$directory/archive with spaces"
	previous="$directory/previous"
	mkdir --parents -- "$fixture" "$directory/bin" "$archive" "$previous"
	cp -- "$ROOT_DIR/tests/test-jammy.sh" "$runner"
	printf '{}\n' >"$archive/releases.json"
	printf '{}\n' >"$previous/releases.json"
	ln --symbolic -- "$archive" "$directory/dist"
cat >"$directory/bin/sudo" <<'SH'
#!/bin/sh
exec "$@"
SH
	cat >"$fixture/jammy-smoke.sh" <<'SH'
#!/bin/bash
set -o errexit -o nounset -o pipefail
printf '%s\n' "$@" >"$3/arguments"
env >"$3/environment"
exit 37
SH
	chmod 0755 -- "$directory/bin/sudo" "$runner"
	export PATH="$directory/bin:$PATH"
	export APT_GPG_PRIVATE_KEY=fixture-private-key RUSTC=/fixture/wrong-rustc
	export CARGO_HOME=/fixture/wrong-cargo RUSTUP_TOOLCHAIN=fixture-wrong-toolchain
	unset GITHUB_ACTIONS RUNNER_ENVIRONMENT RUNNER_OS
	expect_failure 'direct smoke invocation needs explicit opt-in' env \
		--unset=JAMMY_SMOKE_ALLOW_SYSTEM_CHANGES /bin/bash "$ROOT_DIR/tests/jammy-smoke.sh" \
		--mode release "$archive"
	expect_failure 'unknown smoke mode rejected before system changes' env \
		JAMMY_SMOKE_ALLOW_SYSTEM_CHANGES=1 /bin/bash "$ROOT_DIR/tests/jammy-smoke.sh" \
		--mode invalid "$archive"
	expect_failure 'local machine needs explicit opt-in' "$runner" "$archive"
	if [[ -e $archive/arguments ]]; then
		die 'unapproved local test reached the system-mutating script'
	fi
	expect_failure 'previous archive needs full mode' "$runner" --allow-system-changes "$archive" "$previous"
	if [[ -e $archive/arguments ]]; then
		die 'invalid release arguments reached the system-mutating script'
	fi

	local mode status
	for mode in release full; do
		local args=(--allow-system-changes)
		if [[ $mode == full ]]; then args+=(--full); fi
		args+=("$directory/dist")
		if [[ $mode == full ]]; then args+=("$previous"); fi
		if "$runner" "${args[@]}"; then status=0; else status=$?; fi
		assert_eq 37 "$status" 'native smoke failure reaches the caller'
		mapfile -t actual <"$archive/arguments"
		assert_eq --mode "${actual[0]}" 'mode flag forwarded'
		assert_eq "$mode" "${actual[1]}" 'selected validation mode'
		assert_eq "$archive" "${actual[2]}" 'generation pointer resolved without losing spaces'
		if [[ $mode == full ]]; then
			assert_eq "$previous" "${actual[3]}" 'previous archive forwarded'
		fi
		if grep --extended-regexp --quiet '^(APT_GPG_PRIVATE_KEY|RUSTC|CARGO_HOME|RUSTUP_TOOLCHAIN)=' "$archive/environment"; then
			die 'native smoke inherited signing credentials or host Rust configuration'
		fi
		grep --fixed-strings --line-regexp --quiet 'PATH=/usr/sbin:/usr/bin:/sbin:/bin' "$archive/environment"
		grep --fixed-strings --line-regexp --quiet 'JAMMY_SMOKE_ALLOW_SYSTEM_CHANGES=1' "$archive/environment"
	done
	rm -- "$archive/arguments"
	export GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=self-hosted RUNNER_OS=Linux
	expect_failure 'self-hosted runner needs explicit opt-in' "$runner" "$archive"
	if [[ -e $archive/arguments ]]; then die 'self-hosted runner bypassed opt-in'; fi
	export RUNNER_ENVIRONMENT=github-hosted
	if "$runner" "$directory/dist"; then status=0; else status=$?; fi
	assert_eq 37 "$status" 'hosted runner runs native validation automatically'
	assert_file "$archive/arguments" 'hosted runner invoked smoke test'
)
