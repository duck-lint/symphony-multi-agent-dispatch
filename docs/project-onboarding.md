# Project onboarding

This guide attaches one GitHub repository to one project-scoped SYMPHONY
runtime. The example repository throughout is `example/project`; replace it
with the target project without changing the shared lifecycle or role
authority.

The host must not be asked to route normal role transitions. After initial
opt-in, the host validates structured role results and owns the lifecycle.

## 1. Project authority

Prepare the target repository with its own `AGENTS.md`, specifications,
harness material, source, tests, and fixture contracts. Those files define
project meaning and acceptance evidence. They do not redefine SYMPHONY's role
topology, lifecycle budgets, PM continuity, or host mutation authority.

## 2. Host-loaded configuration authority

The runtime loads exactly one YAML instance configuration file. The CLI accepts
an explicit path:

```bash
symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$HOME/.local/state/symphony/example-project" \
  /srv/projects/example-project/.symphony/instance_config.yml
```

Without the final argument, the CLI uses `.symphony/instance_config.yml`
relative to its current working directory. The selected file's location—not
the repository's default branch—determines the authoritative instance
configuration. The runtime does not search GitHub branches for a newer copy.

Copies of `.symphony/instance_config.yml` in a source branch or an issue
workspace are ordinary project files. They do not redirect a running host,
and changing one does not change the host's selected configuration file. To
change the running instance, change the host-loaded file and let the host's
configuration store reload it, or restart the instance with a different path.

Keep credentials and other host secrets outside the target repository.

## 3. Host prerequisites and secrets

Before launch, provide:

- the accepted SYMPHONY executable and its declared Linux/WSL toolchain or
  installed runtime;
- an installed and authenticated Codex CLI whose app-server command is
  available to the host;
- a GitHub token with access to `example/project` and permission for the
  bounded issue, comment, and label operations;
- the lifecycle integrity secret; and
- the numeric GitHub user IDs allowed to answer human escalations.

For example, load a mode-600 environment file in the host service or shell
before launching SYMPHONY. Do not print or commit it:

```bash
set -a
source /etc/symphony/example-project.env
set +a
```

The file can contain values referenced by the instance configuration, such as
`SYMPHONY_GITHUB_TOKEN` and `SYMPHONY_LIFECYCLE_INTEGRITY_SECRET`. Never put
an actual secret in this document, a project workspace, a prompt, or a Git
commit.

## 4. Instance configuration

Create the host-selected `.symphony/instance_config.yml` with the project
specific tracker, workspace, hooks, capabilities, and runtime settings. This
example is internally consistent:

```yaml
tracker:
  kind: github
  provider:
    repo: "example/project"
    token: "$SYMPHONY_GITHUB_TOKEN"
  required_labels:
    - symphony:auto
  active_states:
    - open
  terminal_states:
    - closed

polling:
  interval_ms: 5000

workspace:
  root: /var/lib/symphony/workspaces/example-project
  repository: github.com/example/project
  branch: feature/accepted-baseline

hooks:
  after_create: |
    set -eu
    git clone --branch "feature/accepted-baseline" --single-branch \
      https://github.com/example/project.git .

environment:
  capabilities:
    - id: project-runtime
      working_directory: .
      resources:
        - fixtures/input/example.pdf
      command:
        executable: .venv/bin/python
        args: ["-c", "import project_package"]

lifecycle:
  integrity_secret: "$SYMPHONY_LIFECYCLE_INTEGRITY_SECRET"

human_response:
  authorized_user_ids: [12345678] # replace with a verified numeric GitHub user ID

agent:
  max_concurrent_agents: 1

codex:
  command: codex --config 'model="gpt-5.6-luna"' --config 'model_reasoning_effort="high"' app-server
  approval_policy: on-request
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: false
```

The runtime parses the YAML and resolves supported `$NAME` references from the
host environment. `workspace.repository` and `workspace.branch` must be
configured together; the branch must be a safe Git branch reference. A relative
`workspace.root` is resolved relative to the directory containing the selected
configuration file.

### Lifecycle integrity

`lifecycle.integrity_secret` is required for GitHub lifecycle preparation and
commit. The host signs its append-only lifecycle events with HMAC-SHA256 and
verifies the signed history before proceeding. Provision the environment
variable securely before process launch, keep its value stable across restarts,
and do not rotate it while existing signed events still need to be read. A
successful process start is not proof that the secret is usable: configuration
parsing and OTP startup occur first; the lifecycle coordinator enforces the
usable secret when it prepares a GitHub dispatch.

### Human-response authorization

`human_response.authorized_user_ids` contains positive, unique numeric GitHub
user IDs. Do not authorize by login name alone. For a verified login, obtain
the ID from the authenticated GitHub API, for example:

```bash
gh api users/VERIFIED_LOGIN --jq .id
```

The current parser accepts only `decision: "continue"`; a formal rejection
decision is not implemented. A response comment must have this exact enclosing
shape and all of these fields:

