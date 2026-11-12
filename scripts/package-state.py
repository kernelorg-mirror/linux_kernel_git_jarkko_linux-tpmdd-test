#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) Opinsys Oy 2026

from __future__ import annotations

import argparse
import bisect
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any

from state import BuildState

_EXCLUDES = ("__pycache__", "*.pyc", "dist", ".git")
_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9+_.-]*\Z")
_SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
_CONFIG_REF_RE = re.compile(r"\bBR2_[A-Za-z0-9_]+\b")
_CONFIG_ASSIGNMENT_RE = re.compile(r"(BR2_[A-Za-z0-9_]+)=(.*)\Z")
_NOT_SET_RE = re.compile(r"# (BR2_[A-Za-z0-9_]+) is not set\Z")
_CONFIG_METADATA = frozenset(
    {
        "BR2_DEFCONFIG",
        "BR2_DL_DIR",
        "BR2_JLEVEL",
        "BR2_PRIMARY_SITE",
        "BR2_PRIMARY_SITE_ONLY",
        "BR2_BACKUP_SITE",
        "BR2_KERNEL_MIRROR",
        "BR2_GNU_MIRROR",
        "BR2_LUAROCKS_MIRROR",
        "BR2_CPAN_MIRROR",
        "BR2_GOOGLE_MIRROR",
        "BR2_EXTERNAL_NAMES",
        "BR2_HAVE_DOT_CONFIG",
        "BR2_TARGET_ROOTFS_OCI_LABELS",
    }
)
_DATA_FIELDS = ("KCONFIG_FILE", "KCONFIG_FRAGMENT_FILES", "CONFIG_FILE")
_MAKE_FUNCTIONS = frozenset(
    (
        "subst patsubst strip findstring filter filter-out sort word wordlist words "
        "firstword lastword dir notdir suffix basename addsuffix addprefix join "
        "wildcard realpath abspath if or and intcmp foreach let call value eval "
        "origin flavor shell file error warning info guile"
    ).split()
)
_EPHEMERAL_MAKE_VARS = frozenset(
    {
        "MAKEFLAGS",
        "MFLAGS",
        "MAKELEVEL",
        "MAKE_TERMOUT",
        "MAKE_TERMERR",
        "DATE",
        "BR2_LOCALVERSION",
        "BR2_VERSION_FULL",
        "BR2_VERSION_GIT_EPOCH",
        "CUR_UMASK",
        "BR_ORIG_UMASK",
        "TPMDD_PACKAGE_STATE_DIR",
        "-*-command-variables-*-",
        "-*-eval-flags-*-",
    }
)
_ACCUMULATOR_GLOBALS = frozenset(
    {
        "KEEP_PYTHON_PY_FILES",
        "PACKAGES_BUSYBOX_CONFIG_FIXUPS",
        "PACKAGES_LINUX_CONFIG_FIXUPS",
        "PACKAGES_SELINUX_MODULES",
        "PACKAGES_SELINUX_EXTRA_MODULES_DIRS",
    }
)


@dataclass(frozen=True)
class ScanResult:
    references: frozenset[str]
    calls: frozenset[tuple[str, tuple[str, ...]]]
    prefixes: frozenset[str]
    suffixes: frozenset[str]
    opaque: bool


