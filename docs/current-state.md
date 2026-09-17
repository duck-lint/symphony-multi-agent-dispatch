# SYMPHONY current runtime state

SYMPHONY is a reusable, project-scoped MVP orchestrator. A target repository supplies
`.symphony/instance_config.yml`; that file binds one runtime instance but does not define the shared
lifecycle, role topology, prompts, or lifecycle authority.

## Lifecycle and durable state

The generic lifecycle is:

```text
PM → fresh Planner → fresh Reviewer → bounded Implementer → fresh Adversary
  → same task-scoped PM → fresh Archivist → terminal lifecycle state
```

Reviewer revision returns to a fresh Planner. A blocking Adversary finding forces another working round
through the same task-scoped PM. The initial PM cannot converge or skip to Archivist. Planning attempts are
bounded at 3 per round and working rounds at 8; exhaustion is `symphony:state:non-converged`, not success.

Planner and Reviewer can carry a structured `prerequisite_resolution` report when a prerequisite blocks
feasibility. The report records the blocked objective, missing prerequisite, evidence of absence, governing
requirement, material alternatives and their dispositions, authority to resolve the prerequisite, the smallest
unlocking action, and resolution status. The host validates its shape and legal disposition, then carries the
accepted report in the visible lifecycle event and in the next handoff/context snapshot. It does not infer
semantic equivalence, verify domain facts, or treat a model assertion of exhaustive investigation as host proof.

`plan_ready` and `accept` require a reported prerequisite to be resolved. A specific external prerequisite may
produce `await_human` with a precise question. Planner or Reviewer may return `non_converged` only with a
structurally complete investigation showing that no feasible authorized path has been established; the existing
`symphony:state:non-converged` terminal projection is used. At the planning budget boundary, the host compares
the structured Planner/Reviewer prerequisite reports for the current and preceding attempt. Exact unchanged
reports produce the distinct `prerequisite_non_progress` terminal reason; changed reports remain eligible for
normal review. This deterministic comparison is repetition detection, not a proof that no solution exists.

PM is the only persistent reasoning session. The first PM creates and persists a Codex thread before its
first turn. Returning PM execution resumes that exact thread through Codex `thread/resume`; a missing,
unavailable, or mismatched thread fails closed and is operator-visible. Planner, Reviewer, Implementer,
Adversary, and Archivist executions always receive fresh Codex threads.

GitHub labels are the current lifecycle projection. Append-only host-written comments are the durable
lifecycle history and handoff log, with deterministic transition IDs for idempotent retries. Host-local
PM metadata stores only the task/lifecycle binding, thread ID, and optional Codex rollout/thread path
needed for reconnect. It is not lifecycle authority; lifecycle recovery comes from GitHub labels and
comments. Each lifecycle comment is one fully visible, pretty-printed JSON event. The exact JSON object
is parsed for reconstruction, idempotence, and restart recovery and is the complete human-readable issue
ledger; no lifecycle information is carried only in hidden HTML or a lossy summary.

Terminal projection is idempotent: a correct terminal label set causes no GitHub mutation on later polls.
Terminal issues are non-dispatchable. If the projection drifts, the host may repair it through the normal
bounded lifecycle-label path and verifies the result.

Prompt inputs keep four concerns separate: `RoleProfiles` supplies behavioral methodology,
`RoleRuntimePolicy` supplies enforced mechanical authority, lifecycle context supplies the host-derived
temporal/structural position, and handoff supplies task-specific prior evidence. Lifecycle context is
derived from the reconstructed visible ledger for prompt orientation; it is not a second durable record
or a routing authority.

## Authority and result contract

Role authority is structural:

```text
PM / Planner / Reviewer / Adversary / Archivist  read-only project access
Implementer                                      bounded project-workspace writes only
```

Implementer cannot mutate `.git`, stage, commit, switch, reset, merge, push, or publish. Models have no
GitHub mutation capability. The host performs only the bounded current-issue reads, lifecycle comments,
and lifecycle-label mutations required by the MVP. There is no automatic commit, PR, merge, publication,
or issue closure; the successful lifecycle leaves the GitHub issue open.

