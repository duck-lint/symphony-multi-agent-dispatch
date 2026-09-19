# Contributing

This is an experimental upstream-derived project. Before proposing changes, read [AGENTS.md](AGENTS.md) and the [MVP invariants](harness/SYMPHONY-multi-agent-dispatch_MVP_INVARIANTS.md). Those documents define project authority; the README is an introduction, not an override.

For a bug, provide the observed behavior, expected behavior, reproduction or relevant lifecycle transition IDs, and the smallest evidence-backed explanation. Distinguish a host enforcement defect from an unproven model judgment or a proposed product-design change. Redact tokens, local paths containing secrets, and sensitive issue contents.

For a pull request, identify its authorized scope, affected and non-affected surfaces, tests, and any remaining runtime-evidence gaps. Run the relevant checks from `elixir/` (`make all` for the repository gate) and describe checks that could not be run. Changes to lifecycle meaning, task authority, tracker permissions, persistence, or deployment require explicit design approval; do not silently broaden them.

Use [SECURITY.md](SECURITY.md) for vulnerabilities rather than posting sensitive details in public issues. Contributions are reviewed at the maintainer's discretion; submission does not imply an SLA or a commitment to adopt the proposal.
