# Development and packaging

These are maintainer/developer instructions for the current operator-run build, not a guarantee that downloadable binaries exist or work on every declared target. For executable provenance and runtime acceptance requirements, consult [current runtime state](current-state.md).

## Linux validation from Windows

When direct Codex-to-WSL execution is unavailable, the repository's bounded development bridge can run Mix from the authorized Windows checkout:

```powershell
python scripts/wsl_validation.py --cwd F:\\PROJECT-REPOS\\symphony-multi-agent-dispatch\\elixir -- mix test
```

**This path is the maintainer's configured checkout, not a portable example.** The bridge authorizes that checkout, archives the current working tree (including uncommitted edits) to a disposable WSL-native directory under `/home/duck-lint`, maps the working directory by repo-relative path, selects Ubuntu-24.04 and the declared mise toolchain, and uses a sterile environment. It is validation tooling only; it neither owns lifecycle state nor creates a second authoritative source checkout.

## Ubuntu/WSL Burrito build

Install the Ubuntu packaging dependency and repo-declared toolchain:

```bash
sudo apt-get update
sudo apt-get install -y xz-utils
mise install
```

From `elixir/` in a **clean source snapshot of an exact committed revision**, build with:

```bash
SYMPHONY_BUILD_REVISION="<40-character committed Git SHA>" \
  BURRITO_TARGET=linux_x86_64 MIX_ENV=prod \
  mise exec -- mix release symphony --overwrite
```

The 40-character SHA must identify the source snapshot. The production build rejects missing or malformed revision values. The repo declares Zig 0.15.2; do not substitute an unverified toolchain. Install under a revision-scoped location and check both the embedded release revision and extracted Burrito payload identity before launch. Never reuse an extracted payload from another revision.

The GitHub release workflow needs its version/revision/build contract repaired and demonstrated before binaries are presented as downloadable releases. This development procedure is separate from release automation.
