#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) Opinsys Oy 2026

from __future__ import annotations

import argparse
from collections.abc import Sequence
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tarfile
import tempfile

_OCI_DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}\Z")


class BuildState:
    @staticmethod
    def fingerprint(
        paths: Sequence[str],
        values: Sequence[str] = (),
        excludes: Sequence[str] = (),
        *,
        metadata: bool = False,
    ) -> str:
        digest = hashlib.sha256()

        def record(value: object) -> None:
            digest.update(
                json.dumps(value, ensure_ascii=True, separators=(",", ":")).encode()
            )
            digest.update(b"\n")

        def visit(path: Path, relative: str) -> None:
            if any(
                fnmatch.fnmatch(relative, pattern) or fnmatch.fnmatch(path.name, pattern)
                for pattern in excludes
            ):
                return
            info = path.lstat()
            record([relative, stat.S_IMODE(info.st_mode)])
            if metadata:
                record(
                    [
                        info.st_dev,
                        info.st_ino,
                        info.st_size,
                        info.st_uid,
                        info.st_gid,
                        info.st_mtime_ns,
                        info.st_ctime_ns,
                    ]
                )
            if stat.S_ISLNK(info.st_mode):
                record(["link", os.readlink(path)])
            elif stat.S_ISDIR(info.st_mode):
                record("directory")
                for child in sorted(path.iterdir()):
                    visit(child, f"{relative}/{child.name}")
            elif stat.S_ISREG(info.st_mode):
                record(["file", info.st_size])
                if not metadata:
                    with path.open("rb") as handle:
                        while block := handle.read(1024 * 1024):
                            digest.update(block)
                    digest.update(b"\n")
            else:
                raise ValueError(f"unsupported build input: {path}")

        record(["build-state", 1])
        for value in values:
            record(["value", value])
        for name in paths:
            path = Path(name)
            label = os.path.normpath(name)
            record(["path", label])
            visit(path, label)
        return digest.hexdigest()

    @staticmethod
    def build_tree_key(board: Path) -> str:
        entries: list[list[object]] = []

        def stat_entry(label: str, path: Path | str) -> None:
            try:
                info = os.lstat(path)
            except FileNotFoundError:
                entries.append([label, "missing"])
            else:
                entries.append(
                    [label, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns]
                )

        for rel in ("target", "target/usr", "target/etc", "host", "host/bin", "staging"):
            stat_entry(rel, board / rel)

        for tree in ("build", "per-package"):
            root = board / tree
            if not root.is_dir():
                entries.append([tree, "missing"])
                continue
            with os.scandir(root) as packages:
                package_entries = sorted(
                    (entry for entry in packages if entry.is_dir(follow_symlinks=False)),
                    key=lambda entry: entry.name,
                )
            for package in package_entries:
                prefix = f"{tree}/{package.name}"
                stat_entry(prefix, package.path)
                if tree == "build":
                    with os.scandir(package.path) as children:
                        stamps = sorted(
                            (child for child in children if child.name.startswith(".stamp")),
                            key=lambda child: child.name,
                        )
                    for stamp in stamps:
                        stat_entry(f"{prefix}/{stamp.name}", stamp.path)
                else:
                    for sub in ("host", "target", "staging"):
                        stat_entry(f"{prefix}/{sub}", os.path.join(package.path, sub))
        return hashlib.sha256(
            json.dumps(entries, separators=(",", ":")).encode()
        ).hexdigest()

    @staticmethod
    def sync_directory(path: Path) -> None:
        dir_fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)

    @classmethod
    def write_json(
        cls,
        path: Path,
        value: object,
        *,
        indent: int | None = None,
    ) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", dir=path.parent, delete=False, encoding="utf-8"
            ) as handle:
                temporary = Path(handle.name)
                json.dump(value, handle, sort_keys=True, indent=indent)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
            cls.sync_directory(path.parent)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    @classmethod
    def save(
        cls,
        path: Path,
        key: str,
        outputs: Sequence[str],
        metadata_outputs: Sequence[str],
    ) -> None:
        all_outputs = [*outputs, *metadata_outputs]
        for output in all_outputs:
            if not Path(output).exists():
                raise FileNotFoundError(f"missing build output: {output}")
        data = {
            "version": 1,
            "key": key,
            "outputs": cls.fingerprint(outputs),
            "metadata_outputs": cls.fingerprint(metadata_outputs, metadata=True),
        }
        cls.write_json(path, data)
    @classmethod
    def check(
        cls,
        path: Path,
        key: str,
        outputs: Sequence[str],
        metadata_outputs: Sequence[str],
    ) -> bool:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError, UnicodeDecodeError):
            return False
        if not isinstance(data, dict) or data.get("version") != 1 or data.get("key") != key:
            return False
        if any(not Path(item).exists() for item in (*outputs, *metadata_outputs)):
            return False
        if data.get("outputs") != cls.fingerprint(outputs):
            return False
        if data.get("metadata_outputs") != cls.fingerprint(metadata_outputs, metadata=True):
            return False
        return True

    @staticmethod
    def oci_archive_digest(archive_path: Path) -> str:
        with tarfile.open(archive_path) as archive:
            try:
                member = archive.extractfile("index.json")
            except KeyError as error:
                raise ValueError(f"missing index.json in {archive_path}") from error
            if member is None:
                raise ValueError(f"missing index.json in {archive_path}")
            index = json.load(member)
        manifests = index.get("manifests") if isinstance(index, dict) else None
        if not isinstance(manifests, list) or not manifests or not isinstance(manifests[0], dict):
            raise ValueError(f"invalid index.json in {archive_path}")
        digest = manifests[0].get("digest")
        if not isinstance(digest, str) or not _OCI_DIGEST_RE.fullmatch(digest):
            raise ValueError(f"invalid OCI digest in {archive_path}")
        return digest


