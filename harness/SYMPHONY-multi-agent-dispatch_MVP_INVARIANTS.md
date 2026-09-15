# SYMPHONY MVP — Lifecycle Invariants & Rebuild Guardrails

**Status:** Current MVP semantic contract.
**Purpose:** Preserve the accepted lifecycle and authority boundaries while maintaining the upstream-derived SYMPHONY implementation.

## 1. Primary invariant

The strongest invariant is **not SQLite, Pilot, GitHub, or any specific control-plane technology**.

> **The human must not be the routine transition function between coding-agent roles.**

SYMPHONY succeeds when a task can autonomously move through planning, review, implementation, adversarial review, convergence evaluation, and closeout, and only returns to the human for a genuinely semantic/product/authority decision or a true external blocker.

The control-plane substrate is replaceable. For MVP, prefer the path that preserves the most proven upstream Symphony behavior and reaches this lifecycle with the least new machinery.

SYMPHONY is reusable across arbitrary target repositories without source-code modification. Each runtime instance is project-scoped through that target project's project-local `.symphony/instance_config.yml`; multiple independent project-scoped instances may run concurrently. MVP does not require a single orchestrator to multiplex multiple target projects.

`.symphony/instance_config.yml` binds/configures one project-scoped runtime instance only. It does not define the lifecycle, the PM profile, role prompts, or lifecycle authority. The shared multi-role lifecycle belongs to SYMPHONY and is structurally enforced by host code. Dispatched agents obtain project-specific semantic context from the target repository's applicable `AGENTS.md`, harness, and source context; that domain context is not orchestrator-owned.

## 2. Lifecycle in stock-Symphony terms

For MVP, one **GitHub Issue** remains Symphony's durable task, scheduling, claim, retry, reconciliation, and workspace identity.

An issue is dispatch-eligible only when it is:

- open;
- opted in with `symphony:auto`;
- carrying **exactly one** host-controlled lifecycle role label:
  - `symphony:role:pm`
  - `symphony:role:planner`
  - `symphony:role:reviewer`
  - `symphony:role:implementer`
  - `symphony:role:adversary`
  - `symphony:role:archivist`
- not paused or terminal under a host-controlled `symphony:state:*` label.

Conceptual lifecycle:

```text
GitHub Issue
  → PM
  → fresh Planner
  → fresh Reviewer
       ↳ correction → fresh Planner → fresh Reviewer
  → fresh Implementer
  → fresh Adversary
  → same task-scoped PM
       ↳ not converged → another full working round
       ↳ converged → fresh Archivist → lifecycle closeout
```

The **initial** PM invocation may route only to Planner or valid human escalation. `PM → ARCHIVIST` becomes legal only after at least one complete `IMPLEMENTER → ADVERSARY → PM` cycle.

Unless explicitly changed later, retain these bounds:

- at most **3 Planner/Reviewer attempts per working round**;
- at most **8 working rounds per lifecycle**;
- exhausting either budget is **non-convergence**, not success and not automatically a blocker;
- infrastructure retries, worker crashes, timeouts, or transport failures do **not** consume lifecycle budgets.

Every specialist execution is fresh. The PM is the only role with task-scoped reasoning continuity across returns to PM.

There is no Architect role.

Project-local `.symphony/instance_config.yml` configures a project-scoped Symphony instance; it is not itself the lifecycle, PM profile, role prompt, or lifecycle authority. Host lifecycle code selects and dispatches PM and specialist role profiles.

## 3. Durable lifecycle state and budget accounting

GitHub is the durable lifecycle substrate for MVP. Do not create a hidden lifecycle database.

Lifecycle state is split deliberately:

- **current role/state:** host-controlled GitHub labels;
- **durable history and handoffs:** append-only host-written GitHub comments;
- **mutable project work:** the per-issue workspace;
- **PM thread continuity:** host-local Symphony state outside the model-writable workspace.

Workspace artifacts are not lifecycle authority. A mutable "mega-comment" is not the lifecycle record.

### Lifecycle event log

