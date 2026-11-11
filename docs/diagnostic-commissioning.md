# Diagnostic commissioning

The \`symphony lab\` command family tests project-specific workspace readiness **without starting the production polling orchestrator**. It does not create GitHub issues, dispatch Codex agents, write lifecycle ledger events, change labels, or persist PM threads.

This is the first diagnostic slice: configuration checking, workspace provisioning, role-bound environment verification, and explicit cleanup. It does **not** run an agent turn, simulate a lifecycle, or provide an interactive agent sandbox.

## Usage

Select the same host-loaded instance configuration that the production executable would use. If \`--config\` is omitted, the default is \`.symphony/instance_config.yml\` relative to the working directory.

\`\`\`bash
symphony lab check --config /path/to/project/.symphony/instance_config.yml

symphony lab provision --run onboarding-a \
  --config /path/to/project/.symphony/instance_config.yml \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails

symphony lab verify --run onboarding-a --role implementer \
  --config /path/to/project/.symphony/instance_config.yml \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails

symphony lab destroy --run onboarding-a \
  --config /path/to/project/.symphony/instance_config.yml \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
\`\`\`

Use the emitted \`workspace\` path to inspect the result with normal operator tools; \`lab shell\` and role-specific Codex probes are **not implemented**. For remote workers, inspect that path on the selected remote host.

A \`--run\` name is a unique, operator-chosen identity, not a GitHub issue identifier. It must have 1–64 ASCII letters, digits, hyphens, or underscores and start with a letter or digit. The workspace is created under the selected instance's \`workspace.root/.symphony-diagnostics/<run>\` directory. An existing run is not overwritten. Use \`destroy\` explicitly before reprovisioning. Production issue workspaces cannot use the reserved diagnostic namespace.

When \`worker.ssh_hosts\` contains one host, the lab selects it; when several hosts are configured, pass \`--worker <configured-host>\`. Without configured SSH hosts the lab uses the local host. These are the actual workspace preparation and role-policy execution surfaces, not simulated checks.

## What each operation establishes

- \`check\`: parses and validates the selected instance configuration and tracker settings. It does not verify the remote tracker, workspace provenance, GitHub labels, Codex authentication, or declared environment capabilities.
- \`provision\`: uses the production workspace materialization implementation, including \`after_create\` for a new diagnostic workspace. It preserves the resulting workspace for inspection.
- \`verify\`: uses the same role policy, workspace-boundary enforcement, \`before_run\`, source-provenance verification, and declared capability checks as production dispatch. It also runs \`after_run\` on the same preparation/attempt boundary. A failure is not reported as success. The role policy is enforced during preparation; no Codex session is started.
- \`destroy\`: removes the named diagnostic workspace through the production cleanup mechanisms, including \`before_remove\` where configured. For remote Implementer checks it also cleans the diagnostic workspace's externally protected Git metadata when its pointer matches the expected location.

\`verified\` is time-bound host evidence, not evidence that a Codex agent can access a command inside its actual sandbox. Agent-level probes, lifecycle handoffs, and returning PM continuity are outside this slice.

## Authority and safety

The CLI chooses a **different startup path** from normal \`symphony\`. The normal lifecycle remains GitHub-driven; the diagnostic caller cannot route agents or publish lifecycle results. The shared preparation implementation is used by production \`AgentRunner\`, rather than a duplicated diagnostic implementation.

Provisioning and hooks can execute arbitrary project-declared commands and can affect external systems. The diagnostic workspace name does not sandbox a hook or an external CLI. Run only in a trusted operator-controlled environment, with credentials kept outside the target repository. A human shell in the diagnostic workspace would not itself establish agent-level reachability.

\`verify\` does not recreate the workspace or rerun \`after_create\`; if the project configuration or branch changes, destroy and reprovision a fresh run rather than silently mutating an existing workspace.

The first PR requires separate runtime acceptance evidence on actual local and, when applicable, remote worker substrates; synthetic unit tests alone cannot establish live environment parity.
