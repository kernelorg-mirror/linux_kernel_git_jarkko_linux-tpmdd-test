#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) Opinsys Oy 2026

set -euo pipefail

git ls-files -z --cached --others --exclude-standard | (
  sh_files=()
  py_files=()
  shell_shebang_re='^#!([^[:space:]]*/)?(env([[:space:]]+-S)?[[:space:]]+)?(a|ba|da|k)?sh([[:space:]]|$)'
  python_shebang_re='^#!([^[:space:]]*/)?(env([[:space:]]+-S)?[[:space:]]+)?python3?([[:space:]]|$)'
  while IFS= read -r -d '' file; do
    [[ -f "$file" ]] || continue
    mapfile -t -n 1 header < "$file"
    if [[ $file == *.sh || ${header[0]-} =~ $shell_shebang_re ]]; then
      sh_files+=("$file")
    elif [[ $file == *.py || ${header[0]-} =~ $python_shebang_re ]]; then
      py_files+=("$file")
    fi
  done

  if ((${#sh_files[@]} > 0)); then
    shellcheck -x -- "${sh_files[@]}"
  fi

  if ((${#py_files[@]} > 0)); then
    python3 -c '
import sys

status = 0
for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        source = handle.read()
    try:
        compile(source, path, "exec")
    except SyntaxError as error:
        print(f"error: {path}:{error.lineno}: {error.msg}", file=sys.stderr)
        status = 1
sys.exit(status)
' "${py_files[@]}"
  fi
)