class MakeScanner:
    @staticmethod
    def split_call_arguments(text: str) -> list[str]:
        arguments: list[str] = []
        start = 0
        parens = 0
        braces = 0
        for index, char in enumerate(text):
            if char == "(":
                parens += 1
            elif char == ")":
                parens = max(0, parens - 1)
            elif char == "{":
                braces += 1
            elif char == "}":
                braces = max(0, braces - 1)
            elif char == "," and parens == 0 and braces == 0:
                arguments.append(text[start:index].strip())
                start = index + 1
        arguments.append(text[start:].strip())
        return arguments

    @staticmethod
    def bind_context(text: str, prefix: str, params: Sequence[str] = ()) -> str:
        def replace(match: re.Match[str]) -> str:
            if match.group(0) == "$$":
                return "$$"
            token = match.group(1) or match.group(2)
            if token == "PKG":
                return prefix
            position = int(token)
            return params[position - 1] if position <= len(params) else ""

        return re.sub(r"\$\$|\$\((PKG|[1-9])\)|\$\{(PKG|[1-9])\}", replace, text)

    @classmethod
    def scan_bound(cls, text: str) -> ScanResult:
        references: set[str] = set()
        calls: set[tuple[str, tuple[str, ...]]] = set()
        prefixes: set[str] = set()
        suffixes: set[str] = set()
        opaque = False
        index = 0
        while index < len(text):
            if text[index] != "$" or index + 1 == len(text):
                index += 1
                continue
            opening = text[index + 1]
            if opening == "$":
                index += 2
                continue
            if opening not in "({":
                if opening not in "@%<?^+*|0123456789":
                    references.add(opening)
                index += 2
                continue
            closing = ")" if opening == "(" else "}"
            end = index + 2
            depth = 1
            while end < len(text) and depth:
                depth += (text[end] == opening) - (text[end] == closing)
                end += 1
            if depth:
                return ScanResult(
                    frozenset(references),
                    frozenset(calls),
                    frozenset(prefixes),
                    frozenset(suffixes),
                    True,
                )
            body = text[index + 2 : end - 1].strip()
            if not body or re.fullmatch(
                r"(?:[@%<?^+*|][DF]?|[0-9]+|\$\(strip\s*\))", body
            ):
                pass
            elif re.fullmatch(r"[A-Za-z_.][A-Za-z0-9_.-]*", body):
                references.add(body)
            elif match := re.fullmatch(
                r"\$\(strip\s+([A-Za-z_.][A-Za-z0-9_.-]*)\)", body
            ):
                references.add(match[1])
            else:
                match = re.match(r"([A-Za-z-]+)(?:\s+|\Z)", body)
                if match and match[1] in _MAKE_FUNCTIONS:
                    function = match[1]
                    rest = body[match.end() :]
                    arguments = cls.split_call_arguments(rest) if rest else [""]
                    if function == "call":
                        target = arguments[0]
                        if re.fullmatch(r"[A-Za-z_.][A-Za-z0-9_.-]*", target):
                            calls.add((target, tuple(arguments[1:])))
                        elif pfx_match := re.match(
                            r"([A-Za-z_.][A-Za-z0-9_.-]*)\$", target
                        ):
                            prefixes.add(pfx_match[1])
                        else:
                            opaque = True
                    elif function in ("value", "origin", "flavor"):
                        if re.fullmatch(r"[A-Za-z_.][A-Za-z0-9_.-]*", arguments[0]):
                            references.add(arguments[0])
                        else:
                            opaque = True
                    elif function == "eval":
                        if not rest.lstrip().startswith("__tmp "):
                            opaque = True
                    elif function == "guile":
                        opaque = True
                elif match := re.match(r"([A-Za-z_.][A-Za-z0-9_.-]*):", body):
                    references.add(match[1])
                elif pfx_match := re.match(r"([A-Za-z_.][A-Za-z0-9_.-]*)\$", body):
                    prefixes.add(pfx_match[1])
                elif sfx_match := re.fullmatch(
                    r"\$\(call\s+UPPERCASE,\$\([A-Za-z_][A-Za-z0-9_]*\)\)(_[A-Za-z0-9_]+)",
                    body,
                ):
                    suffixes.add(sfx_match[1])
                else:
                    opaque = True
                nested = cls.scan_bound(body)
                references.update(nested.references)
                calls.update(nested.calls)
                prefixes.update(nested.prefixes)
                suffixes.update(nested.suffixes)
                opaque |= nested.opaque
            index = end
        return ScanResult(
            frozenset(references),
            frozenset(calls),
            frozenset(prefixes),
            frozenset(suffixes),
            opaque,
        )

    @classmethod
    def helper_inputs(
        cls,
        data: Mapping[str, Any],
        variables: Mapping[str, Mapping[str, str]],
        globals_data: Mapping[str, str],
        universe: Sequence[str],
        suffix_cache: dict[str, list[str]],
    ) -> tuple[dict[str, Mapping[str, str]], bool]:
        prefix = data["prefix"]
        resolved = {
            **globals_data,
            **{f"{prefix}_{field}": value for field, value in data["expanded"].items()},
        }
        helpers: dict[str, Mapping[str, str]] = {}
        seen: set[tuple[str, tuple[str, ...], bool]] = set()
        opaque = False
        queue: list[tuple[str, tuple[str, ...], int, bool]] = [
            (name, (), 0, False) for name in data["definitions"]
        ]
        for hooks in data["hooks"].values():
            queue.extend((hook, (), 0, True) for hook in hooks)

        def enqueue_matches(
            prefixes: frozenset[str], suffixes: frozenset[str]
        ) -> None:
            for pfx in prefixes:
                position = bisect.bisect_left(universe, pfx)
                while position < len(universe) and universe[position].startswith(pfx):
                    queue.append((universe[position], (), 0, True))
                    position += 1
            for sfx in suffixes:
                matches = suffix_cache.get(sfx)
                if matches is None:
                    matches = [item for item in universe if item.endswith(sfx)]
                    suffix_cache[sfx] = matches
                queue.extend((item, (), 0, True) for item in matches)

        for field, body in data["raw"].items():
            scanned = cls.scan_bound(cls.bind_context(body, prefix))
            queue.extend((name, (), 0, True) for name in scanned.references)
            queue.extend((target, args, 1, True) for target, args in scanned.calls)
            enqueue_matches(scanned.prefixes, scanned.suffixes)
            opaque |= scanned.opaque
            if field.endswith("_HOOKS"):
                queue.extend(
                    (word, (), 0, True)
                    for word in re.findall(r"[A-Za-z_][A-Za-z0-9_.-]*", body)
                    if word in variables
                )
        while queue:
            name, params, depth, called = queue.pop()
            if name in _EPHEMERAL_MAKE_VARS or name.startswith("TPMDD_STATE_"):
                continue
            if (name, params, called) in seen:
                continue
            seen.add((name, params, called))
            record: Mapping[str, str] = (
                {"value": resolved[name], "flavor": "simple"}
                if name in resolved
                else variables.get(name, {"value": "", "flavor": "undefined"})
            )
            helpers.setdefault(name, record)
            body = record["value"]
            if name.endswith("_HOOKS"):
                queue.extend(
                    (word, (), 0, True)
                    for word in re.findall(r"[A-Za-z_][A-Za-z0-9_.-]*", body)
                    if word in variables
                )
            if record["flavor"] != "recursive":
                continue
            if not called and re.search(r"\$(?:[1-9]|\([1-9]\)|\{[1-9]\})", body):
                continue
            if depth > 6:
                opaque = True
                continue
            scanned = cls.scan_bound(cls.bind_context(body, prefix, params))
            queue.extend((target, (), 0, True) for target in scanned.references)
            queue.extend(
                (target, args, depth + 1, True) for target, args in scanned.calls
            )
            enqueue_matches(scanned.prefixes, scanned.suffixes)
            opaque |= scanned.opaque
        return helpers, opaque


