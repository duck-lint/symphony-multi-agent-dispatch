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
bounded at 3 per planning cycle and working rounds at 8 per epoch; exhaustion is
`symphony:state:non-converged`, not success.

The bounded horizons are nested:

```text
lifecycle
└── epoch (up to 8 working rounds)
    └── working round
        └── planning cycle (up to 3 attempts)
            └── Planner / Reviewer attempt
```

Global round and round-local planning-attempt numbers are immutable provenance
coordinates. `epoch_round` and `planning_cycle_attempt` measure the active local
budgets. An authorized response resets the relevant local budget without
renumbering earlier transitions.

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
Terminal issues are quiescent. A planning-exhaustion terminal issue can resume
only after an exact, authorized planning response; other terminal states retain
their existing semantics. If the projection drifts, the host may repair it
through the normal bounded lifecycle-label path and verifies the result.

Prompt inputs keep four concerns separate: `RoleProfiles` supplies behavioral methodology,
`RoleRuntimePolicy` supplies enforced mechanical authority, lifecycle context supplies the host-derived
temporal/structural position, and handoff supplies task-specific prior evidence. Lifecycle context is
derived from the reconstructed visible ledger for prompt orientation; it is not a second durable record
or a routing authority.

## Host-verified environment capabilities

An instance may declare project capabilities under `environment.capabilities`. Each capability has a stable
`id`, an optional workspace-relative `resources` list, an optional workspace-relative `working_directory`
(default `.`), and an optional direct `command` with an `executable` and argv-style `args`. Relative
executable paths are resolved from the workspace root; bare executable names use the host PATH. A capability
must declare at least one resource or command. Paths cannot be absolute or escape the workspace.

```yaml
environment:
  capabilities:
    - id: project-runtime
      command:
        executable: .venv/bin/python
        args: ["-c", "import project_package"]
      resources:
        - fixtures/input/example.pdf
```

After the existing `before_run` hook succeeds, the host verifies every declared capability in the current
workspace and creates an ephemeral `symphony.environment-capabilities/v1` report for that dispatch. Resource
checks and direct commands are executed by the host; arbitrary `before_run` shell text is not parsed into
capability evidence. Any missing resource, unavailable executable, non-zero command, timeout, or unsafe
declaration fails closed through the existing preparation-failure/retry path. A project with no declarations
receives a `not_checked` report and no fabricated capability claims.

The report reaches PM and every fresh specialist through the shared structured prompt context. It contains
the resolved workspace identity, a digest of the relevant declaration, verification time, capability IDs,
safe canonical executable/resource information, and observed status. Command output and argv contents are not
copied into prompts; command arguments are represented by a digest. `verified` means that the declared checks
passed at the report's verification time. It is evidence, not permission, and it is not a permanent guarantee
that the workspace cannot change. Role sandbox policies and project write boundaries remain independent.

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
`prerequisite_resolution` are optional, with the latter limited to PLANNER and REVIEWER. PM returning results also
carry `reconciliation` (`considered_transition_ids`, `assessment`), and PM `await_human` results carry
`escalation_basis` (`required_external_action`, `existing_authority_gap`, `supporting_transition_ids`). Roles are exactly
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

For a returning PM, the host builds a pure reconciliation projection from accepted current-round specialist event
maps. It preserves transition IDs, role, outcome, evidence, findings, and prerequisite reports without replacing
the reports with a generated summary. The commit-time validator requires the PM to cite every projected event in
ledger order and requires returning PM escalations to cite a nonempty subset of those accepted IDs. Missing or
invalid references are correctable role-result errors: the same PM thread receives the precise host diagnostic for
at most three corrections, after which the lifecycle is visibly blocked without committing the rejected result.
The ledger projection is the only lifecycle state authority; old response and
continuation shapes are outside the clean-cutover contract.

