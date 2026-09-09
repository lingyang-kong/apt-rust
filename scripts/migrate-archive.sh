#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
shopt -s inherit_errexit

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/activation.sh
source "$ROOT_DIR/scripts/lib/activation.sh"

if [[ $# != 2 || $1 != --offline ]]; then
	printf 'usage: %s --offline OUT_DIR\nRun once while the local archive is not being served.\n' "${0##*/}" >&2
	exit 2
fi
require_command flock realpath mv ln
migrate_archive_offline "$2"