```text
<!-- symphony.human-response/v1
{
  "schema": "symphony.human-response/v1",
  "lifecycle_id": "<current lifecycle id>",
  "scope": "epoch",
  "target_transition_id": "<exact current escalation transition id>",
  "decision": "continue",
  "guidance": "Continue with the bounded, authorized correction.",
  "authorized_actions": []
}
-->
```

`lifecycle_id`, `scope`, and `target_transition_id` bind the response to the
exact current boundary. Use `scope: "planning_cycle"` to continue a terminal
Reviewer `revise` with `planning_attempt_exhausted`; the target must be that
terminal Reviewer's transition ID. `guidance` must be non-empty. `authorized_actions` must be
a list of strings and is empty unless the human explicitly authorizes named
actions. The authenticated GitHub comment metadata—not prose in the body—supplies
the author ID, comment identity, timestamps, and URL. Edited, malformed,
unauthorized, stale, or conflicting comments do not continue the lifecycle.

For planning exhaustion, use `"scope": "planning_cycle"` and set
`target_transition_id` to the exact terminal Reviewer `revise` transition
whose `terminal_reason` is `planning_attempt_exhausted`. The host starts a
new bounded planning cycle in the same epoch and working round at a fresh
Planner. The PM thread is not invoked. No lifecycle-label change is required
from the human.

When the PM lacks authority for an external decision, it returns `await_human`
with a non-empty `human_question`. The host persists that escalation and adds
the awaiting-human projection. The PM does not call a GitHub authorization
tool. When a valid response is accepted, the host opens a new work epoch in
the same lifecycle, retaining the PM thread and issue workspace, resetting the
epoch-local working-round budget, and preserving monotonic global rounds.

For a Planner, Reviewer, Implementer, Adversary, or Archivist `await_human`, use
`scope: "specialist"` and target the exact signed specialist escalation. A
valid response appends `specialist_response_accepted`, restores `symphony:auto`
and the same specialist role label, and dispatches a fresh worker of that role.
It preserves the same lifecycle, workspace, epoch, round, planning cycle,
planning attempt, and all existing handoff evidence. It does not invoke PM,
reset a budget or horizon, or require a manual label change. The response
becomes role-local guidance; the resumed specialist must acknowledge its exact
response transition ID in its first result. Guidance is not a new permission
surface and disappears when that specialist advances normally.

## 5. Branch-scoped workspace materialization and verification

For a new issue workspace, the host creates the issue-specific directory and
runs `hooks.after_create` once. In the example, the hook materializes the
configured branch. The hook is preparation, not provenance evidence.

Before every role dispatch, the host independently verifies the materialized
workspace's:

- `origin` repository identity against `workspace.repository`;
- symbolic checked-out branch against `workspace.branch`;
- checked-out `HEAD`; and
- `refs/remotes/origin/<branch>` revision, requiring it to equal `HEAD`.

The host passes the resulting source-provenance report to the role only after
these checks succeed. A missing repository, unsafe or mismatched branch,
unreadable Git state, repository mismatch, or revision mismatch fails closed.

Existing issue workspaces are preserved in place. SYMPHONY does not
automatically reset, rebase, reclone, or otherwise reconcile a reused
workspace. If a changed `workspace.repository` or `workspace.branch`
declaration conflicts with an existing workspace, dispatch is rejected; the
configuration change does not redirect that workspace.

Only the Implementer receives bounded project-workspace write authority. Git
metadata is protected by the runtime, and the Implementer cannot stage, commit,
switch branches, reset, merge, push, or publish.

## 6. Environment capabilities

`environment.capabilities` is a declarative contract for checks the host can
report at a role-dispatch boundary. Each capability has a stable `id` and at
least one of:

- `resources`: workspace-relative paths;
- `working_directory`: an optional workspace-relative directory, default `.`;
- `command`: an optional direct executable plus argv-style string `args`.

Resource paths and relative executables cannot be absolute or escape the
workspace. A relative executable is resolved from the workspace root; a bare
executable name is resolved through the host `PATH`. The host executes the
declared command directly; it does not parse arbitrary shell text into
capability evidence.

Use `after_create` to provision substrate needed to materialize a new
workspace, such as cloning the source or copying permitted host-local fixture
data. Use `before_run` when a per-attempt setup or dynamic check cannot be
expressed as a workspace-local resource or direct command. `before_run` runs
before source and capability verification and its success is not itself a
capability report. Redundant shell checks in `before_run` are therefore not
the preferred way to report ordinary capabilities.

After `before_run` succeeds, the host verifies every declared capability in the
current workspace for that dispatch. Any missing resource, unavailable
executable, non-zero command, timeout, or unsafe declaration fails closed. With
no declarations, the dispatch receives an explicit `not_checked` report. A
`verified` report means only that the declared checks passed at its verification
time; it is ephemeral evidence, not a permanent workspace guarantee and not a
grant of role authority.

## 7. GitHub label namespace and first issue

The current runtime does **not** reconcile a repository-wide SYMPHONY label
namespace at startup. Provision these labels in the target repository through
GitHub before opt-in:

