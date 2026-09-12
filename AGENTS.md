# AGENTS.md

## Purpose

This repository is a clean upstream-based rebuild of SYMPHONY.

The primary product invariant is:

> **The human must not be the routine transition function between coding-agent roles.**

Prefer the smallest coherent change to upstream Symphony that makes the required lifecycle autonomous. Do not recreate the abandoned Pilot/SQLite architecture unless a later explicit decision requires it.

## Authority

Use this order when sources disagree:

1. This `AGENTS.md`
2. `harness/SYMPHONY-multi-agent-dispatch_MVP_INVARIANTS.md`
3. Explicit current task instructions from the human
4. Current implementation evidence
5. `DONOR-*` documents and upstream history as reference only

Files prefixed `DONOR-` describe the inherited upstream system. They are **not current product authority**. Do not make new code conform to donor semantics merely because those documents are detailed.

If current authority is insufficient to choose between materially different product meanings, stop and surface the semantic decision instead of silently choosing one.

## Current lifecycle invariant

One GitHub Issue remains the task/scheduling/workspace identity.

The intended lifecycle is:

```text
PM
→ fresh Planner
→ fresh Reviewer
   ↳ correction → fresh Planner → fresh Reviewer
→ fresh Implementer
→ fresh Adversary
→ same task-scoped PM
   ↳ not converged → another working round
   ↳ converged → fresh Archivist
→ terminal lifecycle state
```

There is no Architect role.

Specialists are fresh executions. PM alone has task-scoped reasoning continuity.

The initial PM must route through Planner; it may not skip directly to Archivist. PM convergence is legal only after at least one complete Implementer → Adversary → PM cycle and no blocking findings in the immediately preceding Adversary result.

Models report structured role outcomes. They do not choose arbitrary next roles. Host code validates the result and maps it onto the legal lifecycle transition.

## Frozen MVP lifecycle state model

For MVP, lifecycle authority is intentionally small:

- GitHub role/state labels are the current lifecycle projection.
- Append-only host-written GitHub comments are the durable lifecycle history and handoff log.
- Lifecycle comments use deterministic transition IDs so retries are idempotent.
- Planning-attempt and working-round budgets are reconstructed from accepted lifecycle history; infrastructure retries do not consume those budgets.
- PM thread identity is stored in host-owned local state outside the issue workspace and supports same-machine restart continuity.
- There is no lifecycle SQLite database or mutable lifecycle mega-record.

The benchmark limits are 3 Planner/Reviewer attempts per round and 8 working rounds per lifecycle. Budget exhaustion produces `symphony:state:non-converged`; it is not task success and does not close the issue.

A successful Archivist closeout produces `symphony:state:lifecycle-complete`, removes automation/role labels, leaves the issue open, and leaves the workspace available for later human-authorized disposition/publication.

## Role authority

Role boundaries must be enforced structurally, not by prompt wording alone.

For MVP:

```text
PM           read-only project access
Planner      read-only project access
Reviewer     read-only project access
Implementer  bounded project-workspace write access
Adversary    read-only project access
Archivist    read-only project access
```

Only Implementer writes project files. Implementer must not mutate `.git`, stage, commit, switch branches, reset, merge, push, or publish. Read-only Git inspection is allowed.

The host also performs no automatic commit, push, PR creation, merge, or publication as part of the lifecycle MVP.

Models receive no GitHub mutation capability for MVP. Host lifecycle code alone may perform the bounded current-issue operations required to read state/history, append lifecycle comments, and add/remove SYMPHONY lifecycle labels. Do not expose a generic host-authenticated tracker write surface to role agents.

Human escalation is exceptional. Normal revision, adversarial findings, failed tests, difficult implementation, budget exhaustion, and retryable infrastructure failures are not reasons to hand routine routing back to the human.

## Preserve upstream unless required otherwise

Treat these as valuable stock Symphony surfaces:

- tracker polling and issue refresh;
- one issue claim identity;
- per-issue workspace reuse;
- worker supervision;
- retry/backoff and reconciliation;
- Codex App Server transport;
- terminal-issue cleanup;
- observability foundations.

Do not widen a change merely to make the architecture feel cleaner.

Before changing an upstream seam, ask:

> Does this directly help one issue progress through the required role lifecycle without human routing?

If not, leave it alone unless required for safety.

## Project-scoped deployment model

