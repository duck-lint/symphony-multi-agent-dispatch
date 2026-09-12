# SYMPHONY multi-agent dispatch

This repository is a clean upstream-based rebuild of SYMPHONY. It is not a comprehensive product guide.

Read [AGENTS.md](AGENTS.md) for repository authority and change boundaries, and
[the MVP invariants](harness/SYMPHONY-multi-agent-dispatch_MVP_INVARIANTS.md) for the intended lifecycle
and rebuild guardrails.

Project-local `.symphony/instance_config.yml` binds/configures one project-scoped runtime instance only. It does
not define the shared lifecycle, role behavior, or lifecycle authority. The shared multi-role lifecycle
is SYMPHONY behavior structurally enforced by host code; dispatched agents use the target repository's
applicable `AGENTS.md`, harness, and source context.

The current host includes the pure lifecycle/role kernel, SYMPHONY-owned role profiles, and
host-enforced role runtime authority. GitHub lifecycle transition persistence remains a separate
lifecycle seam.

## Linux validation from Windows

When direct Codex-to-WSL execution is unavailable, run Mix through the bounded
developer bridge:

```powershell
python scripts/wsl_validation.py --cwd F:\\PROJECT-REPOS\\symphony-multi-agent-dispatch\\elixir -- mix test
```

The bridge authorizes only this Windows checkout, archives the current working
tree (including uncommitted edits) into a disposable native WSL directory
under `/home/duck-lint`, maps the requested cwd by repository-relative path,
uses Ubuntu-24.04 as `duck-lint`, and launches the declared `mise` toolchain
with a sterile environment. It is validation tooling only; it does not own
lifecycle state or create a second authoritative source checkout.