```text
symphony:auto
symphony:role:pm
symphony:role:planner
symphony:role:reviewer
symphony:role:implementer
symphony:role:adversary
symphony:role:archivist
symphony:state:awaiting-human
symphony:state:blocked
symphony:state:lifecycle-complete
symphony:state:non-converged
```
```
set -a
source ~/.config/symphony/credentials.env
set +a

python3 - <<'PY'
import json
import os
import urllib.request
import urllib.error

repo = "<<<your_project_repo_here>>>"
token = os.environ["SYMPHONY_GITHUB_TOKEN"]

labels = [
    ("symphony:auto", "Eligible for SYMPHONY autonomous lifecycle", "5319e7"),
    ("symphony:role:pm", "Current SYMPHONY role: PM", "8250df"),
    ("symphony:role:planner", "Current SYMPHONY role: Planner", "8250df"),
    ("symphony:role:reviewer", "Current SYMPHONY role: Reviewer", "8250df"),
    ("symphony:role:implementer", "Current SYMPHONY role: Implementer", "8250df"),
    ("symphony:role:adversary", "Current SYMPHONY role: Adversary", "8250df"),
    ("symphony:role:archivist", "Current SYMPHONY role: Archivist", "8250df"),
    ("symphony:state:awaiting-human", "SYMPHONY requires human input", "fbca04"),
    ("symphony:state:blocked", "SYMPHONY lifecycle blocked", "d73a4a"),
    ("symphony:state:lifecycle-complete", "SYMPHONY lifecycle completed", "0e8a16"),
    ("symphony:state:non-converged", "SYMPHONY lifecycle exhausted without convergence", "b60205"),
]

url = f"https://api.github.com/repos/{repo}/labels"

for name, description, color in labels:
    body = json.dumps({
        "name": name,
        "description": description,
        "color": color,
    }).encode()

    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(req) as response:
            print(f"created: {name}")
    except urllib.error.HTTPError as e:
        if e.code == 422:
            print(f"already exists: {name}")
        else:
            print(f"FAILED {name}: HTTP {e.code} {e.read().decode()}")
PY
```


The host only performs bounded add/remove operations for labels on the current
issue and verifies its lifecycle projection. It does not create the complete
namespace, set label descriptions or colors, or repair unrelated repository
labels.

For a new open issue, add both `symphony:auto` and
`symphony:role:pm`. The current no-history initialization path requires the PM
role label; an auto-only issue is not converted into PM by a separate startup
preflight. Once those labels are present, the host creates the lifecycle-start
comment, preserves it as durable history, and then owns all subsequent role
and state-label transitions.

## 8. Actual operational sequence

Use this order:

1. **Project authority:** prepare the target repository's authority files,
   source, tests, and required branch content.
2. **Host prerequisites and secrets:** install/authenticate Codex, make the
   GitHub credential and integrity secret available to the host, and verify the
   authorized numeric GitHub user IDs.
3. **Instance configuration:** create the selected YAML file and ensure it
   parses with the required tracker, workspace, lifecycle, human-response, and
   runtime settings.
4. **Workspace materialization:** confirm that the `after_create` clone or
   other provisioning hook can create a new issue workspace for the configured
   branch. It runs only for a new workspace.
5. **Label namespace:** provision the labels above manually; the runtime does
   not reconcile them.
6. **Verification:** distinguish operator checks from runtime checks. The
   runtime parses and validates configuration during startup and poll cycles;
   lifecycle preparation checks the integrity secret and signed GitHub history;
   each role dispatch runs `before_run`, source-provenance verification, and
   environment-capability verification. There is no startup preflight that
   guarantees the latter checks.
7. **Runtime launch:** start the selected executable with the required
   acknowledgement flag and explicit configuration path. Startup checks the
   file path, loads the configuration, and starts polling; it does not dispatch
   a role by itself.
8. **Issue opt-in:** on an active open issue, apply `symphony:auto` and
   `symphony:role:pm`.
9. **Lifecycle operation:** polling refreshes the issue, and lifecycle
   preparation fetches/verifies comments and initializes the PM lifecycle when
   no lifecycle exists. The host then dispatches PM, Planner, Reviewer,
   Implementer, Adversary, returning PM, and—after valid convergence—Archivist
   according to the committed transition rules.
10. **Awaiting-human continuation:** if PM returns `await_human`, wait for one
    authenticated, correctly bound response comment. Do not route the next role
    manually. A valid response resumes the same PM thread and workspace in the
    next epoch.
11. **Terminal behavior:** Archivist completion removes `symphony:auto` and
    role labels, adds `symphony:state:lifecycle-complete`, and leaves the issue
    open. Budget exhaustion uses `symphony:state:non-converged`; technical or
    continuity failures use the blocked projection. Terminal issues remain
    non-dispatchable, and the workspace remains available for later
    human-authorized disposition or publication.

The host performs no automatic commit, push, pull request, merge, publication,
or issue closure.
