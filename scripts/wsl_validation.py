#!/usr/bin/env python3
"""Run bounded Linux validation against this Windows checkout.

This is developer tooling only.  It does not schedule work, own lifecycle
state, or provide a general Windows-to-WSL command broker.  The authorized
checkout and WSL identity are deliberately fixed so validation cannot drift
onto a second SYMPHONY source tree.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
from typing import Sequence


AUTHORIZED_WINDOWS_ROOT = Path(r"F:\PROJECT-REPOS\symphony-multi-agent-dispatch")
WSL_DISTRIBUTION = "Ubuntu-24.04"
WSL_USER = "duck-lint"
MAX_TIMEOUT_SECONDS = 60 * 60
PATH_RESOLUTION_TIMEOUT_SECONDS = 60
MAX_OUTPUT_BYTES = 4 * 1024 * 1024
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
) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            [str(wsl), "--distribution", WSL_DISTRIBUTION, "--user", WSL_USER, *arguments],
            stdin=subprocess.DEVNULL,
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


def _canonical_wsl_path(wsl: Path, windows_path: Path, *, purpose: str) -> str:
    converted = _single_line_output(
        _run_wsl(
            wsl,
            ["--exec", "/usr/bin/wslpath", "-a", "-u", str(windows_path)],
            timeout_seconds=PATH_RESOLUTION_TIMEOUT_SECONDS,
        ),
        f"{purpose} Windows-to-WSL resolution",
    )
    return _single_line_output(
        _run_wsl(
            wsl,
            ["--exec", "/usr/bin/readlink", "-e", "--", converted],
            timeout_seconds=PATH_RESOLUTION_TIMEOUT_SECONDS,
        ),
        f"{purpose} canonicalization",
    )


def _authorized_root(wsl: Path) -> tuple[Path, str]:
    repository_root = Path(__file__).resolve().parents[1]
    if repository_root != AUTHORIZED_WINDOWS_ROOT.resolve():
        raise ValidationBridgeError(
            "the bridge must run from the authorized Windows checkout "
            f"{AUTHORIZED_WINDOWS_ROOT}"
        )
    if not (repository_root / ".git").exists() or not (repository_root / "elixir" / "mix.exs").is_file():
        raise ValidationBridgeError("the authorized checkout is not a SYMPHONY source checkout")
    return repository_root, _canonical_wsl_path(wsl, repository_root, purpose="repository cwd")


def _authorized_cwd(wsl: Path, repository_root: Path, repository_wsl_root: str, cwd: str) -> str:
    requested = Path(cwd).resolve() if cwd else repository_root
    try:
        requested.relative_to(repository_root)
    except ValueError as exc:
        raise ValidationBridgeError("cwd is outside the authorized SYMPHONY checkout") from exc
    canonical = _canonical_wsl_path(wsl, requested, purpose="requested cwd")
    if canonical != repository_wsl_root and not canonical.startswith(repository_wsl_root + "/"):
        raise ValidationBridgeError("canonical cwd leaves the authorized SYMPHONY checkout")
    return canonical


def _validate_command(command: Sequence[str]) -> tuple[str, ...]:
    if not command or isinstance(command, (str, bytes)):
        raise ValidationBridgeError("a Linux command is required after --")
    executable = Path(command[0]).name
    if executable not in ALLOWED_COMMANDS or Path(command[0]).name != command[0]:
        raise ValidationBridgeError(f"command is outside the validation allowlist: {command[0]}")
    if any("\x00" in argument for argument in command):
        raise ValidationBridgeError("command contains a NUL byte")
    return tuple(command)


def execute(cwd: str, command: Sequence[str], *, timeout_seconds: float = 30 * 60) -> int:
    if not 0 < timeout_seconds <= MAX_TIMEOUT_SECONDS:
        raise ValidationBridgeError("timeout is outside the bounded bridge range")
    wsl = _wsl_executable()
    repository_root, repository_wsl_root = _authorized_root(wsl)
    resolved_cwd = _authorized_cwd(wsl, repository_root, repository_wsl_root, cwd)
    validated_command = _validate_command(command)

    # mise is the project's declared toolchain mechanism.  The sterile Linux
    # environment keeps tracker credentials and inherited WSL configuration
    # out of the child while retaining only the toolchain bootstrap paths.
    arguments = [
        "--cd",
        resolved_cwd,
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
        *validated_command,
    ]
    result = _run_wsl(wsl, arguments, timeout_seconds=timeout_seconds)
    # Write UTF-8 bytes so Windows' legacy console code page cannot make the
    # bridge fail while forwarding Credo or Mix diagnostics.
    sys.stdout.buffer.write(_decode_output(result.stdout).encode("utf-8"))
    sys.stderr.buffer.write(_decode_output(result.stderr).encode("utf-8"))
    sys.stdout.flush()
    sys.stderr.flush()
    return result.returncode


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
