from __future__ import annotations

import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import wsl_validation


class WslValidationTests(unittest.TestCase):
    def test_archive_contains_current_working_tree_content_not_just_head(self):
        with tempfile.TemporaryDirectory() as directory:
            repository_root = Path(directory)
            (repository_root / ".git").mkdir()
            (repository_root / "elixir").mkdir()
            (repository_root / "elixir" / "mix.exs").write_bytes(b"HEAD content\n")
            uncommitted_file = repository_root / "elixir" / "uncommitted.ex"
            uncommitted_file.write_bytes(b"current working tree content\n")
            (repository_root / "elixir" / "_build").mkdir()
            (repository_root / "elixir" / "_build" / "stale.beam").write_bytes(b"generated")

            archive_data = wsl_validation._working_tree_archive(repository_root)
            with tarfile.open(fileobj=io.BytesIO(archive_data), mode="r:gz") as archive:
                names = set(archive.getnames())
                self.assertIn("elixir/uncommitted.ex", names)
                self.assertEqual(archive.extractfile("elixir/uncommitted.ex").read(), b"current working tree content\n")
                self.assertNotIn(".git", " ".join(names))
                self.assertNotIn("elixir/_build/stale.beam", names)

    def test_execution_maps_cwd_into_native_staging_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            repository_root = Path(directory)
            (repository_root / ".git").mkdir()
            (repository_root / "elixir").mkdir()
            (repository_root / "elixir" / "mix.exs").write_bytes(b"project\n")
            staged_root = "/home/duck-lint/.symphony-validation-abc123"
            completed = wsl_validation.subprocess.CompletedProcess([], 0, b"", b"")

            with mock.patch.object(wsl_validation, "_wsl_executable", return_value=Path("wsl.exe")), \
                mock.patch.object(wsl_validation, "_authorized_root", return_value=repository_root), \
                mock.patch.object(wsl_validation, "_working_tree_archive", return_value=b"archive"), \
                mock.patch.object(wsl_validation, "_create_native_staging_root", return_value=staged_root), \
                mock.patch.object(wsl_validation, "_extract_working_tree") as extract, \
                mock.patch.object(wsl_validation, "_cleanup_native_staging") as cleanup, \
                mock.patch.object(wsl_validation, "_run_wsl", return_value=completed) as run_wsl:
                self.assertEqual(wsl_validation.execute(str(repository_root / "elixir"), ["pwd"], timeout_seconds=1), 0)

            extract.assert_called_once_with(Path("wsl.exe"), staged_root, b"archive")
            cleanup.assert_called_once_with(Path("wsl.exe"), staged_root)
            validation_arguments = run_wsl.call_args.args[1]
            self.assertEqual(validation_arguments[0:2], ["--cd", staged_root + "/elixir"])
            self.assertNotIn("/mnt/f", validation_arguments)

    def test_cwd_containment_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            repository_root = Path(directory) / "repository"
            outside = Path(directory) / "outside"
            repository_root.mkdir()
            outside.mkdir()
            with self.assertRaisesRegex(wsl_validation.ValidationBridgeError, "outside"):
                wsl_validation._authorized_cwd(repository_root, str(outside))

    def test_windows_credentials_and_tracker_secrets_are_excluded(self):
        with mock.patch.dict(
            wsl_validation.os.environ,
            {
                "SystemRoot": r"C:\Windows",
                "GITHUB_TOKEN": "secret",
                "GH_TOKEN": "secret",
                "GITHUB_ENTERPRISE_TOKEN": "secret",
                "GH_ENTERPRISE_TOKEN": "secret",
            },
            clear=True,
        ):
            self.assertEqual(
                wsl_validation._wsl_environment(),
                {"SystemRoot": r"C:\Windows", "WINDIR": r"C:\Windows"},
            )
        arguments = wsl_validation._validation_arguments(
            "/home/duck-lint/.symphony-validation-test/elixir", ["mix", "test"]
        )
        self.assertNotIn("GITHUB_TOKEN", arguments)
        self.assertNotIn("GH_TOKEN", arguments)
        self.assertNotIn("GITHUB_ENTERPRISE_TOKEN", arguments)
        self.assertNotIn("GH_ENTERPRISE_TOKEN", arguments)

    def test_existing_allowed_validation_commands_remain_allowed(self):
        for command in sorted(wsl_validation.ALLOWED_COMMANDS):
            with self.subTest(command=command):
                self.assertEqual(wsl_validation._validate_command([command]), (command,))


if __name__ == "__main__":
    unittest.main(verbosity=2)
