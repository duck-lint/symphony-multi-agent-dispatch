# SYMPHONY MVP — Lifecycle Invariants & Rebuild Guardrails

**Status:** Pre-implementation semantic contract. Intentionally concise.  
**Purpose:** Preserve the desired behavior while rebuilding from fresh upstream `openai/symphony` without re-importing the custom Pilot/Runtime architecture.

## 1. Primary invariant

The strongest invariant is **not SQLite, Pilot, GitHub, or any specific control-plane technology**.

> **The human must not be the routine transition function between coding-agent roles.**

SYMPHONY succeeds when a task can autonomously move through planning, review, implementation, adversarial review, convergence evaluation, and closeout, and only returns to the human for a genuinely semantic/product/authority decision or a true external blocker.

The control-plane substrate is replaceable. For MVP, prefer the path that preserves the most proven upstream Symphony behavior and reaches this lifecycle with the least new machinery.

SYMPHONY is reusable across arbitrary target repositories without source-code modification. Each runtime instance is project-scoped through that target project's project-local `.symphony/instance_config.yml`; multiple independent project-scoped instances may run concurrently. MVP does not require a single orchestrator to multiplex multiple target projects.

`.symphony/instance_config.yml` binds/configures one project-scoped runtime instance only. It does not define the lifecycle, the PM profile, role prompts, or lifecycle authority. The shared multi-role lifecycle belongs to SYMPHONY and is structurally enforced by host code. Dispatched agents obtain project-specific semantic context from the target repository's applicable `AGENTS.md`, harness, and source context; that domain context is not orchestrator-owned.

## 2. Lifecycle in stock-Symphony terms

For MVP, one **GitHub Issue** remains Symphony's durable scheduling/workspace identity.

An eligible issue is:

- open;
- opted in with `symphony:auto`;
- carrying **exactly one** host-controlled lifecycle role label:
  - `symphony:role:pm`
  - `symphony:role:planner`
  - `symphony:role:reviewer`
  - `symphony:role:implementer`
  - `symphony:role:adversary`
  - `symphony:role:archivist`

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

Unless explicitly changed later, retain the current benchmark bounds:

- at most **3 Planner/Reviewer attempts per working round**;
- at most **8 working rounds per lifecycle**;
- exhausting a planning or working-round budget is **non-convergence**, not success and not automatically a blocker.

Every specialist execution is fresh. The PM is the only role with task-scoped reasoning continuity across returns to PM.

There is no Architect role.

Project-local `.symphony/instance_config.yml` configures a project-scoped Symphony instance; it is not itself the lifecycle, PM profile, role prompt, or lifecycle authority. Host lifecycle code selects and dispatches PM and specialist role profiles.

## 3. Required differences from upstream Symphony

Preserve upstream behavior unless one of these invariants requires a change.

### One issue, many role executions

Upstream Symphony treats one issue as one continuing agent lifecycle. MVP SYMPHONY keeps the issue as the scheduling, claim, retry, reconciliation, and workspace identity, but changes the worker unit:

> **one successful worker invocation performs one lifecycle-role execution.**

After a role completes and the host commits the next lifecycle state, the worker exits. Symphony's existing continuation/retry machinery may then redispatch the same issue under its new role.

### Deterministic role routing

Before launching Codex, the host derives exactly one current role from the issue labels and selects that role's:

- prompt;
- tool policy;
- filesystem/write policy;
- PM-thread-resume vs fresh-thread behavior.

Zero or multiple role labels are invalid lifecycle state and must not dispatch.

### Host-owned lifecycle transitions

Models produce evidence and a structured proposed outcome. They do **not** directly control lifecycle labels, issue closure, or lifecycle comments.

The host validates the current role, result schema, and legal transition before changing GitHub state.

Core transition graph:

```text
PM          → PLANNER | ARCHIVIST
PLANNER     → REVIEWER
REVIEWER    → PLANNER | IMPLEMENTER
IMPLEMENTER → ADVERSARY
ADVERSARY   → PM
ARCHIVIST   → DONE
```

Planning-attempt and working-round limits further constrain those transitions.

A safe transition order is:

```text
role turn completes
→ parse strict result
→ refetch/validate current GitHub role
→ persist bounded handoff/history
→ mutate exactly-one role label or terminal state
→ refetch/verify
→ worker exits
→ normal Symphony retry/redispatch
```

Transitions must be idempotent enough that retry cannot create duplicate or contradictory lifecycle state.

### PM continuity; specialist freshness

- First PM invocation creates a Codex thread.
- Later PM invocations for the same issue resume that task's PM thread.
- Planner, Reviewer, Implementer, Adversary, and Archivist always receive fresh threads.
- Failure to resume the required PM thread must be visible; never silently create a fresh PM and pretend continuity survived.
- PM continuity does not require an immortal OS process or App Server process.

### Authority boundary

The model may not use arbitrary GitHub write operations to bypass the lifecycle coordinator.

For lifecycle mode, host code owns role-label changes, lifecycle handoff writes, and issue closeout. Model GitHub access must be restricted accordingly.

Role-specific project write authority must be enforced by actual runtime/tooling boundaries, not prompt wording alone.

## 4. What should remain stock

