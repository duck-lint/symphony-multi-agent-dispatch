# Security policy and trust model

## Scope and deployment posture

SYMPHONY Multi-Agent Dispatch is an experimental engineering preview intended for trusted, operator-controlled environments. It is not a security-certified isolation boundary or a managed service. Do not assume agent output is correct, that repository instructions are trustworthy, or that successful lifecycle completion constitutes security review or permission to publish.

## Relevant authority boundaries

- The human and target project's authoritative documents define task scope and acceptance requirements. Agent output does not amend those requirements.
- The host validates role results and routes only legal transitions. Models do not receive GitHub mutation tools; the host performs bounded current-issue lifecycle reads, label changes, and append-only comments.
- PM, Planner, Reviewer, Adversary, and Archivist receive read-only project policies. The Implementer alone receives bounded workspace-write authority; it is not authorized to manipulate `.git`, commit, push, merge, or publish.
- Role runtime policies disable network access for model execution. Whether a restriction withstands an attack also depends on the underlying runtime, sandbox, host, credentials, and deployment configuration; no general resistance guarantee is claimed.
- GitHub labels and append-only host-written comments are the durable lifecycle record. Host-local PM metadata exists for thread reconnection, not as a competing lifecycle authority. Issue comments contain reported evidence, not independently verified truth.
- Optional `environment.capabilities` declarations are host-checked before a dispatch. A verified result describes checks at a specific time; it is not a permission grant, a continuous monitor, or proof of every dependency's integrity.

## Operator responsibilities

Use narrowly scoped GitHub credentials stored outside the project repository and workspace. Protect Codex credentials and host-local PM continuity state. Keep deployment and workspace permissions restricted, inspect executable build provenance, and review changed files before committing or publishing. Treat issue text, repositories, test output, and model-generated handoffs as potentially untrusted content. Preserve human review for high-impact or sensitive work.

## Known limitations

The host can enforce structural contracts and selected execution policies; it cannot establish that an agent examined every alternative, that evidence claims are factually true, or that a review found every defect. Representative live testing remains ongoing across failure/revision/recovery paths and deployment targets. The current acceptance evidence and open gaps belong in [current runtime state](docs/current-state.md), not in fixed security promises.

## Reporting vulnerabilities

Please do not publish exploit details, secrets, or active vulnerabilities in public issues. If this repository has GitHub private vulnerability reporting enabled, use the **Report a vulnerability** option under its Security tab. If that option is unavailable, do not assume a confidential reporting channel exists; the maintainer must establish one before inviting sensitive vulnerability reports. Non-sensitive, reproducible defects may be filed as ordinary issues.

No security-response SLA or supported production version is currently promised.
