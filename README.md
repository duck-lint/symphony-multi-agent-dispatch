# SYMPHONY multi-agent dispatch

This repository is a clean upstream-based rebuild of SYMPHONY. It is currently a pre-implementation
project contract, not a comprehensive product guide.

Read [AGENTS.md](AGENTS.md) for repository authority and change boundaries, and
[the MVP invariants](harness/SYMPHONY-multi-agent-dispatch_MVP_INVARIANTS.md) for the intended lifecycle
and rebuild guardrails.

Project-local `instance_config.yml` binds/configures one project-scoped runtime instance only. It does
not define the shared lifecycle, role behavior, or lifecycle authority. The shared multi-role lifecycle
is SYMPHONY behavior structurally enforced by host code; dispatched agents use the target repository's
applicable `AGENTS.md`, harness, and source context.