class PackageCollector:
    @staticmethod
    def digest(value: object) -> str:
        return hashlib.sha256(
            json.dumps(
                value, sort_keys=True, ensure_ascii=True, separators=(",", ":")
            ).encode()
        ).hexdigest()

    @staticmethod
    def read_config(path: Path) -> dict[str, str]:
        config: dict[str, str] = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            if match := _CONFIG_ASSIGNMENT_RE.fullmatch(line):
                name, value = match.groups()
            elif match := _NOT_SET_RE.fullmatch(line):
                name, value = match.group(1), "n"
            elif not line or line.startswith("#"):
                continue
            else:
                raise ValueError(f"unrecognized configuration line in {path}: {line!r}")
            if name in config:
                raise ValueError(f"duplicate configuration symbol: {name}")
            config[name] = value
        if config.get("BR2_HAVE_DOT_CONFIG") != "y":
            raise ValueError(f"not a configured Buildroot output directory: {path.parent}")
        return config

    @staticmethod
    def global_config(config: Mapping[str, str]) -> dict[str, str]:
        return {
            name: value
            for name, value in config.items()
            if not name.startswith(("BR2_PACKAGE_", "BR2_LINUX_KERNEL", "BR2_CCACHE"))
            and not (
                name.startswith("BR2_EXTERNAL_")
                and name.endswith(("_PATH", "_VERSION"))
            )
            and name not in _CONFIG_METADATA
        }

    @staticmethod
    def normalizer(
        root: Path, board: Path, source: Path, download: Path | None = None
    ) -> Callable[[Any], Any]:
        items: list[tuple[Path, str]] = [
            (root, "<external>"),
            (board, "<output>"),
            (source, "<buildroot>"),
        ]
        if download is not None:
            items.append((download, "<download>"))
        prefixes = sorted(
            ((str(path), label) for path, label in items),
            key=lambda item: len(item[0]),
            reverse=True,
        )
        pattern = re.compile(
            "(?:"
            + "|".join(re.escape(prefix) for prefix, _ in prefixes)
            + r")(?![A-Za-z0-9_.+-])"
        )
        labels = dict(prefixes)

        def normalize(value: Any) -> Any:
            if isinstance(value, str):
                return pattern.sub(lambda match: labels[match.group()], value)
            if isinstance(value, list):
                return [normalize(item) for item in value]
            if isinstance(value, dict):
                return {name: normalize(item) for name, item in value.items()}
            return value

        return normalize

    @staticmethod
    def content_fingerprint(path: Path) -> str:
        previous = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.chdir(path.parent)
            return BuildState.fingerprint([path.name], excludes=_EXCLUDES)
        finally:
            os.fchdir(previous)
            os.close(previous)

    @staticmethod
    def input_path(
        value: str,
        root: Path,
        board: Path,
        source: Path,
        *,
        board_relative: bool = False,
        allow_external: bool = False,
    ) -> Path:
        path = Path(value)
        if not path.is_absolute():
            base = board if board_relative and (board / path).exists() else source
            path = base / path
        path = Path(os.path.normpath(path))
        resolved = path.resolve()
        if resolved.is_relative_to(board) and not resolved.is_relative_to(source):
            raise ValueError(f"configured data input points into build output: {path}")
        if not allow_external and not (
            resolved.is_relative_to(root) or resolved.is_relative_to(source)
        ):
            raise ValueError(
                f"unclassified package input outside external/Buildroot trees: {path}"
            )
        if not path.exists():
            raise FileNotFoundError(f"missing configured package input: {path}")
        return path

    @staticmethod
    def build_dirs(info: Mapping[str, Any]) -> list[str]:
        value = info.get("stamp_dir")
        if not isinstance(value, str):
            raise ValueError(f"missing or invalid stamp_dir: {info!r}")
        if not value:
            if info["virtual"]:
                return []
            raise ValueError(f"missing nonvirtual stamp_dir: {info!r}")
        path = Path(value)
        if (
            path.is_absolute()
            or len(value.split("/")) != 2
            or len(path.parts) != 2
            or path.parts[0] != "build"
            or path.parts[1] in (".", "..")
        ):
            raise ValueError(f"unsafe stamp_dir: {value!r}")
        return [path.as_posix()]

    @staticmethod
    def make_arguments(
        make_args: Sequence[str], root: Path, board: Path, source: Path
    ) -> tuple[list[str], dict[str, str]]:
        index = 0
        assignments: dict[str, str] = {}
        while index < len(make_args):
            arg = make_args[index]
            if arg in ("-j", "-l", "-C"):
                index += 1
                if index == len(make_args):
                    raise ValueError(f"missing value after {arg}")
                value = make_args[index]
                if arg == "-C":
                    if Path(value).resolve() != source:
                        raise ValueError("make -C does not match source")
                elif not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", value):
                    raise ValueError(f"invalid make option: {arg} {value}")
            elif re.fullmatch(r"-[jl][0-9]+(?:\.[0-9]+)?", arg):
                pass
            elif arg.startswith("-C") and Path(arg[2:]).resolve() == source:
                pass
            elif match := re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", arg, re.DOTALL):
                name, value = match.groups()
                assignments[name] = value
            else:
                raise ValueError(f"unsupported metadata make argument: {arg!r}")
            index += 1
        for name, expected in (("O", board), ("BR2_EXTERNAL", root)):
            if name in assignments and Path(assignments[name]).resolve() != expected:
                raise ValueError(f"make {name} does not match collector input")
        overrides = {
            name: value
            for name, value in assignments.items()
            if name
            not in {
                "O",
                "BR2_EXTERNAL",
                "BR2_CCACHE_DIR",
                "BR2_DL_DIR",
                "TPMDD_VERSION",
            }
        }
        return [*make_args, "-C", str(source), f"O={board}", f"BR2_EXTERNAL={root}"], overrides

    @classmethod
    def collect(
        cls, root: Path, board: Path, source: Path, make_args: Sequence[str]
    ) -> dict[str, Any]:
        root = root.resolve(strict=True)
        board = board.resolve(strict=True)
        source = source.resolve(strict=True)
        config = cls.read_config(board / ".config")
        if config.get("BR2_PER_PACKAGE_DIRECTORIES") != "y":
            raise ValueError("safe invalidation requires BR2_PER_PACKAGE_DIRECTORIES=y")
        arguments, overrides = cls.make_arguments(make_args, root, board, source)
        collector = Path(__file__).resolve().with_name("package-state.mk")
        with tempfile.TemporaryDirectory(prefix="tpmdd-package-state-") as temporary:
            result = subprocess.run(
                [
                    "make",
                    *arguments,
                    "--no-print-directory",
                    "-s",
                    "-f",
                    str(source / "Makefile"),
                    "-f",
                    str(collector),
                    f"TPMDD_PACKAGE_STATE_DIR={temporary}",
                    "show-info",
                ],
                cwd=source,
                text=True,
                stdout=subprocess.PIPE,
                check=True,
                umask=0o022,
            )
            upstream = json.loads(result.stdout)
            if not isinstance(upstream, dict) or not upstream:
                raise ValueError("Buildroot show-info did not return a package graph")
            globals_data = json.loads(
                (Path(temporary) / "globals.json").read_text(encoding="utf-8")
            )
            if (
                not isinstance(globals_data, dict)
                or not all(isinstance(value, str) for value in globals_data.values())
                or not globals_data.get("BR2_VERSION")
            ):
                raise ValueError("invalid Buildroot global metadata")
            download = (
                Path(globals_data["DL_DIR"]).resolve()
                if globals_data.get("DL_DIR")
                else None
            )
            normalize = cls.normalizer(root, board, source, download)
            raw_data = json.loads(
                (Path(temporary) / "raw-definitions.json").read_text(encoding="utf-8")
            )
            variables = raw_data.get("variables")
            if not isinstance(variables, dict) or not all(
                isinstance(record, dict)
                and isinstance(record.get("value"), str)
                and record.get("flavor") in ("simple", "recursive", "undefined")
                for record in variables.values()
            ):
                raise ValueError("invalid raw Make helper metadata")
            records: dict[str, dict[str, Any]] = {}
            for name, info in upstream.items():
                if not _NAME_RE.fullmatch(name) or not isinstance(info, dict):
                    raise ValueError(f"invalid upstream package metadata: {name!r}")
                if info.get("type") == "rootfs":
                    continue
                if info.get("type") not in ("host", "target") or type(
                    info.get("virtual")
                ) is not bool:
                    raise ValueError(f"unsupported package type/virtual metadata: {name}")
                data = json.loads(
                    (Path(temporary) / f"{name}.json").read_text(encoding="utf-8")
                )
                if not isinstance(data, dict) or data.get("info") != {name: info}:
                    raise ValueError(f"inconsistent package metadata: {name}")
                for field in ("expanded", "raw", "hooks", "definitions"):
                    if not isinstance(data.get(field), dict):
                        raise ValueError(f"missing bounded {field} metadata: {name}")
                if not all(
                    isinstance(value, str)
                    for field in ("expanded", "raw", "definitions")
                    for value in data[field].values()
                ):
                    raise ValueError(f"invalid bounded inputs: {name}")
                if not isinstance(data.get("prefix"), str) or not all(
                    isinstance(hooks, dict)
                    and all(isinstance(body, str) for body in hooks.values())
                    for hooks in data["hooks"].values()
                ):
                    raise ValueError(f"invalid hook metadata: {name}")
                records[name] = data

        packages: dict[str, dict[str, Any]] = {}
        identity_inputs: dict[str, dict[str, Any]] = {}
        content_cache: dict[Path, str] = {}
        universe = sorted(set(variables) | set(config))
        suffix_cache: dict[str, list[str]] = {}

        def content(path: Path) -> list[str]:
            if path not in content_cache:
                content_cache[path] = cls.content_fingerprint(path)
            return [normalize(str(path)), content_cache[path]]

        for name, data in sorted(records.items()):
            info = data["info"][name]
            dependencies = info.get("dependencies")
            if not isinstance(dependencies, list) or not all(
                isinstance(dep, str) and dep in records for dep in dependencies
            ):
                raise ValueError(f"incomplete package dependency graph: {name}")
            pkgdir = info.get("package_dir")
            if not isinstance(pkgdir, str) or not pkgdir:
                raise ValueError(f"missing package_dir: {name}")
            recipe = cls.input_path(pkgdir, root, board, source)
            if not recipe.is_dir():
                raise ValueError(f"package_dir is not a directory: {recipe}")
            inputs = [content(recipe)]
            rawname = info.get("name")
            if not isinstance(rawname, str) or not _NAME_RE.fullmatch(rawname):
                raise ValueError(f"invalid upstream raw package name: {name}")
            patches = root / "patches" / rawname
            if patches.exists():
                inputs.append(content(patches))
            for field in ("hashes", "patches"):
                paths = info.get(field, [])
                if not isinstance(paths, list) or not all(
                    isinstance(path, str) for path in paths
                ):
                    raise ValueError(f"invalid upstream {field}: {name}")
                for value in paths:
                    if "://" in value:
                        continue
                    inputs.append(
                        content(
                            cls.input_path(
                                value,
                                root,
                                board,
                                source,
                                board_relative=field == "patches",
                            )
                        )
                    )
            expanded = data["expanded"]
            for field in _DATA_FIELDS:
                for value in expanded.get(field, "").split():
                    inputs.append(content(cls.input_path(value, root, board, source)))
            override_srcdir = expanded.get("OVERRIDE_SRCDIR", "")
            if override_srcdir:
                inputs.append(
                    content(
                        cls.input_path(
                            override_srcdir,
                            root,
                            board,
                            source,
                            allow_external=True,
                        )
                    )
                )
            elif expanded.get("SITE_METHOD") == "local" and expanded.get("SITE", ""):
                inputs.append(
                    content(cls.input_path(expanded["SITE"], root, board, source))
                )
            helpers, opaque = MakeScanner.helper_inputs(
                data, variables, globals_data, universe, suffix_cache
            )
            references = set(
                _CONFIG_REF_RE.findall(
                    json.dumps([data["definitions"], data["raw"], data["hooks"], helpers])
                )
            )
            if opaque:
                references.update(
                    symbol for symbol in config if symbol.startswith("BR2_PACKAGE_")
                )
            package_config = {
                symbol: config.get(symbol, "n")
                for symbol in sorted(references)
                if not (
                    symbol.startswith("BR2_EXTERNAL_")
                    and symbol.endswith(("_PATH", "_VERSION"))
                )
            }
            if name == "linux":
                inputs.append(content(root / "linux"))
                package_config.update(
                    {
                        symbol: value
                        for symbol, value in config.items()
                        if symbol.startswith("BR2_LINUX_KERNEL")
                    }
                )
            metadata = {
                key: val
                for key, val in info.items()
                if key not in ("dependencies", "reverse_dependencies")
            }
            identity_inputs[name] = normalize(
                {
                    "metadata": metadata,
                    "expanded": expanded,
                    "raw": data["raw"],
                    "hooks": data["hooks"],
                    "definitions": data["definitions"],
                    "config": package_config,
                    "files": inputs,
                    "helpers": helpers,
                }
            )
            packages[name] = {
                "dependencies": sorted(set(dependencies)),
                "build_dirs": cls.build_dirs(info),
                "virtual": info["virtual"],
                "conservative": opaque,
            }
        for name, package in packages.items():
            pkg_inputs = identity_inputs[name]
            if name == "linux":
                pkg_inputs["dependency_metadata"] = {
                    dep: {
                        key: value
                        for key, value in identity_inputs[dep].items()
                        if key != "files"
                    }
                    for dep in package["dependencies"]
                }
            package["identity"] = cls.digest(pkg_inputs)

        common = [
            source / name
            for name in (
                "Makefile",
                "Makefile.legacy",
                "Config.in",
                "Config.in.legacy",
                "arch",
                "toolchain",
                "support",
                "system",
                "package/Makefile.in",
            )
        ]
        common.extend(sorted((source / "package").glob("pkg-*.mk")))
        common.extend(
            root / name
            for name in ("buildroot.patch", "sdk", "Config.in", "external.desc")
        )
        infrastructure = normalize(
            {
                "files": [content(path) for path in common],
                "globals": {
                    name: value
                    for name, value in globals_data.items()
                    if name not in _ACCUMULATOR_GLOBALS
                },
                "config": cls.global_config(config),
                "overrides": overrides,
                "source_hash": (
                    source.parent.name
                    if _SHA256_RE.fullmatch(source.parent.name)
                    else None
                ),
            }
        )
        return {
            "version": 1,
            "infrastructure": cls.digest(infrastructure),
            "external_mk": (root / "external.mk").read_text(encoding="utf-8"),
            "packages": packages,
        }