When an opted-in issue begins a lifecycle and has no active lifecycle record, the host creates a `lifecycle_started` comment with a new `lifecycle_id`. A later deliberate rerun after a terminal lifecycle creates a new `lifecycle_id` on the same issue.

Every accepted role transition is persisted as exactly one append-only lifecycle comment before the role label changes. Each lifecycle comment contains one fully visible, pretty-printed JSON object conforming to `symphony.lifecycle/v1`. That exact object is both the parser input for reconstruction/idempotence/recovery and the complete human-readable issue ledger; there is no hidden HTML payload or lossy prose summary.

The lifecycle event record must include at least:

```text
schema
kind
lifecycle_id
transition_id
role_result_schema
role
from_role
outcome
to_role
round
planning_attempt
summary
evidence
findings
human_question
terminal_reason
```

For MVP, transition identity is deterministic from lifecycle position:

```text
<lifecycle_id>:r<round>:p<planning_attempt>:<from_role>:<outcome>
```

The host must check for an existing `transition_id` before appending a comment. Replaying a completed host operation therefore completes or verifies the same transition rather than creating another event.

### Working rounds and planning attempts

A working round is:

```text
PM → Planner → Reviewer [↔ Planner/Reviewer corrections] → Implementer → Adversary → PM
```

Budget counters are reconstructed from the accepted lifecycle event history rather than maintained in a separate mutable store.

- `PM → PLANNER` opens a round with planning attempt `1`.
- `REVIEWER → PLANNER` increments the planning attempt within the same round.
- A Reviewer revision after planning attempt `3` terminates the lifecycle as non-converged rather than dispatching a fourth Planner.
- A returning PM outcome requesting another round increments the working round and resets planning attempt to `1`.
- A returning PM request for another round after round `8` terminates the lifecycle as non-converged rather than opening round `9`.

Non-convergence removes `symphony:auto` and the role label, adds `symphony:state:non-converged`, writes a terminal lifecycle comment, and leaves the GitHub issue open for human disposition or a later lifecycle.

## 4. Deterministic role routing and role-result contract

Upstream Symphony treats one issue as one continuing agent lifecycle. MVP SYMPHONY keeps the issue as the scheduling, claim, retry, reconciliation, and workspace identity, but changes the worker unit:

> **one successful worker invocation performs one lifecycle-role execution.**

After a role completes and the host commits the next lifecycle state, the worker exits. Symphony's existing continuation/retry machinery may then redispatch the same issue under its new role.

Before launching Codex, the host derives exactly one current role from the issue labels and selects that role's:

- prompt;
- tool policy;
- filesystem/write policy;
- PM-thread-resume vs fresh-thread behavior.

Zero or multiple role labels are invalid lifecycle state and must not dispatch.

### Structured role result

Every role returns exactly one result conforming to `symphony.role-result/v1`:

```json
{
  "schema": "symphony.role-result/v1",
  "role": "REVIEWER",
  "outcome": "accept",
  "summary": "The plan is executable and satisfies the task constraints.",
  "evidence": [],
  "findings": [],
  "human_question": null
}
```

`evidence` is a list of bounded evidence strings. Each finding has this shape:

```json
{
  "severity": "blocking",
  "summary": "...",
  "evidence": ["..."]
}
```

MVP finding severity is only `blocking` or `advisory`.

`human_question` must be non-null only when `outcome` is `await_human`; otherwise it must be null.

The result schema does **not** contain `next_role`. Models report role-specific outcomes; host code maps valid outcomes to legal transitions.

Allowed outcomes are:

```text
PM           plan | converge | await_human
Planner      plan_ready | await_human
Reviewer     accept | revise | await_human
Implementer  implementation_complete | await_human
Adversary    review_complete | await_human
Archivist    archive_complete | await_human
```

Host transition mapping is:

```text
initial PM + plan                  → PLANNER
returning PM + plan                → PLANNER, subject to round budget
returning PM + converge            → ARCHIVIST, subject to convergence preconditions
PLANNER + plan_ready               → REVIEWER
REVIEWER + revise                  → PLANNER, subject to planning-attempt budget
REVIEWER + accept                  → IMPLEMENTER
IMPLEMENTER + implementation_complete → ADVERSARY
ADVERSARY + review_complete        → PM
ARCHIVIST + archive_complete       → lifecycle-complete
any role + await_human             → paused awaiting-human state
```

A Reviewer `accept` result may not contain blocking findings. A returning PM `converge` result is legal only when:

- the current lifecycle has completed at least one Implementer → Adversary → PM cycle;
- the immediately preceding Adversary result contains no blocking findings;
- the PM explicitly returns `converge` and provides bounded evidence that the issue objective is satisfied.

Blocking findings from the immediately preceding Adversary result structurally forbid `PM → ARCHIVIST`. They can only be cleared for convergence purposes by another complete working round whose Adversary result contains no blocking findings.

The host validates role, schema, outcome, budget, convergence preconditions, and expected current GitHub state before changing lifecycle state.

A safe transition order is:

```text
role turn completes
→ parse strict result
→ refetch/validate current GitHub role
→ validate budget/convergence constraints
→ append idempotent lifecycle handoff comment
→ mutate exactly-one role label or terminal state
→ refetch/verify
→ worker exits
→ normal Symphony retry/redispatch
```

## 5. PM continuity and specialist freshness

- First PM invocation creates a Codex thread.
- Later PM invocations for the same lifecycle resume that task's PM thread.
- Planner, Reviewer, Implementer, Adversary, and Archivist always receive fresh threads.
- PM continuity does not require an immortal OS process or App Server process.

The PM thread ID is host-owned local state stored under Symphony's state root, outside the issue workspace and outside any model-writable path. Conceptually:

```text
<state-root>/<project-instance>/<issue-id>/pm-thread.json
```

The record contains the active `lifecycle_id`, PM `thread_id`, and optional Codex rollout/thread path metadata
returned by the app-server. These are host-local reconnect metadata only; they do not authorize, advance, or
reconstruct lifecycle state.

MVP guarantees **same-machine restart continuity**, not portable cross-machine PM continuity. Publishing the thread ID into GitHub does not make an absent Codex thread resumable and is not required.

If the required PM thread cannot be resumed, the host must never silently create a replacement PM and pretend continuity survived. It pauses the lifecycle visibly as a technical blocked state until continuity is recovered or a human explicitly authorizes a continuity reset.

## 6. Role authority, filesystem scope, Git, and tracker mutation

Role boundaries are structural runtime authority, not prompt suggestions.

For MVP:

```text
PM           read-only project access
Planner      read-only project access
Reviewer     read-only project access
Implementer  bounded project-workspace write access
Adversary    read-only project access
Archivist    read-only project access
```

Planner plans and Archivist closeout material are externalized through their structured role results and host-written lifecycle comments. They do not require repository write authority for the first MVP.

### Implementer filesystem and Git authority

The Implementer may modify authorized project files in the issue workspace. It must not own Git metadata.

The Implementer may inspect repository state with read-only Git operations such as `status`, `diff`, `log`, and `show`, but may not stage, commit, switch branches, reset, merge, push, or otherwise mutate `.git` or publish changes.

The host also performs **no automatic commit, push, PR creation, merge, or publication** as part of the lifecycle MVP. Publication remains a separate later/human-authorized operation.

The implementation must prove an actual enforcement boundary preventing model mutation of `.git`. If stock directory-root sandboxing cannot express `workspace source writable, .git not writable`, the implementation must add the smallest enforceable boundary required before canary. Prompt wording alone is insufficient.

### GitHub mutation authority

Models receive no GitHub mutation capability for MVP. Do not expose a raw host-authenticated provider API that lets a role bypass lifecycle authority.

The host lifecycle coordinator receives only the bounded GitHub operations required for the configured repository/current issue:

- fetch current issue state and labels;
- read SYMPHONY lifecycle comments;
- append a lifecycle/handoff/escalation comment;
- add or remove SYMPHONY lifecycle labels.