SYMPHONY is one reusable orchestration implementation that can be used across arbitrary target repositories without source-code modification.

Each running Symphony instance is scoped to one target project through that project's project-local `.symphony/instance_config.yml`. This file binds/configures one project-scoped runtime instance only; it does not define the shared lifecycle, a PM profile, a role prompt, or lifecycle authority.

The shared multi-role lifecycle belongs to SYMPHONY and is structurally enforced by host code, not expressed as project-specific prompt prose. Dispatched agents read the target repository's applicable `AGENTS.md`, harness, and source context; the orchestrator does not need to reason about that project's domain.

Multiple project-scoped Symphony instances may run concurrently. They remain independent scheduling domains with separate tracker scopes, claim maps, workspaces, and runtime state.

MVP does **not** require one orchestrator to multiplex multiple target projects internally, a central project registry, or a scheduler-of-schedulers.

Project onboarding should be configuration/bootstrap work, not a new source-code integration.

## Recovery boundary

Lifecycle recovery is reconstructed from GitHub labels plus the append-only lifecycle event log. Host-local PM metadata is used only for PM thread continuity.

Important invariants:

- a crashed specialist reruns fresh in the same role without consuming lifecycle budget;
- a crashed PM resumes the same PM thread without consuming lifecycle budget;
- a durable transition comment with a stale old role label is completed idempotently by the host;
- a new-role label without its matching durable handoff is invalid/corrupt state and must block visibly rather than invent missing history;
- an unavailable required PM thread must block visibly and must never be silently replaced.

Persist durable handoff/history **before** mutating the role label.

## WSL and adapter boundary

There is a known VS Code Codex → direct WSL access failure (`E_ACCESSDENIED`) in this environment.

When Linux-side inspection/build/test work is required, use the established Windows-host → WSL adapter pattern from the parked `symphony-pilot` repository, or a minimal extracted equivalent.

The adapter is **developer/tooling infrastructure only**. It is not lifecycle authority and must not become a new control plane.

Do not respond to the known direct-WSL bug by reinstalling/rebuilding WSL or redesigning the product.

There must be one authoritative SYMPHONY source checkout. WSL may contain an installed/built Symphony runtime, logs, caches, host-owned state, and project/issue workspaces, but not a second independently authoritative SYMPHONY source repository.

Old SYMPHONY-specific WSL state may be removed only after producing an explicit deletion manifest. Preserve unrelated WSL state, Codex auth/install, Git config, and unrelated projects/tools.

## Donor review rules

For documentation/reconciliation work, classify inherited material as:

- `PRESERVE STOCK`
- `ADAPT TO MVP`
- `DELETE AS DONOR-SPECIFIC`
- `UNDECIDED — REQUIRES SEMANTIC DECISION`

Do not implement while performing a donor-doc review unless the task explicitly authorizes implementation.

Pay special attention to hidden architectural assumptions in apparently operational documentation: scheduling identity, workspace identity, tracker scope, instance-config scope, thread lifetime, retry ownership, project selection, and mutation authority.

## Change discipline

- Prefer narrow extensions over rewrites.
- Do not import scheduling/control-plane code from parked custom Pilot/Runtime branches.
- Do not preserve legacy behavior for compatibility's sake; this product has not launched.
- Do not introduce SQLite, a scheduler-of-schedulers, centralized multi-project control plane, publication automation, or internal multi-project multiplexing without explicit authority. Independent project-scoped runtime instances are allowed.
- Do not add a model-owned lifecycle transition mechanism or generic tracker-write escape hatch.
- Do not perform unrelated refactors.
- Do not use destructive Git operations (`reset`, `clean`, force push, ref rewrites, destructive checkout) without explicit human approval and stated consequences.
- Do not ask the human to manually inspect giant diffs or ferry routine prompts between agents.
- Surface human decisions only when they change product meaning, authority, or safety.

## Implementation validation

When implementation is authorized:

1. prove the smallest changed seam with focused tests;
2. prove role/write/tracker authority with executable boundaries, not prompt assertions;
3. verify adjacent retry/reconciliation/restart behavior when stateful code changes;
4. run the relevant broader project gate before handoff;
5. report the exact changed files/functions, evidence, and any remaining semantic uncertainty.

A technically passing implementation that violates the lifecycle invariant is not acceptable.

## Commits

Push commits when complete.
