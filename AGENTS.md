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

Models may propose outcomes, but host code must validate lifecycle transitions. Models must not directly own role-label mutation, lifecycle closeout, or other lifecycle authority.

## Preserve upstream unless required otherwise

Treat these as valuable stock Symphony surfaces:

- tracker polling and issue refresh;
- one issue claim identity;
- per-issue workspace reuse;
- worker supervision;
- retry/backoff and reconciliation;
- Codex App Server transport;
- terminal cleanup;
- observability foundations.

Do not widen a change merely to make the architecture feel cleaner.

Before changing an upstream seam, ask:

> Does this directly help one issue progress through the required role lifecycle without human routing?

If not, leave it alone unless required for safety.

## N-project requirement

SYMPHONY must not structurally privilege one target repository.

Target-project identity, repository bootstrap, instance_config/harness inputs, and workspace policy must be project-scoped configuration rather than hard-coded assumptions.

**The exact N-project hosting model is not yet frozen.** In particular, do not yet assume either:

- one generalized orchestrator multiplexing every project; or
- multiple project-scoped orchestrators supervised by one host.

That is a semantic/architecture decision to be made before implementation.

## GitHub lifecycle direction

For MVP, GitHub Issues are the preferred durable task/lifecycle substrate unless later analysis proves them insufficient.

Current direction:

- `symphony:auto` opts an issue into automation;
- exactly one `symphony:role:*` label represents the active lifecycle role;
- host code validates and performs lifecycle transitions;
- durable handoff representation, round counters, PM-thread persistence, restart semantics, and terminal/non-converged representation are still explicit design questions.

Do not invent a hidden second lifecycle database while those questions are unresolved.

## WSL and adapter boundary

There is a known VS Code Codex → direct WSL access failure (`E_ACCESSDENIED`) in this environment.

When Linux-side inspection/build/test work is required, use the established Windows-host → WSL adapter pattern from the parked `symphony-pilot` repository, or a minimal extracted equivalent.

The adapter is **developer/tooling infrastructure only**. It is not lifecycle authority and must not become a new control plane.

Do not respond to the known direct-WSL bug by reinstalling/rebuilding WSL or redesigning the product.

There must be one authoritative SYMPHONY source checkout. WSL may contain build/runtime state and per-issue target workspaces, but not a second independently authoritative SYMPHONY source/deployment clone.

Old SYMPHONY-specific WSL state may be removed only after producing an explicit deletion manifest. Preserve unrelated WSL state, Codex auth/install, Git config, and unrelated projects/tools.

## Donor review rules

For documentation/reconciliation work, classify inherited material as:

- `PRESERVE STOCK`
- `ADAPT TO MVP`
- `DELETE AS DONOR-SPECIFIC`
- `UNDECIDED — REQUIRES SEMANTIC DECISION`

Do not implement while performing a donor-doc review unless the task explicitly authorizes implementation.

Pay special attention to hidden architectural assumptions in apparently operational documentation: scheduling identity, workspace identity, tracker scope, instance_config scope, thread lifetime, retry ownership, project selection, and mutation authority.

## Change discipline

- Prefer narrow extensions over rewrites.
- Do not import scheduling/control-plane code from parked custom Pilot/Runtime branches.
- Do not preserve legacy behavior for compatibility's sake; this product has not launched.
- Do not introduce SQLite, a second scheduler, a second Symphony daemon, publication automation, or generalized abstractions without explicit authority.
- Do not perform unrelated refactors.
- Do not use destructive Git operations (`reset`, `clean`, force push, ref rewrites, destructive checkout) without explicit human approval and stated consequences.
- Do not ask the human to manually inspect giant diffs or ferry routine prompts between agents.
- Surface human decisions only when they change product meaning, authority, or safety.

## Implementation validation

When implementation is authorized:

1. prove the smallest changed seam with focused tests;
2. verify adjacent retry/reconciliation/restart behavior when stateful code changes;
3. run the relevant broader project gate before handoff;
4. report the exact changed files/functions, evidence, and any remaining semantic uncertainty.

A technically passing implementation that violates the lifecycle invariant is not acceptable.
