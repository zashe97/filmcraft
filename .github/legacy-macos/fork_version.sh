#!/usr/bin/env bash
# Prints the version a fork publishes for an upstream release: usage fork_version.sh <repo> <X.Y.Z>.
# The launcher updates itself only to a higher version, so its builds carry this fork's own
# revision in the patch number: X.Y.(Z*100 + revision). Raising the number in `revision` ships a
# fix to the launcher's users through its self-update, and every later upstream release still
# sorts higher (0.4.1 -> 0.4.100, 0.4.101, ... then 0.4.2 -> 0.4.2xx). The apps keep upstream's.
set -euo pipefail
repo="${1:?repo}"
version="${2:?version}"
if [ "$repo" != craft-launcher ]; then echo "$version"; exit 0; fi
rev=$(tr -cd '0-9' < "$(dirname "${BASH_SOURCE[0]}")/revision")
rev=${rev:-0}
if [ "$rev" -ge 100 ]; then echo "revision must stay below 100" >&2; exit 1; fi
IFS=. read -r major minor patch <<<"$version"
echo "$major.$minor.$((patch * 100 + rev))"