Issue close, PR creation, merge, arbitrary repository mutation, and generic tracker CRUD are outside the MVP lifecycle coordinator.

If direct model-side tracker reading later proves useful, add GET-only capability deliberately; it is not required for the first lifecycle canary.

## 7. Human escalation and lifecycle completion

Human escalation is exceptional, not a routine workflow branch.

Legitimate `await_human` conditions are limited to cases such as:

- genuine product/semantic ambiguity where choosing changes user intent;
- requested action exceeding the role or system's granted authority;
- missing required external authentication, secret, or unavailable external capability;
- security/safety boundary requiring explicit approval;
- corrupt or unrecoverable lifecycle state;
- unavailable required PM continuity.

The following are **not** human-escalation reasons by themselves:

- Reviewer requests revision;
- Adversary finds defects;
- tests fail;
- implementation is difficult;
- a role is uncertain about code and can investigate autonomously;
- a planning attempt or working-round budget is exhausted;
- a retryable worker, transport, or network failure occurs.

On valid human escalation, the host:

- removes `symphony:auto`;
- keeps the current role label when that role remains the resume point;
- adds `symphony:state:awaiting-human` for semantic/authority escalation, or `symphony:state:blocked` for unrecoverable technical state;
- appends a structured comment explaining the exact decision/recovery required and resume point.

Resumption is explicit: after the exceptional condition is resolved, automation is re-enabled and the same lifecycle/role continues where structurally valid.

### Lifecycle completion is not task closure

A successful Archivist closeout terminates the **SYMPHONY lifecycle**, not the human GitHub task.

On `ARCHIVIST + archive_complete`, the host:

- appends the terminal lifecycle comment;
- removes `symphony:auto`;
- removes the role label;
- adds `symphony:state:lifecycle-complete`;
- leaves the GitHub issue **open**;
- leaves the issue workspace available for later inspection/publication.

On budget exhaustion, the corresponding terminal state is `symphony:state:non-converged`, and the issue likewise remains open.

The human may later publish/merge/close the issue, or deliberately begin another lifecycle on the same issue. A new lifecycle uses a new `lifecycle_id`.

This distinction is intentional:

```text
role terminal
→ lifecycle terminal
→ human disposition / publication
→ task terminal
```

## 8. Restart and recovery semantics

Recovery is reconstructed from GitHub labels plus the append-only lifecycle event log, with host-local PM metadata used only for PM thread continuity.

Required recovery behavior:

```text
specialist crashes before accepted transition
→ rerun the same role fresh
→ lifecycle budget unchanged

PM crashes before accepted transition
→ resume the same PM thread
→ lifecycle budget unchanged

transition comment exists but role label is still old
→ detect existing transition_id
→ complete/verify the label mutation
→ do not rerun the completed role

transition comment and destination label both exist
→ normal redispatch of the destination role

role label reflects a transition but matching durable transition comment is absent
→ treat as invalid/corrupt lifecycle state
→ remove automation eligibility and block visibly
→ do not invent the missing handoff

required PM thread metadata exists but the thread cannot resume
→ block visibly
→ never silently replace the PM
```

The host must persist the lifecycle comment before mutating the role label. This ordering ensures the normal recoverable partial transition is "durable handoff exists, projection label is stale," not "new role is visible without its handoff."

External edits or two independent runtimes attempting to own the same issue population are authority conflicts, not a supported concurrency mode.

## 9. What should remain stock

The rebuild should try to leave these upstream Symphony surfaces alone unless the lifecycle contract above requires a narrow extension:

- GitHub tracker polling;
- issue eligibility and refresh;
- one Orchestrator / one claim map per project-scoped runtime;
- per-issue workspace identity and reuse;
- Task Supervisor / worker supervision;
- retry and backoff;
- reconciliation;
- terminal-issue workspace cleanup;
- Codex App Server transport where role semantics do not require changes;
- observability/dashboard foundations.

Within one project-scoped runtime instance, one Symphony runtime and one claim map own that issue population. Independent runtime instances for different target projects are allowed and may run concurrently. Two runtimes must not independently schedule the same project/issue population unless a later design explicitly introduces shared ownership semantics.