Every role must return one strict `symphony.role-result/v1` JSON object and no surrounding prose. Required
top-level keys are `schema`, `role`, `outcome`, `summary`, `evidence`, and `findings`; `human_question` and
`prerequisite_resolution` are optional, with the latter limited to PLANNER and REVIEWER. Roles are exactly
`PM`, `PLANNER`, `REVIEWER`, `IMPLEMENTER`, `ADVERSARY`, or `ARCHIVIST`, with these legal outcomes:

```text
PM           plan | converge | await_human
Planner      plan_ready | non_converged | await_human
Reviewer     accept | revise | non_converged | await_human
Implementer  implementation_complete | await_human
Adversary    review_complete | await_human
Archivist    archive_complete | await_human
```

`summary` is a non-empty string of at most 16,000 characters. `evidence` is an array of non-empty strings.
Each finding has exactly `severity`, `summary`, and `evidence`; severity is `blocking` or `advisory`, the
summary is non-empty, and evidence is an array of non-empty strings. `human_question` is required and
non-empty only for `await_human`; otherwise it is omitted or null. Unknown fields, including `next_role`,
are rejected. The host validates the result and owns all routing decisions.

Continuity, authority, malformed state, and unavailable required external capabilities fail closed and
remain visible to the operator. Normal revision, difficult implementation, failed tests, infrastructure
retry, and budget exhaustion do not hand routine routing back to the human.

The prerequisite report is retained in the same visible JSON lifecycle ledger as the role result. On restart,
the host reconstructs the preceding correction, attempted resolution, and outstanding evidence frontier from
that ledger; operational retries do not create lifecycle events or consume planning attempts. The host can
enforce field shape, report/outcome consistency, transition legality, terminal idempotence, and exact structured
repetition. It cannot establish that an agent examined every possible mechanism or that two arbitrary prose plans
are semantically equivalent. Synthetic tests cover these host guarantees; they do not prove exhaustive live agent
investigation.

## Runtime configuration and provenance

The required Codex runtime configuration is `gpt-5.6-luna` with reasoning effort `high`, supplied through
the project instance's Codex app-server command, for example:

```yaml
codex:
  command: codex --config 'model="gpt-5.6-luna"' --config 'model_reasoning_effort="high"' app-server
```

For Linux x86_64 Burrito deployment, build only from a clean WSL-native `git archive` of the exact
committed source. Set `SYMPHONY_BUILD_REVISION` to that 40-character SHA and run the repo-declared mise
toolchain's production path:

```bash
SYMPHONY_BUILD_REVISION="$sha" BURRITO_TARGET=linux_x86_64 MIX_ENV=prod \
  mise exec -- mix release symphony --overwrite
```

Install the executable under `~/.local/lib/symphony/$sha/`, point `~/.local/bin/symphony` at it, and verify
the executable's embedded release/payload identity before launch. The extracted Burrito payload must also
identify `$sha`; never allow Burrito to execute an extracted payload from a different revision.

## Validation doctrine and evidence

Synthetic tests are regression protection, not runtime acceptance evidence. Runtime claims require
representative runtime evidence. The canary is the acceptance gate, not a synthetic fixture and not the
source of lifecycle semantics: it can falsify implementation claims, but SYMPHONY must never be shaped
specifically to a canary repository, issue, or task.

Demonstrated on the real canary substrate: eligible issue intake; PM planning; fresh Planner; fresh
Reviewer; bounded Implementer; fresh Adversary; exact task-scoped PM resume; PM convergence; fresh Archivist;
durable GitHub lifecycle projection/handoffs; lifecycle-complete with the issue still open; autonomous
removal of `symphony:auto` and the role label; post-terminal polling that is read-only/quiescent;
fail-closed PM continuity failure from an earlier canary; and recovery across host restart after a
role-result contract failure.

Still requiring representative canary evidence: Reviewer → Planner revision; Adversary blocker → PM →
another working round; planning-attempt exhaustion; round-budget/non-converged termination; awaiting-human;
healthy mid-lifecycle restart/recovery; actual terminal projection drift repair; and multiple eligible
issues/configured concurrency behavior.

This status is capability evidence, not a percentage or coverage claim.