The rebuild should try to leave these upstream Symphony surfaces alone:

- GitHub tracker polling;
- issue eligibility and refresh;
- one Orchestrator / one claim map;
- per-issue workspace identity and reuse;
- Task Supervisor / worker supervision;
- retry and backoff;
- reconciliation;
- terminal workspace cleanup;
- Codex App Server transport where role semantics do not require changes;
- observability/dashboard foundations.

Within one project-scoped runtime instance, one Symphony runtime and one claim map own that issue population. Independent runtime instances for different target projects are allowed and may run concurrently. Two runtimes must not independently schedule the same project/issue population unless a later design explicitly introduces shared ownership semantics.

## 5. WSL / tooling invariant

The known VS Code Codex → direct WSL path can fail with `E_ACCESSDENIED`. That host-tooling defect is independent of the lifecycle architecture.

Keep the proven **WSL adapter bridge** from `symphony-pilot`, or extract its minimal equivalent, so Codex can inspect/test Linux-side work without making the human a PowerShell/WSL meat proxy.

The adapter is **developer/tooling infrastructure only**. It must not become lifecycle authority or a new control plane.

The MVP uses one authoritative SYMPHONY source checkout. WSL may host runtime state and per-issue workspaces, but it must not maintain a second deployed/source clone of SYMPHONY as an independent implementation authority.

### Fresh WSL reset before the new canary

The old custom SYMPHONY runtime/control-plane state in WSL should be removed before the clean upstream-based build is exercised.

Intent:

- no compatibility with the abandoned Pilot/Runtime architecture;
- no stale deployment, runtime state, workspace, lock, cache, or extracted artifact should influence the new MVP;
- do **not** reinstall or wipe the whole WSL distro merely to remove SYMPHONY;
- preserve unrelated WSL state, Codex installation/auth, Git/user configuration, and unrelated projects/tools.

Before deletion, produce an explicit manifest of Symphony-specific WSL paths/state to remove. After reset, reinstall only the minimal adapter/supervisor bridge actually required by the new target `.symphony/instance_config.yml`.

There is no migration/backward-compatibility requirement for abandoned SYMPHONY state.

## 6. Parked architecture

The existing custom `symphony-pilot` and rewritten `symphony-runtime` branches are **reference material, not the implementation base**.

Do not transplant their scheduling/control-plane code into the new repo.

They may be consulted for:

- lifecycle semantics;
- **role prompts** and authority ideas;
- adversarial findings;
- **WSL adapter implementation**;
- lessons about failure modes.

The new implementation base is a fresh clone of current upstream `openai/symphony`.

## 7. Semantic decisions still requiring explicit design

These are intentionally **not** frozen yet and should be worked through before broad implementation:

1. **Durable lifecycle record**
   - append-only GitHub comments only;
   - compact host-maintained lifecycle record;
   - workspace artifacts plus GitHub handoff;
   - exact idempotency/transition-ID scheme.

2. **Budget representation**
   - how planning-attempt count and working-round count are represented and reconstructed without a lifecycle DB;
   - how non-converged lifecycle exhaustion is represented in GitHub.

3. **PM thread persistence**
   - where the PM thread ID lives;
   - same-machine restart behavior;
   - whether filesystem durability is sufficient for MVP or tracker durability is required.

4. **Role output contract**
   - exact structured schema;
   - accepted/rejected/finding semantics;
   - what evidence permits PM to declare convergence and route to Archivist.

5. **Role write scopes**
   - whether Planner/Archivist are read-only for first MVP and externalize output to GitHub;
   - or whether bounded harness writes are required immediately;
   - how to enforce `source but not .git` if directory-root sandboxing is insufficient.

6. **Implementer Git authority**
   - whether the model may stage/commit;
   - whether host code performs bounded Git operations;
   - publication/PR/merge remain separate from lifecycle completion unless explicitly added.

7. **Human escalation**
   - exact conditions that legitimately pause for human judgment;
   - GitHub representation of blocked/awaiting-human state;
   - routine role routing must never require human intervention.

8. **Tracker mutation authority**
   - exact bounded host GitHub APIs needed for comments, labels, and closeout;
   - what read-only GitHub access, if any, each model role receives.

9. **Restart/recovery semantics**
   - recovery for every role state after process restart;
   - recovery after handoff-write/label-write partial failure;
   - behavior when the persisted PM thread cannot resume.

10. **Lifecycle completion vs task completion**
    - whether successful Archivist closeout closes the GitHub issue for MVP;
    - how a non-converged terminal lifecycle remains available for human disposition or a later lifecycle.

## 8. Anti-drift rule

Before any implementation seam is widened, ask:

> **Does this change directly help one GitHub issue autonomously progress through the required role lifecycle without human routing?**

If not, it is out of MVP scope unless required for safety or to preserve already-working upstream behavior.

The canary is successful when the human creates/opts-in one disposable issue and then does nothing while SYMPHONY proves:

```text
PM P1
→ Planner S1
→ Reviewer S2
→ Implementer S3
→ Adversary S4
→ PM P1 again
→ Archivist S5
→ terminal lifecycle state
```

with fresh specialist threads, preserved PM continuity, host-enforced legal transitions, no overlapping worker ownership, and no human acting as the message bus.
