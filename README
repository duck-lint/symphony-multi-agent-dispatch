# SYMPHONY Multi-Agent Dispatch

**Task-centered engineering orchestration with host-governed handoffs.**

SYMPHONY Multi-Agent Dispatch extends [OpenAI's Symphony](https://github.com/openai/symphony) with a defined, multi-role engineering lifecycle. It coordinates planning, review, execution, adversarial examination, and convergence without requiring a human to route every handoff between coding agents.

A task might ask for a feature, a specification revision, a failure investigation, or a red-team assessment. **The whole lifecycle applies to the task.** A red-team task, for example, is planned, reviewed, executed, challenged, and evaluated; it does not simply skip to the Adversary. Specialist roles are responsibilities *within* the process, not categories limiting what can be a task.

The current implementation uses GitHub issues as the task identity, scheduling interface, and durable lifecycle substrate. The task is the unit of engineering intent; GitHub is how this MVP represents and runs it.

> **Status:** Usable experimental engineering preview for trusted, operator-controlled environments. Development and real-project validation are ongoing. See [current runtime state](docs/current-state.md) for verified behaviour, outstanding evidence, and deployment requirements. Lifecycle completion is not a declaration that code is safe or ready to merge.

## The problem

Coding agents can investigate and change repositories, but a multi-step engineering task still requires someone to keep the objective in view, select the next responsibility, communicate findings, handle revisions, and distinguish an executed step from an accepted result. Doing that manually for every agent makes the human the workflow's transition function.

SYMPHONY moves *routine coordination* into the host. The human supplies the task and its governing project authority; specialists perform bounded work; the host validates structured results, selects legal next steps, and records accepted transitions. The human remains responsible for project decisions and final disposition.

This is an orchestration and accountability design, **not** a claim that adding roles guarantees better code, independent verification of agent claims, or cheaper inference.

## How a task progresses

```text
Task opted in through a GitHub issue
              |
              v
       PM (task-scoped)
              |
              v
       Planner (fresh) <---------+
              |                 |
              v                 | revision
       Reviewer (fresh) --------+
              | accepted plan
              v
       Implementer (fresh; bounded workspace writes)
              |
              v
       Adversary (fresh)
              |
              v
       Same PM (resume)
          |           |
    another round   converge
          |           |
       Planner        v
                    Archivist (fresh)
                       |
                       v
                Lifecycle complete
                (issue stays open)
```

The host also represents precise human escalations, blocked states, and non-convergence rather than silently treating them as completion. Each specialist runs on a fresh Codex thread; the PM alone has task-scoped thread continuity. A specialist may conduct its own bounded inquiry, but this does not mean the runtime recursively launches a complete nested lifecycle.

## What the host owns

- **Transitions:** role results follow a strict schema; the host validates them and determines the next legal state. Agents do not choose arbitrary successor roles.
- **Execution authority:** five roles have read-only project access; only the Implementer receives bounded project-workspace write access. Role policy is host-owned, not overridable by project configuration.
- **Continuity:** the PM resumes its task-specific Codex thread; missing continuity fails visibly rather than being silently replaced.
- **Evidence and recovery:** GitHub labels project current lifecycle state; append-only host-written issue comments preserve accepted handoffs. The host reconstructs history from this ledger and uses deterministic transition IDs to handle retries.
- **Environment evidence:** optional project-declared resource and command checks are verified by the host before dispatch; their time-bounded result is shared with roles, not treated as a permanent guarantee or a permission grant.

Only the host performs the limited GitHub issue/comment/label mutations required for the lifecycle. The MVP does **not** automatically commit, push, open or merge PRs, publish work, or close the task issue. Completing the lifecycle and accepting changes into a project are separate decisions.

## Get started

This is currently an operator-deployed tool, not a one-click hosted service.

1. Prepare a trusted Linux/WSL environment with the repo-declared toolchain, an installed/authenticated Codex CLI, and GitHub credentials kept outside the target repository. Follow [development and packaging](docs/development-and-packaging.md) for the source-build path.
2. Give the target project its own `AGENTS.md` and relevant specifications/tests. Add a project-local `.symphony/instance_config.yml` describing the GitHub repository, workspace, runtime, and optional verified environment capabilities. Follow [project onboarding](docs/project-onboarding.md) for the configuration contract.
3. Start the installed executable with your target project's configuration:

   ```bash
   symphony \
     --i-understand-that-this-will-be-running-without-the-usual-guardrails \
     --logs-root "$HOME/.local/state/symphony/project" \
     /path/to/project/.symphony/instance_config.yml
   ```

4. Opt in a well-scoped, open GitHub issue using `symphony:auto`. The host initializes and owns the subsequent role transitions. Review the issue ledger and resulting workspace before taking any publication action.

The startup acknowledgement reflects the project's experimental risk posture. Role restrictions reduce granted capabilities but are **not** proof of comprehensive sandbox security. Do not use an untrusted repository, sensitive credentials, or unsupervised production infrastructure as a first deployment. See [security and threat assumptions](SECURITY.md).

## Documentation and project authority

| Document | Purpose |
| --- | --- |
| [Project onboarding](docs/project-onboarding.md) | Configure a project-scoped runtime and opt in work. |
| [Current runtime state](docs/current-state.md) | Authoritative operational details, live evidence, limitations, and deployment provenance. |
| [Development and packaging](docs/development-and-packaging.md) | Maintainer build/validation procedure. |
| [AGENTS.md](AGENTS.md) | Repository instructions and authority boundaries for contributors/agents. |
| [MVP invariants](harness/SYMPHONY-multi-agent-dispatch_MVP_INVARIANTS.md) | Accepted lifecycle contract and rebuild guardrails. |
| [Security](SECURITY.md) | Trust model, capability boundaries, known limitations, and reporting. |

## Origins and license

This project is an upstream-derived extension of [OpenAI Symphony](https://github.com/openai/symphony), not an official OpenAI product. It retains upstream foundations and adds the task-governed multi-role lifecycle and associated authority/evidence contracts. See [NOTICE](NOTICE) for attribution and [LICENSE](LICENSE) for Apache-2.0 licensing.