## 10. WSL / tooling invariant

The known VS Code Codex → direct WSL path can fail with `E_ACCESSDENIED`. That host-tooling defect is independent of the lifecycle architecture.

Keep the proven **WSL adapter bridge** from `symphony-pilot`, or extract its minimal equivalent, so Codex can inspect/test Linux-side work without making the human a PowerShell/WSL meat proxy.

The adapter is **developer/tooling infrastructure only**. It must not become lifecycle authority or a new control plane.

The MVP uses one authoritative SYMPHONY source checkout. WSL may host installed/built runtime artifacts, logs, caches, host-owned state, and project/issue workspaces, but it must not maintain a second independently authoritative SYMPHONY source repository.

### Revision-specific runtime provenance

The authoritative committed source, build input, Burrito executable, extracted Burrito payload, and code
actually executing must identify the same committed revision. Build Linux x86_64 from a clean WSL-native
`git archive` snapshot with `SYMPHONY_BUILD_REVISION` set to the exact 40-character SHA, install under a
SHA-scoped directory, and verify the embedded release/payload identity before launch. A commit-scoped
executable pathname alone is insufficient; an extracted payload from another revision must not be reused.

## 11. Parked architecture

The existing custom `symphony-pilot` and rewritten `symphony-runtime` branches are **reference material, not the implementation base**.

Do not transplant their scheduling/control-plane code into the new repo.

They may be consulted for:

- lifecycle semantics;
- **role prompts** and authority ideas;
- adversarial findings;
- **WSL adapter implementation**;
- lessons about failure modes.

The new implementation base is the fresh current-upstream-derived repository.

## 12. Anti-drift rule and canary

Before any implementation seam is widened, ask:

> **Does this change directly help one GitHub issue autonomously progress through the required role lifecycle without human routing?**

If not, it is out of MVP scope unless required for safety or to preserve already-working upstream behavior.

The canary is the acceptance gate for representative runtime behavior. It is not a synthetic fixture and it
does not define lifecycle semantics. The canary may falsify an implementation claim, but SYMPHONY must not
be shaped around a canary repository, issue, or task.

The happy-path gate proves, on the real canary substrate, that the human can create/opt-in one disposable
issue and then do nothing while SYMPHONY performs:

```text
PM P1
→ Planner S1
→ Reviewer S2
→ Implementer S3
→ Adversary S4
→ PM P1 again
→ Archivist S5
→ symphony:state:lifecycle-complete
```

with:

- fresh specialist threads;
- preserved PM continuity;
- append-only durable handoffs;
- deterministic budget reconstruction;
- host-enforced legal transitions;
- host-enforced role/write/tracker authority;
- no overlapping worker ownership;
- the implementation left in the issue workspace without automatic Git publication;
- the GitHub issue still open for human disposition;
- no human acting as the routine message bus.

## 13. Runtime validation doctrine and current evidence

Synthetic tests are regression protection, not runtime acceptance evidence. Runtime claims require
representative runtime evidence. The current evidence status is recorded as capabilities, not as a
percentage or coverage score.

Demonstrated on the real canary substrate:

- eligible issue intake and PM planning;
- fresh Planner, fresh Reviewer, bounded Implementer, fresh Adversary, and fresh Archivist execution;
- exact task-scoped PM resume and PM convergence;
- durable GitHub lifecycle projection and append-only handoffs;
- `symphony:state:lifecycle-complete` while the issue remains open;
- autonomous removal of `symphony:auto` and the role label;
- post-terminal polling that is read-only/quiescent;
- fail-closed PM continuity failure from an earlier canary;
- recovery across host restart after a role-result contract failure.

Still requiring representative canary evidence:

- Reviewer → Planner revision;
- Adversary blocker → PM → another working round;
- planning-attempt exhaustion;
- working-round budget / non-converged termination;
- awaiting-human;
- healthy mid-lifecycle restart/recovery;
- repair of actual terminal projection drift;
- multiple eligible issues and configured concurrency behavior.
