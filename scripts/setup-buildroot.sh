#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) Opinsys Oy 2026

set -euo pipefail

if (($# < 7)); then
  echo "usage: $0 <lock_file> <tarball> <hash> <board_dir> <src_dir> <stamp_file> <base_patch> [extra_patches...]" >&2
  exit 1
fi

lock_file=$(realpath -m -- "$1")
tarball=$2
hash=$3
board_dir=$4
while [[ $board_dir == */ && $board_dir != / ]]; do
  board_dir=${board_dir%/}
done
if [[ -L "$board_dir" || /$board_dir/ == */./* || /$board_dir/ == */../* ]]; then
  echo "error: board directory must not be a symbolic link or contain dot components: $board_dir" >&2
  exit 1
fi
board_dir=$(realpath -m -- "$board_dir")
src_dir=$(realpath -m -- "$5")
stamp_file=$(realpath -m -- "$6")
shift 6
patches=("$@")

if [[ $board_dir == / || $src_dir != "$board_dir/"* ||
      $stamp_file != "$board_dir/"* || $lock_file == "$board_dir" || $lock_file == "$board_dir/"* ]]; then
  echo "error: source and stamp must be inside the board directory, and lock outside it" >&2
  exit 1
fi
for input in "$tarball" "${patches[@]}"; do
  input_path=$(realpath -- "$input")
  if [[ $input_path == "$board_dir/"* ]]; then
    echo "error: preparation input must be outside the board directory: $input" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$lock_file")"
exec 9>"$lock_file"
flock 9

echo "$hash  $tarball" | sha256sum --status -c -
patch_hashes=$(sha256sum -- "${patches[@]}" | cut -d' ' -f1)
key=$(printf '%s\n' "$hash" "$src_dir" "$patch_hashes" | sha256sum | cut -d' ' -f1)
if [[ -f "$stamp_file" && $(<"$stamp_file") == "$key" ]]; then
  exit 0
fi

rm -rf -- "$board_dir"
mkdir -p "$src_dir"
tar -xf "$tarball" --strip-components=1 -C "$src_dir"
for p in "${patches[@]}"; do
  patch --batch --forward -d "$src_dir" -p1 -i "$(realpath -- "$p")"
done

mkdir -p "$(dirname "$stamp_file")"
printf '%s\n' "$key" > "$stamp_file"
