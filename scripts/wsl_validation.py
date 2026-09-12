#!/usr/bin/env python3
"""Run bounded Linux validation against this Windows checkout.

This is developer tooling only.  It does not schedule work, own lifecycle
state, or provide a general Windows-to-WSL command broker.  The authorized
checkout and WSL identity are deliberately fixed so validation cannot drift
onto a second SYMPHONY source tree.
"""

from __future__ import annotations

import argparse
import io
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tarfile
from typing import Sequence


AUTHORIZED_WINDOWS_ROOT = Path(r"F:\PROJECT-REPOS\symphony-multi-agent-dispatch")
WSL_DISTRIBUTION = "Ubuntu-24.04"
WSL_USER = "duck-lint"
MAX_TIMEOUT_SECONDS = 60 * 60
PATH_RESOLUTION_TIMEOUT_SECONDS = 60
MAX_OUTPUT_BYTES = 4 * 1024 * 1024
MAX_STAGING_ARCHIVE_BYTES = 128 * 1024 * 1024
NATIVE_STAGING_PARENT = "/home/duck-lint"
NATIVE_STAGING_PREFIX = ".symphony-validation-"
ALLOWED_COMMANDS = frozenset(
    {
        "elixir",
        "erl",
        "find",
        "git",
        "make",
        "mise",
        "mix",
        "pwd",
        "rg",
        "test",
        "which",
    }
)


class ValidationBridgeError(RuntimeError):
    """A fail-closed bridge validation or transport error."""


def _wsl_executable() -> Path:
    system_root = Path(os.environ.get("SystemRoot", r"C:\Windows"))
    executable = (system_root / "System32" / "wsl.exe").resolve()
    if not executable.is_file():
        raise ValidationBridgeError(f"fixed WSL executable is unavailable: {executable}")
    return executable


def _wsl_environment() -> dict[str, str]:
    """Keep Windows credentials and WSLENV out of the WSL process boundary."""
    system_root = os.environ.get("SystemRoot", r"C:\Windows")
    return {"SystemRoot": system_root, "WINDIR": system_root}


def _run_wsl(
    wsl: Path,
    arguments: Sequence[str],
    *,
    timeout_seconds: float,
    input_data: bytes | None = None,
) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            [str(wsl), "--distribution", WSL_DISTRIBUTION, "--user", WSL_USER, *arguments],
            input=input_data,
            stdin=subprocess.DEVNULL if input_data is None else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_wsl_environment(),
            shell=False,
            timeout=timeout_seconds,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ValidationBridgeError("the bounded WSL transport failed") from exc


def _decode_output(raw: bytes) -> str:
    if len(raw) > MAX_OUTPUT_BYTES:
        raise ValidationBridgeError("WSL output exceeded the bounded bridge limit")
    return raw.decode("utf-8", errors="replace").replace("\x00", "")


def _single_line_output(result: subprocess.CompletedProcess[bytes], purpose: str) -> str:
    if result.returncode != 0:
        raise ValidationBridgeError(f"{purpose} failed")
    lines = _decode_output(result.stdout).strip().splitlines()
    if len(lines) != 1 or not lines[0].startswith("/"):
        raise ValidationBridgeError(f"{purpose} returned malformed path evidence")
    return lines[0]


def _authorized_root() -> Path:
    repository_root = Path(__file__).resolve().parents[1]
    if repository_root != AUTHORIZED_WINDOWS_ROOT.resolve():
        raise ValidationBridgeError(
            "the bridge must run from the authorized Windows checkout "
            f"{AUTHORIZED_WINDOWS_ROOT}"
        )
    if not (repository_root / ".git").exists() or not (repository_root / "elixir" / "mix.exs").is_file():
        raise ValidationBridgeError("the authorized checkout is not a SYMPHONY source checkout")
    return repository_root


def _authorized_cwd(repository_root: Path, cwd: str) -> Path:
    requested = Path(cwd).resolve() if cwd else repository_root
    try:
        requested.relative_to(repository_root)
    except ValueError as exc:
        raise ValidationBridgeError("cwd is outside the authorized SYMPHONY checkout") from exc
    if not requested.is_dir():
        raise ValidationBridgeError("cwd is not an existing directory in the authorized checkout")
    return requested


def _relative_cwd(repository_root: Path, requested_cwd: Path) -> str:
    relative = requested_cwd.relative_to(repository_root)
    return "" if relative == Path(".") else relative.as_posix()


def _excluded_from_staging(relative_path: Path) -> bool:
    parts = relative_path.parts
    if not parts:
        return False
    if parts[0] == ".git":
        return True
    return len(parts) >= 2 and parts[:2] in {
        ("elixir", "_build"),
        ("elixir", "cover"),
        ("elixir", "deps"),
        ("elixir", "bin"),
        ("elixir", "log"),
        ("elixir", "logs"),
        ("elixir", "tmp"),
    }


def _working_tree_archive(repository_root: Path) -> bytes:
    """Archive current filesystem content, including edits not present in HEAD.

    Git metadata and generated validation output are deliberately omitted.  The
    staged tree is disposable source material, not a second authoritative
    checkout, and Mix will recreate its own dependencies and build artifacts.
    """
    archive_buffer = io.BytesIO()
    with tarfile.open(fileobj=archive_buffer, mode="w:gz") as archive:
        for root, directory_names, file_names in os.walk(repository_root, topdown=True, followlinks=False):
            root_path = Path(root)
            root_relative = root_path.relative_to(repository_root)
            directory_names[:] = sorted(
                name
                for name in directory_names
                if not _excluded_from_staging(root_relative / name)
            )
            for name in sorted(file_names):
                file_path = root_path / name
                relative_path = file_path.relative_to(repository_root)
                if _excluded_from_staging(relative_path):
                    continue
                archive.add(file_path, arcname=relative_path.as_posix(), recursive=False)
                if archive_buffer.tell() > MAX_STAGING_ARCHIVE_BYTES:
                    raise ValidationBridgeError("current working tree exceeds the staging archive limit")
    return archive_buffer.getvalue()