class PackageInvalidator:
    @staticmethod
    def read_json(path: Path) -> Any:
        return json.loads(path.read_text(encoding="utf-8"))

    @staticmethod
    def state_paths(board: Path) -> tuple[Path, Path, Path]:
        directory = board / "stamp/orchestration"
        return (
            directory,
            directory / "packages.json",
            directory / "packages.pending.json",
        )

    @staticmethod
    def validate_snapshot(snapshot: Any) -> None:
        if (
            not isinstance(snapshot, dict)
            or snapshot.get("version") != 1
            or not isinstance(snapshot.get("infrastructure"), str)
            or not isinstance(snapshot.get("external_mk"), str)
            or not isinstance(snapshot.get("packages"), dict)
        ):
            raise ValueError("invalid package state snapshot")
        for name, package in snapshot["packages"].items():
            if (
                not isinstance(name, str)
                or not _NAME_RE.fullmatch(name)
                or not isinstance(package, dict)
                or not isinstance(package.get("identity"), str)
                or not _SHA256_RE.fullmatch(package["identity"])
                or not isinstance(package.get("dependencies"), list)
                or not all(
                    isinstance(dep, str) and _NAME_RE.fullmatch(dep)
                    for dep in package["dependencies"]
                )
                or not isinstance(package.get("build_dirs"), list)
                or not all(isinstance(path, str) for path in package["build_dirs"])
            ):
                raise ValueError(f"invalid package state for {name}")

    @staticmethod
    def include_layout(text: str) -> bool:
        if "\0" in text:
            return False
        includes = 0
        for raw_line in text.splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("include "):
                expression = line.removeprefix("include ")
                includes += 1
            elif line.startswith("TPMDD_PYTHON_PACKAGE_MKS := "):
                expression = line.removeprefix("TPMDD_PYTHON_PACKAGE_MKS := ")
            else:
                return False
            for wildcard in ("*", "python-*"):
                expression = expression.replace(
                    f"$(BR2_EXTERNAL_TPMDD_PATH)/package/{wildcard}/*.mk", "\0"
                )
            expression = expression.replace("$(TPMDD_PYTHON_PACKAGE_MKS)", "\0")
            expression = re.sub(r"\$\((?:sort|wildcard|filter-out)\s+", "(", expression)
            if "\0" not in expression or not re.fullmatch(r"[\x00(),\s]+", expression):
                return False
        return includes > 0

    @staticmethod
    def board_path(board: Path, relative: str) -> Path:
        path = Path(relative)
        if (
            path.is_absolute()
            or len(path.parts) != 2
            or path.parts[0] not in ("build", "per-package")
        ):
            raise ValueError(f"not a board-owned package directory: {relative}")
        if not _NAME_RE.fullmatch(path.parts[1]) or path.parts[1] in (".", ".."):
            raise ValueError(f"invalid package directory: {relative}")
        result = board / path
        if (board / path.parts[0]).is_symlink() or result.is_symlink():
            raise ValueError(f"refusing a symlinked package directory: {result}")
        return result

    @staticmethod
    def cached_packages(board: Path) -> bool:
        packages = board / "per-package"
        return (
            (packages.is_dir() and any(packages.iterdir()))
            or any(
                path.parent.name != "buildroot-config"
                for path in (board / "build").glob("*/.stamp_*")
            )
            or any(
                path.is_file() or path.is_symlink()
                for name in ("target", "host")
                for path in (board / name).rglob("*")
            )
        )

    @classmethod
    def plan(
        cls,
        board: Path,
        current: Mapping[str, Any],
        baseline: Mapping[str, Any] | None,
        journal: Mapping[str, Any] | None,
    ) -> tuple[set[str], set[str]]:
        cls.validate_snapshot(current)
        reference = baseline
        if journal is not None:
            if (
                not isinstance(journal, dict)
                or journal.get("version") != 1
                or journal.get("phase") not in ("invalidating", "prepared")
                or not isinstance(journal.get("dirty"), list)
                or not all(
                    isinstance(name, str) and _NAME_RE.fullmatch(name)
                    for name in journal["dirty"]
                )
                or not isinstance(journal.get("paths"), list)
                or not all(isinstance(path, str) for path in journal["paths"])
            ):
                raise ValueError("invalid package invalidation journal")
            cls.validate_snapshot(journal["snapshot"])
            if journal["phase"] == "prepared":
                reference = journal["snapshot"]
        snapshots: list[Mapping[str, Any]] = [
            snap for snap in (baseline, reference, current) if snap is not None
        ]
        if journal is not None:
            snapshots.append(journal["snapshot"])
        for snap in snapshots:
            cls.validate_snapshot(snap)
            if snap["infrastructure"] != current["infrastructure"]:
                raise ValueError(
                    "build infrastructure or toolchain changed; targeted invalidation is not sufficient"
                )
            if snap["external_mk"] != current["external_mk"] and not (
                cls.include_layout(snap["external_mk"])
                and cls.include_layout(current["external_mk"])
            ):
                raise ValueError(
                    "unclassified external.mk change; refusing to reuse cached packages"
                )
        previous = reference["packages"] if reference is not None else {}
        packages = current["packages"]
        dirty = {
            name
            for name in previous.keys() | packages.keys()
            if previous.get(name) != packages.get(name)
        }
        paths: set[str] = set()
        if journal is not None and journal["phase"] == "invalidating":
            dirty.update(journal["dirty"])
            paths.update(journal["paths"])
        reverse: dict[str, set[str]] = {}
        for snap in snapshots:
            for name, package in snap["packages"].items():
                for dependency in package["dependencies"]:
                    reverse.setdefault(dependency, set()).add(name)
        queue = list(dirty)
        while queue:
            for consumer in reverse.get(queue.pop(), ()):
                if consumer not in dirty:
                    dirty.add(consumer)
                    queue.append(consumer)
        for name in dirty:
            paths.add(f"per-package/{name}")
            for snap in snapshots:
                package = snap["packages"].get(name)
                if package is not None:
                    paths.update(package["build_dirs"])
        for relative in paths:
            cls.board_path(board, relative)
        return dirty, paths

    @classmethod
    def prepare(
        cls, board: Path, current: Mapping[str, Any], *, readonly: bool = False
    ) -> None:
        directory, baseline_path, journal_path = cls.state_paths(board)
        baseline = cls.read_json(baseline_path) if baseline_path.exists() else None
        journal = cls.read_json(journal_path) if journal_path.exists() else None
        if baseline is None and journal is None and cls.cached_packages(board):
            raise ValueError(
                "cached packages have no verified package metadata; run a clean build first"
            )
        dirty, paths = cls.plan(board, current, baseline, journal)
        cached = sorted(
            name
            for name in dirty
            if (board / "per-package" / name).exists()
            or any(
                cls.board_path(board, rel).exists()
                for snap in (baseline, current)
                if snap is not None
                for rel in snap["packages"].get(name, {}).get("build_dirs", [])
            )
        )
        if readonly:
            print(
                json.dumps(
                    {
                        "dirty": sorted(dirty),
                        "cached": cached,
                        "paths": sorted(paths),
                    },
                    sort_keys=True,
                )
            )
            return
        BuildState.write_json(directory / "packages.next.json", current)
        if not dirty and journal is None:
            return
        if dirty:
            if cached:
                print(
                    f"{board.name}: invalidating {len(cached)} cached packages: {' '.join(cached)}",
                    flush=True,
                )
            pending = {
                "version": 1,
                "phase": "invalidating",
                "snapshot": current,
                "dirty": sorted(dirty),
                "paths": sorted(paths),
            }
            BuildState.write_json(journal_path, pending)
            (directory / "build.json").unlink(missing_ok=True)
            for relative in sorted(paths):
                path = cls.board_path(board, relative)
                if path.exists():
                    shutil.rmtree(path)
            for sync_target in (board / "build", board / "per-package", board):
                if sync_target.exists():
                    BuildState.sync_directory(sync_target)
            pending["phase"] = "prepared"
            BuildState.write_json(journal_path, pending)
        elif journal is not None:
            updated_journal = dict(journal)
            updated_journal["snapshot"] = current
            BuildState.write_json(journal_path, updated_journal)
            (directory / "build.json").unlink(missing_ok=True)

    @classmethod
    def assemble(cls, board: Path) -> None:
        directory, _, journal_path = cls.state_paths(board)
        current = cls.read_json(directory / "packages.next.json")
        cls.validate_snapshot(current)
        if journal_path.exists():
            journal = cls.read_json(journal_path)
            if journal.get("phase") != "prepared" or journal.get("snapshot") != current:
                raise ValueError(
                    "package invalidation must finish before aggregate assembly"
                )
        else:
            BuildState.write_json(
                journal_path,
                {
                    "version": 1,
                    "phase": "prepared",
                    "snapshot": current,
                    "dirty": [],
                    "paths": [],
                },
            )
        (directory / "build.json").unlink(missing_ok=True)
        for name in ("target", "host"):
            path = board / name
            if path.is_symlink():
                raise ValueError(f"refusing a symlinked aggregate directory: {path}")
            if path.exists():
                shutil.rmtree(path)
        BuildState.sync_directory(board)

    @classmethod
    def commit(cls, board: Path, current: Mapping[str, Any]) -> None:
        directory, baseline_path, journal_path = cls.state_paths(board)
        expected = cls.read_json(directory / "packages.next.json")
        cls.validate_snapshot(current)
        if current != expected:
            raise ValueError(
                "package inputs changed during the build; not recording success"
            )
        if journal_path.exists():
            journal = cls.read_json(journal_path)
            if journal.get("phase") != "prepared" or journal.get("snapshot") != current:
                raise ValueError("package invalidation is not ready to commit")
        BuildState.write_json(baseline_path, current)
        (directory / "packages.next.json").unlink()
        journal_path.unlink(missing_ok=True)
        BuildState.sync_directory(directory)

