#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) Opinsys Oy 2026

set -euo pipefail

git ls-files -z | (
  sh_files=()
  shell_shebang_re='^#!([^[:space:]]*/)?(env([[:space:]]+-S)?[[:space:]]+)?(a|ba|da|k)?sh([[:space:]]|$)'
  while IFS= read -r -d '' file; do
    [[ -f "$file" ]] || continue
    mapfile -t -n 1 header < "$file"
    if [[ $file == *.sh || ${header[0]-} =~ $shell_shebang_re ]]; then
      sh_files+=("$file")
    fi
  done

  if ((${#sh_files[@]} > 0)); then
    shellcheck -x -- "${sh_files[@]}"
  fi
)