class StateCli:
    @staticmethod
    def run(argv: Sequence[str] | None = None) -> int:
        parser = argparse.ArgumentParser()
        subparsers = parser.add_subparsers(dest="command", required=True)

        key_parser = subparsers.add_parser("key")
        key_parser.add_argument("--value", action="append", default=[])
        key_parser.add_argument("--path", action="append", default=[])
        key_parser.add_argument("--exclude", action="append", default=[])

        tree_parser = subparsers.add_parser("build-tree")
        tree_parser.add_argument("board", type=Path)

        digest_parser = subparsers.add_parser("oci-digest")
        digest_parser.add_argument("archive", type=Path)

        for name in ("check", "save"):
            cmd_parser = subparsers.add_parser(name)
            cmd_parser.add_argument("state", type=Path)
            cmd_parser.add_argument("--key", required=True)
            cmd_parser.add_argument("--path", action="append", default=[])
            cmd_parser.add_argument("--metadata-path", action="append", default=[])

        args = parser.parse_args(argv)
        if args.command in ("check", "save") and not (args.path or args.metadata_path):
            parser.error(f"{args.command} requires at least one --path or --metadata-path")
        try:
            if args.command == "key":
                print(BuildState.fingerprint(args.path, args.value, args.exclude))
            elif args.command == "build-tree":
                print(BuildState.build_tree_key(args.board))
            elif args.command == "oci-digest":
                print(BuildState.oci_archive_digest(args.archive))
            elif args.command == "save":
                BuildState.save(args.state, args.key, args.path, args.metadata_path)
            else:
                return 0 if BuildState.check(
                    args.state, args.key, args.path, args.metadata_path
                ) else 1
        except (OSError, ValueError, tarfile.TarError, json.JSONDecodeError) as error:
            print(f"state: {error}", file=sys.stderr)
            return 2
        return 0


if __name__ == "__main__":
    raise SystemExit(StateCli.run())