class PackageStateCli:
    @staticmethod
    def run(argv: Sequence[str] | None = None) -> int:
        raw_argv = list(sys.argv[1:] if argv is None else argv)
        parser = argparse.ArgumentParser()
        subparsers = parser.add_subparsers(dest="command", required=True)

        snapshot_parser = subparsers.add_parser("snapshot")
        for name in ("root", "board", "source", "output"):
            snapshot_parser.add_argument(f"--{name}", type=Path, required=True)
        snapshot_parser.add_argument("make_args", nargs=argparse.REMAINDER)

        for name in ("prepare", "plan", "commit"):
            cmd_parser = subparsers.add_parser(name)
            cmd_parser.add_argument("--root", required=True, type=Path)
            cmd_parser.add_argument("--board", required=True, type=Path)
            cmd_parser.add_argument("--source", required=True, type=Path)
            cmd_parser.add_argument("make_args", nargs=argparse.REMAINDER)

        assemble_parser = subparsers.add_parser("assemble")
        assemble_parser.add_argument("--board", required=True, type=Path)

        args = parser.parse_args(raw_argv)
        board = args.board.resolve()
        if not board.is_dir() or not (board / ".config").is_file():
            parser.error("board must be an existing configured Buildroot output")
        try:
            if args.command == "assemble":
                PackageInvalidator.assemble(board)
            else:
                make_args = (
                    args.make_args[1:]
                    if args.make_args[:1] == ["--"]
                    else args.make_args
                )
                snapshot = PackageCollector.collect(
                    args.root.resolve(), board, args.source.resolve(), make_args
                )
                if args.command == "snapshot":
                    BuildState.write_json(args.output, snapshot, indent=2)
                elif args.command == "commit":
                    PackageInvalidator.commit(board, snapshot)
                else:
                    PackageInvalidator.prepare(
                        board, snapshot, readonly=args.command == "plan"
                    )
        except (
            OSError,
            ValueError,
            KeyError,
            subprocess.CalledProcessError,
        ) as error:
            print(f"package-state: {error}", file=sys.stderr)
            return 1
        return 0


if __name__ == "__main__":
    raise SystemExit(PackageStateCli.run())
