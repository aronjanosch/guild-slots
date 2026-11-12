#!/usr/bin/env bash
# Symlink the GuildSlots addon (and optionally the probe) into a WoW AddOns folder.
#
# usage: tools/install.sh [--probe] <path to Interface/AddOns>
#
# Existing symlinks with the same name are replaced. Anything else already at the
# destination makes the script refuse, before any link is touched.
set -euo pipefail

usage() {
	echo "usage: $(basename "$0") [--probe] <path to Interface/AddOns>" >&2
	exit 2
}

probe=0
target=""
for arg in "$@"; do
	case "$arg" in
		--probe) probe=1 ;;
		-h | --help) usage ;;
		-*) echo "unknown option: $arg" >&2; usage ;;
		*)
			[ -z "$target" ] || usage
			target="$arg"
			;;
	esac
done
[ -n "$target" ] || usage

if [ ! -d "$target" ]; then
	echo "not a directory: $target" >&2
	exit 1
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sources=("$repo/GuildSlots")
if [ "$probe" -eq 1 ]; then
	sources+=("$repo/probe/GuildSlotsProbe")
fi

# Check every destination first so a refusal leaves the folder untouched.
for src in "${sources[@]}"; do
	dest="$target/$(basename "$src")"
	if [ -e "$dest" ] && [ ! -L "$dest" ]; then
		echo "refusing to overwrite existing non-symlink: $dest" >&2
		exit 1
	fi
done

for src in "${sources[@]}"; do
	dest="$target/$(basename "$src")"
	if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
		echo "already linked: $dest -> $src"
	elif [ -L "$dest" ]; then
		ln -sfn "$src" "$dest"
		echo "relinked: $dest -> $src"
	else
		ln -s "$src" "$dest"
		echo "linked: $dest -> $src"
	fi
done
