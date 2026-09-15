# Project Onboarding

This document describes how to attach a fresh GitHub project repository to
SYMPHONY, from a repository with no SYMPHONY configuration through the first
eligible issue being observed by the polling runtime.

Project onboarding configures one project-scoped runtime instance. It does not
define or customize the shared SYMPHONY lifecycle.

## End state

A project is onboarded when:

1. the repository contains project authority appropriate for coding agents;
2. `.symphony/instance_config.yml` binds the repository to one SYMPHONY runtime;
3. host credentials authorize the required bounded GitHub operations;
4. SYMPHONY has reconciled its managed GitHub label namespace;
5. project workspace materialization has been validated;
6. the runtime is polling successfully;
7. an open issue carrying `symphony:auto` is recognized as eligible and begins
   the host-owned lifecycle at PM without manual lifecycle routing.

No human should manually create or maintain SYMPHONY role/state labels.

---

## 1. Project authority

Before SYMPHONY is configured, the target repository should contain the project
semantics an agent needs to work correctly.

Typical sources include:

- `AGENTS.md`;
- project specifications or harness documentation;
- source code;
- tests;
- fixture contracts;
- implementation plans.

These artifacts define the project.

They MUST NOT redefine SYMPHONY lifecycle topology, role semantics, lifecycle
budgets, PM persistence, or host authority.

SYMPHONY owns those mechanics.

---

## 2. Host prerequisites

The operator host must have:

- the accepted SYMPHONY runtime installed;
- Codex installed and authenticated;
- the required runtime model configuration available;
- a GitHub credential available outside the target repository;
- permission for that credential to access the target repository and perform
  the bounded issue/comment/label operations required by SYMPHONY.

Example host secret:

`~/.config/symphony/credentials.env`

```bash
SYMPHONY_GITHUB_TOKEN=...
```

Secrets MUST NOT be committed to the project repository.

## 3. Add project instance configuration

Create:

.symphony/instance_config.yml

The instance configuration describes project-specific mechanics only.

At minimum it binds:

GitHub repository;
host-side credential reference;
opt-in label;
polling interval;
workspace root;
workspace materialization;
concurrency;
Codex command/runtime configuration.

Example:

```
tracker:
  kind: github
  provider:
    repo: "owner/project"
    token: $SYMPHONY_GITHUB_TOKEN
  required_labels:
    - symphony:auto
  active_states:
    - open
  terminal_states:
    - closed

polling:
  interval_ms: 5000

workspace:
  root: ~/code/symphony-workspaces/project

hooks:
  after_create: |
    set -eu
    git clone --depth 1 https://github.com/owner/project.git .

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

Commit and push this configuration before launching the project runtime.

## 4. Materialize project-local untracked dependencies

If the project requires host-local data that MUST NOT be committed, the
workspace hook is responsible for materializing it.

Examples include:

licensed/local PDFs;
private fixture data;
generated local inputs;
other ignored runtime assets.

The canonical host copy should live outside the repository.

after_create copies or links the required substrate into the issue workspace.

before_run SHOULD validate required substrate and fail explicitly when it is
missing.

Agents should consume ordinary workspace-local paths. They should not depend
on arbitrary visibility into the operator's home directory.

## 5. Reconcile the SYMPHONY GitHub namespace

Before dispatch polling becomes active, the host MUST ensure the target
repository contains the SYMPHONY-managed labels required by the shared
lifecycle.

Managed labels:

```
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

Provisioning MUST be idempotent.

Existing correct labels are left intact.

A missing label is created by the host.

Failure to read or provision the required namespace is an onboarding/startup
failure and MUST be surfaced explicitly.

```bash
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

## 6. Validate before polling

Project startup SHOULD fail before dispatch if any required onboarding
condition is not satisfied.

Validate at minimum:

instance configuration parses;
target repository is reachable;
GitHub credential is accepted;
required label namespace exists;
workspace root is usable;
Codex executable is available;
required model configuration is present;
project workspace creation/materialization succeeds or can succeed;
required host-local substrate checks are valid.

Validation must not dispatch a coding role.

## 7. Start the project runtime

Load host credentials:

```
set -a
source ~/.config/symphony/credentials.env
set +a
```

Then launch the project instance:

```
symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$HOME/.local/state/symphony/<project>-live" \
  --port <project-port> \
  /path/to/project/.symphony/instance_config.yml
```

A successful idle startup means:

configuration valid
→ GitHub reachable
→ managed labels reconciled
→ polling active
→ zero eligible issues
→ zero Codex executions

Idle polling is the expected state before an issue is opted in.

## 8. Opt in the first issue

Create an ordinary GitHub issue describing real project work.

The human applies only:

`symphony:auto`

The human does NOT select a role.

For a newly opted-in issue with:

no existing SYMPHONY lifecycle history;
no terminal SYMPHONY state;
no conflicting managed role projection;

the host deterministically initializes the shared lifecycle:

```
symphony:auto
      ↓
host recognizes new lifecycle
      ↓
projects symphony:role:pm
      ↓
dispatches PM
```

From that point onward, all role/state transitions are host-owned.

The human is not the lifecycle transition function.

## 9. Normal polling behavior

Once initialized:

```
GitHub issue
    ↓
poll
    ↓
validate current lifecycle projection/history
    ↓
dispatch exactly one legal current role
    ↓
validate role result
    ↓
persist handoff/comment
    ↓
project next role/state
    ↓
next poll
```

The project repository does not route itself.

Agents do not mutate GitHub.

The host owns GitHub lifecycle projection.

## 10. Successful terminal behavior

Successful lifecycle termination leaves the project issue open and projects:

symphony:state:lifecycle-complete

The host removes:

symphony:auto;
the current role label.

Later polling of a correct terminal projection is read-only and produces no
additional GitHub mutation.

Publication, commit, PR creation, merge, and issue closure remain separate from
lifecycle completion.

Onboarding invariant

From a fresh project repository to autonomous polling, the human should be
responsible only for:

supplying project authority;
supplying project-specific runtime mechanics;
granting the host credential access to the repository;
starting the project runtime;
opting real work in with symphony:auto.

Everything else required by the shared SYMPHONY lifecycle is SYMPHONY's job.


And the important realization is that this document would expose **two small missing onboarding capabilities in the runtime**, not just missing documentation:

```text
repo label provisioning
+
new opted-in issue → deterministic PM initialization
```