def _validate_native_staging_root(staging_root: str) -> str:
    candidate = PurePosixPath(staging_root)
    if (
        candidate.parent.as_posix() != NATIVE_STAGING_PARENT
        or not candidate.name.startswith(NATIVE_STAGING_PREFIX)
        or len(candidate.name) <= len(NATIVE_STAGING_PREFIX)
    ):
        raise ValidationBridgeError("WSL returned an invalid disposable staging path")
    return candidate.as_posix()


def _create_native_staging_root(wsl: Path) -> str:
    result = _run_wsl(
        wsl,
        [
            "--exec",
            "/usr/bin/mktemp",
            "-d",
            "-p",
            NATIVE_STAGING_PARENT,
            NATIVE_STAGING_PREFIX + "XXXXXX",
        ],
        timeout_seconds=PATH_RESOLUTION_TIMEOUT_SECONDS,
    )
    return _validate_native_staging_root(_single_line_output(result, "native staging directory creation"))


def _extract_working_tree(wsl: Path, staging_root: str, archive_data: bytes) -> None:
    result = _run_wsl(
        wsl,
        ["--cd", staging_root, "--exec", "/usr/bin/tar", "-xzf", "-"],
        timeout_seconds=PATH_RESOLUTION_TIMEOUT_SECONDS,
        input_data=archive_data,
    )
    if result.returncode != 0:
        raise ValidationBridgeError("disposable WSL-native staging extraction failed")


def _cleanup_native_staging(wsl: Path, staging_root: str) -> None:
    staging_root = _validate_native_staging_root(staging_root)
    result = _run_wsl(
        wsl,
        ["--exec", "/usr/bin/rm", "-rf", "--", staging_root],
        timeout_seconds=PATH_RESOLUTION_TIMEOUT_SECONDS,
    )
    if result.returncode != 0:
        raise ValidationBridgeError("disposable WSL-native staging cleanup failed")


def _staged_cwd(staging_root: str, relative_cwd: str) -> str:
    return PurePosixPath(staging_root, relative_cwd).as_posix() if relative_cwd else staging_root


def _validate_command(command: Sequence[str]) -> tuple[str, ...]:
    if not command or isinstance(command, (str, bytes)):
        raise ValidationBridgeError("a Linux command is required after --")
    executable = Path(command[0]).name
    if executable not in ALLOWED_COMMANDS or Path(command[0]).name != command[0]:
        raise ValidationBridgeError(f"command is outside the validation allowlist: {command[0]}")
    if any("\x00" in argument for argument in command):
        raise ValidationBridgeError("command contains a NUL byte")
    return tuple(command)


def _validation_arguments(staged_cwd: str, command: Sequence[str]) -> list[str]:
    return [
        "--cd",
        staged_cwd,
        "--exec",
        "/usr/bin/env",
        "-i",
        "HOME=/home/duck-lint",
        "USER=duck-lint",
        "LOGNAME=duck-lint",
        "PATH=/home/duck-lint/.local/bin:/usr/bin:/bin",
        "LANG=C.UTF-8",
        "LC_ALL=C.UTF-8",
        "/home/duck-lint/.local/bin/mise",
        "exec",
        "--",
        *command,
    ]


def execute(cwd: str, command: Sequence[str], *, timeout_seconds: float = 30 * 60) -> int:
    if not 0 < timeout_seconds <= MAX_TIMEOUT_SECONDS:
        raise ValidationBridgeError("timeout is outside the bounded bridge range")
    wsl = _wsl_executable()
    repository_root = _authorized_root()
    requested_cwd = _authorized_cwd(repository_root, cwd)
    validated_command = _validate_command(command)
    archive_data = _working_tree_archive(repository_root)
    relative_cwd = _relative_cwd(repository_root, requested_cwd)
    staging_root = _create_native_staging_root(wsl)
    try:
        _extract_working_tree(wsl, staging_root, archive_data)
        # mise is the project's declared toolchain mechanism.  The sterile
        # Linux environment keeps tracker credentials and inherited WSL
        # configuration out of the child while retaining only toolchain paths.
        result = _run_wsl(
            wsl,
            _validation_arguments(_staged_cwd(staging_root, relative_cwd), validated_command),
            timeout_seconds=timeout_seconds,
        )
        # Write UTF-8 bytes so Windows' legacy console code page cannot make
        # the bridge fail while forwarding Credo or Mix diagnostics.
        sys.stdout.buffer.write(_decode_output(result.stdout).encode("utf-8"))
        sys.stderr.buffer.write(_decode_output(result.stderr).encode("utf-8"))
        sys.stdout.flush()
        sys.stderr.flush()
        return result.returncode
    finally:
        _cleanup_native_staging(wsl, staging_root)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--cwd",
        default=str(AUTHORIZED_WINDOWS_ROOT),
        help="Windows cwd inside the authorized checkout (default: repository root)",
    )
    parser.add_argument("--timeout-seconds", type=float, default=30 * 60)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    command = list(args.command)
    if command[:1] == ["--"]:
        command = command[1:]
    try:
        return execute(args.cwd, command, timeout_seconds=args.timeout_seconds)
    except ValidationBridgeError as exc:
        print(f"SYMPHONY WSL validation bridge stopped: {exc}", file=sys.stderr)
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
