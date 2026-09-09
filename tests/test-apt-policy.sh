#!/usr/bin/env bash
# Candidate selection against independent repository fixtures; no host APT state.

test_apt_candidate_selection() (
	set -o errexit -o nounset -o pipefail
	local directory="$WORK_DIR/apt-policy"
	local repository version origin
	setup_apt_test_root "$directory"
	APT_TEST_OPTIONS+=( -o 'APT::Get::List-Cleanup=true' )
	for repository in ubuntu rust-same rust-new; do
		case $repository in
		ubuntu)
			version='1.91.1+dfsg-1'
			origin='Ubuntu'
			;;
		rust-same)
			version='1.91.1-1'
			origin='Unofficial Rust APT'
			;;
		rust-new)
			version='1.92.0-1'
			origin='Unofficial Rust APT'
			;;
		esac
		mkdir --parents "$directory/$repository/dists/jammy/main/binary-amd64"
		printf 'Package: rustc\nVersion: %s\nArchitecture: amd64\nDescription: APT policy fixture\n\n' "$version" \
			>"$directory/$repository/dists/jammy/main/binary-amd64/Packages"
		(
			cd "$directory/$repository/dists/jammy"
			apt-ftparchive \
				-o "APT::FTPArchive::Release::Origin=$origin" \
				-o 'APT::FTPArchive::Release::Codename=jammy' \
				-o 'APT::FTPArchive::Release::Architectures=amd64' \
				-o 'APT::FTPArchive::Release::Components=main' release .
		) >"$directory/Release"
		mv "$directory/Release" "$directory/$repository/dists/jammy/Release"
	done
	local selected candidate
	for selected in rust-same rust-new; do
		printf 'deb [trusted=yes] file:%s/ubuntu jammy main\ndeb [trusted=yes] file:%s/%s jammy main\n' \
			"$directory" "$directory" "$selected" >"$directory/sources.list"
		apt-get "${APT_TEST_OPTIONS[@]}" update >"$directory/update.log" 2>&1
		candidate=$(apt-cache "${APT_TEST_OPTIONS[@]}" policy rustc | awk '/Candidate:/ { print $2 }')
		case $selected in
		rust-same) assert_eq '1.91.1+dfsg-1' "$candidate" 'Ubuntu same-upstream candidate at default priorities' ;;
		rust-new) assert_eq '1.92.0-1' "$candidate" 'newer upstream candidate at default priorities' ;;
		esac
	done
	printf 'deb [trusted=yes] file:%s/ubuntu jammy main\ndeb [trusted=yes] file:%s/rust-same jammy main\n' \
		"$directory" "$directory" >"$directory/sources.list"
	printf 'Package: rustc\nPin: release o=Unofficial Rust APT\nPin-Priority: 600\n' >"$directory/preferences"
	apt-get "${APT_TEST_OPTIONS[@]}" update >"$directory/update.log" 2>&1
	candidate=$(apt-cache "${APT_TEST_OPTIONS[@]}" policy rustc | awk '/Candidate:/ { print $2 }')
	assert_eq '1.91.1-1' "$candidate" 'optional origin pin selects our same-upstream package'
	printf 'Package: rustc\nStatus: install ok installed\nVersion: 1.91.1+dfsg-1\nArchitecture: amd64\nDescription: installed fixture\n' \
		>"$directory/status"
	candidate=$(apt-cache "${APT_TEST_OPTIONS[@]}" policy rustc | awk '/Candidate:/ { print $2 }')
	assert_eq '1.91.1+dfsg-1' "$candidate" 'priority 600 does not force an installed-package downgrade'
)
