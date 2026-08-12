# cursor-cloud harness

`cursor-cloud` runs a task's work as a Cursor Cloud Agent over Cursor's Agents REST API instead of as a terminal-UI agent on your machine.

It is a HARNESS, not a runtime backend.
The task still gets an ordinary isolated git worktree and an ordinary session endpoint on whichever runtime backend you already use, and Firstmate supervises it through the same pane, status, busy-state, control, and cleanup machinery as any local worker.
What differs is only what runs inside that endpoint: a Firstmate shim, `bin/fm-cursor-cloud.sh`, which launches the cloud agent, renders its event stream so the pane stays readable, and reads plain lines from its input so `bin/fm-send.sh` steers it exactly as it steers a terminal UI.

The verified adapter facts live in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md), and [`verification/cursor-cloud.md`](verification/cursor-cloud.md) records how the API shapes were established.

## Setup

Pick `cursor-cloud` when the work suits a hosted agent that pushes a branch and opens a pull request, and when you would rather not spend a local machine on it.

Prerequisites:

- A Cursor account with Cloud Agents available, and the repository already connected to it.
- `CURSOR_API_KEY` exported in the environment the task's session endpoint inherits.
- `curl` and `jq`, plus the universal requirements in [`configuration.md`](configuration.md#toolchain).

Select it the way you select any crewmate harness: `config/crew-harness` containing `cursor-cloud`, a `config/crew-dispatch.json` rule that resolves to it, or an explicit per-task request to Firstmate.

## The API key

Auth is HTTP basic with the key as the username and an empty password.
The shim hands the key to `curl` through a `-K -` config on standard input, so it appears neither in a process argument list nor on disk, and the shim never prints it - including on error paths and in status lines.

Export it in the environment the session provider's own daemon inherits, not just in your interactive shell: a long-lived tmux or Herdr server does not pick up a variable you exported afterwards.
Verify a key cheaply with a list call, which launches nothing and costs nothing:

```sh
curl -sS -u "$CURSOR_API_KEY": https://api.cursor.com/v1/agents
```

An unset key is a loud refusal before any request is attempted, reported as a needed credential rather than as a wedged worker.

## Pinning a Cursor environment (config/cursor-cloud-env)

By default a run uses Cursor's default cloud environment.
`config/cursor-cloud-env` is a local, gitignored file holding one line: the `name` of an already-configured Cursor environment to pin runs to instead.
Blank lines and `#` comments are ignored, and the first remaining line wins.

```sh
printf '%s\n' 'My service (cloud agent)' > config/cursor-cloud-env
```

Leave the file absent when the repository already carries its own `.cursor/environment.json`: the cloud agent picks that up on its own, and pinning a name is only needed to override it.
Like the other `config/` files this one is inherited by secondmate homes; see [`configuration.md`](configuration.md#cursor-cloud-environment-configcursor-cloud-env).

## Steering: one run at a time

The API allows a single active run per agent, so steers cannot always be delivered the moment they arrive.

- A steer that arrives while the run is `CREATING` or `RUNNING` is QUEUED, and the pane says so on the line it queues, stating plainly that the steer has NOT been delivered yet.
  It is submitted as the next run once the current one reaches a terminal state; several queued steers are submitted together as one follow-up.
- A steer that arrives with no run active is submitted immediately as a follow-up run.
- The literal line `!cancel` cancels the live run instead of queueing.
- The literal line `!exit` cancels any live run and stops the shim; it is what the control plane's `exit` verb submits.

Delivery confirmation does not read a composer, because the shim draws none.
It reads the shim's own accepted-input counter in the task's run record instead, which is a stronger acknowledgement than any rendered screen: the counter advances only after the shim has actually read the line.

`bin/fm-control.sh <id> interrupt` cancels the active run through the API rather than sending a key, since no key press typed into the pane could stop a cloud run, and it confirms the cancellation from the run's own terminal status.

## Delivery is direct-PR only

Firstmate's `no-mistakes` validation pipeline runs in a local worktree with local tooling, and none of that exists inside a cloud agent, so a `cursor-cloud` task cannot run it.

Every `cursor-cloud` ship task is therefore `direct-PR`: the run is launched with `autoCreatePR`, and the pull request the cloud agent opens IS the deliverable.
Do not select `no-mistakes` for a cloud-executed task, and do not treat a cloud agent's own self-review as a substitute for it.
When a change needs the full pipeline, run it on a local harness instead.

Because the deliverable is a pull request rather than local commits, the local worktree normally stays clean.
When a run finishes, the shim fetches the branch the cloud agent pushed into that worktree as a remote-tracking ref, so the work is inspectable from the task's own local copy.
It deliberately does not check the branch out and creates no local branch: inventing local commits would leave refs behind in the shared repository and could confuse the landed-work test.
That test itself is untouched for this harness - a `cursor-cloud` teardown refuses dirty or unlanded work exactly like any other.

## Cost, and never leaving a run orphaned

A launched cloud run bills until it finishes or is cancelled, and nothing consumes its output once its shim is gone, so an abandoned run is pure waste.

Two independent paths prevent one:

- The shim cancels any still-active run when it exits, including on an interrupt, a `!exit`, or a terminated pane.
- `bin/fm-teardown.sh` cancels a still-active run itself, in case the shim was already gone. It does this only once teardown is committed - after every landed-work and endpoint check has passed - because cancelling a run for a teardown that is then refused would destroy work the task still owns. A cancel it cannot confirm is reported as a warning naming the agent console, never swallowed.

Watch runs and costs at <https://cursor.com/agents>.

## Status lines

The shim appends to the task's status file sparsely: one line when the run starts, and one when it reaches a terminal state.

| Run status | Status line |
|---|---|
| `CREATING`, `RUNNING` | `working: cursor cloud run <runId> under way`, appended once at launch rather than per event |
| `FINISHED` with a pull request | `done: PR <url>` |
| `FINISHED` without one | `done: <result summary> (no PR opened)` |
| `ERROR` | `failed: <message>` |
| `CANCELLED` | `failed: run cancelled` |
| `EXPIRED` | `failed: run expired` |

A lost event stream is never one of those.
The stream is reconnected with backoff, and each attempt reconciles against `GET /v1/agents/{id}/runs/{runId}`, which is the only authority on whether a run is terminal - a dropped connection must never be reported as a finished or failed run.
Only once the retry budget is spent does the shim append `blocked: lost contact with cloud run <runId>`, which says the run may still be running rather than claiming an outcome.

## Active limits

- Crewmate and scout tasks only. `fm-spawn.sh` refuses a secondmate on this harness: the pane runs one cloud task, not a firstmate instance that could hold a session lock and supervise a fleet.
- `direct-PR` delivery only, as above.
- One active run per agent, so steers queue.
- The task's own machine runs no build, test, or tool for the work; whatever the cloud environment provides is what the agent has.
- Reasoning effort is a Cursor model PARAMETER rather than a flag, and which parameter carries it differs by model family, so the shim resolves it from Cursor's own model catalog at launch and drops a level the chosen model does not accept.

## Regression entry points

```sh
tests/fm-cursor-cloud.test.sh
tests/fm-tmux-agent-liveness.test.sh
```

The first mocks the HTTP layer and needs no key or network.
The second pins the pane-process identity that keeps a live cloud worker from reading as an idle shell.