For a Planner returning after a Reviewer `revise`, the host builds a separate pure projection containing the exact
rejected Planner event, triggering Reviewer event, and deterministic finding references. The Planner must account for
every reference; `plan_ready` responses must provide excerpts found verbatim in the resulting plan summary, while
`await_human` and `non_converged` responses account for findings without claiming an executable correction. The host
checks identity, completeness, and excerpt provenance only; the next Reviewer judges semantic adequacy. Invalid
Planner reconciliation is retried as a fresh Planner with a separate bounded technical-correction budget and does not
consume a planning attempt. The final Reviewer findings remain unresolved review evidence when a planning
cycle is continued after exhaustion.

## Runtime configuration and provenance

### Human-guided continuation of epochs and planning cycles

An instance configures the numeric GitHub user IDs permitted to authorize
continuation. A response is accepted only from a matching authenticated GitHub
comment author and only when its structured body names the current lifecycle,
scope, and exact terminal boundary transition:

```yaml
human_response:
  authorized_user_ids: [12345678]
lifecycle:
  integrity_secret: "$SYMPHONY_LIFECYCLE_INTEGRITY_SECRET"
```

The response body is `symphony.human-response/v1` JSON inside the visible
`<!-- symphony.human-response/v1 ... -->` marker. Its `decision` must be
`continue`; `guidance` is preserved verbatim and `authorized_actions` is an
explicit list that is empty unless the human authorizes a named action. The
host obtains author ID, login, timestamps, comment ID, URL, and content digest
from the authenticated GitHub API. Edited, malformed, unauthorized, stale, or
conflicting comments do not advance the lifecycle.

For `scope: "epoch"`, the target is the exact current `await_human` PM
escalation. The signed `human_response_accepted` event records
`boundary_transition_id`, the next epoch, `starting_round`, guidance, and
authenticated comment provenance. The same PM thread resumes. Its next result
must acknowledge that accepted event by transition ID. The epoch-local
eight-round budget resets while global rounds remain monotonic.

For `scope: "planning_cycle"`, the target must be the exact current terminal
Reviewer `revise` event with `terminal_reason: "planning_attempt_exhausted"`.
The signed `planning_response_accepted` event records
`boundary_transition_id`, round, next planning cycle,
`starting_planning_attempt`, guidance, and authenticated comment provenance.
The same lifecycle, epoch, round, workspace, and PM thread remain in place.
A fresh Planner starts directly at the next monotonic planning attempt. The
planning-cycle-local three-attempt budget resets. The first Planner result
must acknowledge the accepted event by transition ID and reconcile the exact
rejected plan and terminal Reviewer findings. The guidance remains available
through that planning cycle, expires as active prompt state on Reviewer
acceptance, and never enters Implementer, Adversary, or PM prompts.

Human guidance is evidence and authorization to reopen a bounded horizon;
it does not grant role or project-write authority. Terminal planning-exhaustion
issues are checked during ordinary lifecycle-recovery polling. Without a valid
response they remain quiescent. No manual label change is needed.

Host-written lifecycle events are authenticated with the instance-scoped
`lifecycle.integrity_secret`. GitHub authorship alone is not a trust boundary
because the host and authorized human may use the same account. The secret is
resolved outside the target workspace and is never included in prompts or
logs.

### Branch-scoped issue workspaces

New project instances can declare the source repository and branch used by
issue workspaces. The existing `hooks.after_create` remains the preparation
mechanism; before a specialist launches, SYMPHONY independently verifies the
actual `origin`, symbolic branch, checked-out `HEAD`, and resolved remote branch
commit:

```yaml
workspace:
  root: /var/lib/symphony/workspaces
  repository: github.com/example/project
  branch: feature/accepted-baseline
```

The branch is passed to Git as an argument, not interpolated into a shell
command. Missing or unsafe refs, repository/branch/revision mismatches, and
failed Git inspection fail closed. Reused workspaces are inspected in place;
their dirty files, current branch, and `HEAD` are not reset, rebased, or
recloned. A changed declaration therefore rejects an existing mismatched
workspace instead of silently redirecting it. The verification report is
ephemeral and records the safe repository, branch, `HEAD`, resolved branch
commit, workspace identity, and timestamp for the current dispatch.

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
