# Verification: the cursor-cloud harness

Active empirical evidence for firstmate's `cursor-cloud` adapter.
[`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts and [`../cursor-cloud-harness.md`](../cursor-cloud-harness.md) owns operator setup; this record owns how the API surface was established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Surface | Cursor Agents REST API, base `https://api.cursor.com` |
| Verified | 2026-08-12, including a live plan-mode run and one live agent-mode run that opened a pull request |
| Platform | macOS arm64 (Darwin 25.5.0), `curl` 8.x, `jq` 1.7.1 |
| Auth | HTTP basic, `CURSOR_API_KEY` as username with an empty password |

Every probe in the sections before "Live plan-mode run" is a READ, so none of it launched an agent or incurred run cost; `GET /v1/agents` and `GET /v1/models` are therefore the safe refresh commands.
The two live runs are the exception and were scoped accordingly: one captain-approved repository, a read-only plan-mode run, and one agent-mode run whose whole approved diff was a single line.
Response bodies are quoted with account-identifying values removed and long arrays truncated where marked.

## Auth reaches the account

```
$ curl -sS -u "$CURSOR_API_KEY": https://api.cursor.com/v1/me
{"apiKeyName":"...","userId":...,"createdAt":"...","userEmail":"...","userFirstName":"...","userLastName":"..."}
```

`GET /v1/agents` is the cheap auth check the operator doc points at, because it lists rather than creates:

```
$ curl -sS -o /dev/null -w '%{http_code}\n' -u "$CURSOR_API_KEY": https://api.cursor.com/v1/agents
200
```

## The list envelope is `items`, not `agents`

Cursor's documented example for the agent list envelope names an `agents` array.
The live API returns `items`:

```
$ curl -sS -u "$CURSOR_API_KEY": https://api.cursor.com/v1/agents | jq 'keys'
[
  "items",
  "nextCursor"
]
```

`GET /v1/repositories` uses the same `items` envelope.
Firstmate follows the live API: nothing in the adapter reads an `agents` key.
This difference matters only for list calls; the single-object launch and run responses the shim actually depends on are read defensively, accepting either the documented nesting or a flat object.

## Reasoning effort is a model parameter, and which one differs by family

This is the fact that decides how the `--effort` axis reaches Cursor at all, so it is recorded in full rather than summarized.
`GET /v1/models` is authoritative per model and lists each model's parameters with their accepted values:

```
$ curl -sS -u "$CURSOR_API_KEY": https://api.cursor.com/v1/models \
  | jq -r '.items[] | "\(.id)\t\([.parameters[]?.id]|join(","))"'
auto-smart	optimize_for
default
grok-4.5	effort,fast
composer-2.5	fast
claude-opus-5	thinking,context,effort,fast
claude-opus-4-8	thinking,context,effort,fast
gpt-5.6-sol	context,reasoning,fast
gpt-5.5	context,reasoning,fast
claude-sonnet-5	thinking,context,effort
gpt-5.6-terra	context,reasoning,fast
gpt-5.6-luna	context,reasoning,fast
gemini-3.6-flash	effort
gpt-5.4-mini	reasoning
kimi-k3	reasoning
kimi-k2.7-code
glm-5.2	reasoning
```

The accepted values differ per model as well as the parameter name:

```
$ curl -sS -u "$CURSOR_API_KEY": https://api.cursor.com/v1/models \
  | jq -c '.items[] | select(.id=="claude-opus-5" or .id=="grok-4.5" or .id=="gpt-5.6-sol" or .id=="composer-2.5")
           | {id, params: [.parameters[]? | {(.id): [.values[]?.value]}]}'
{"id":"grok-4.5","params":[{"effort":["low","medium","high"]},{"fast":["false","true"]}]}
{"id":"composer-2.5","params":[{"fast":["false","true"]}]}
{"id":"claude-opus-5","params":[{"thinking":["false","true"]},{"context":["300k","1m"]},{"effort":["low","medium","high","xhigh","max"]},{"fast":["false","true"]}]}
{"id":"gpt-5.6-sol","params":[{"context":["272k","1m"]},{"reasoning":["none","low","medium","high","xhigh","max"]},{"fast":["false","true"]}]}
```

So the Claude, Grok, and Gemini models carry effort in `effort`, the GPT, Kimi, and GLM ones in `reasoning`, `composer-2.5` carries neither, and Grok's ceiling is `high` where the Claude and GPT models reach `max`.
A static per-model table in Firstmate would be stale on Cursor's next model release, so `bin/fm-cursor-cloud.sh` resolves the parameter name and checks the requested level against that model's own accepted values at launch, dropping an unsupported level with a printed notice instead of sending a known-bad value.

Re-run the command above after a Cursor model release to refresh this table.

## Agent ids are format-validated server-side

A malformed agent path is rejected before any work, which is why the shim refuses to supervise a launch response that carried no agent and run id rather than continuing with an empty one:

```
$ curl -sS -u "$CURSOR_API_KEY": https://api.cursor.com/v1/agents/models
{"error":{"code":"validation_error","message":"Agent ID must be in the format 'bc-<uuid>'"}}
```

## Live plan-mode run

One captain-approved plan-mode run against `https://github.com/Faire/backend` at `main`, launched with `mode: "plan"` and `autoCreatePR: false`, so it read the repository and opened no pull request.
It exercised launch, the event stream, the status mapping, the queue-while-running steer path, a follow-up run, terminal reconciliation, cancellation, and shim exit.
Observed, in order:

```
[cursor-cloud] agent bc-9637084d-... run run-aff7cd3f-... (RUNNING) https://cursor.com/agents/bc-9637084d-...
[cursor-cloud] status: working: cursor cloud run run-aff7cd3f-... under way
[cursor-cloud] steer QUEUED (1 waiting): run run-aff7cd3f-... is RUNNING and only one run may be active. ...
[cursor-cloud] run run-aff7cd3f-... status FINISHED
[cursor-cloud] result FINISHED
[cursor-cloud] status: done: This repo has many top-level services ... (no PR opened)
[cursor-cloud] submitting queued steer(s) now that the run is FINISHED
[cursor-cloud] steer submitted as run run-e91cf25e-... (CREATING)
[cursor-cloud] cancelling run run-e91cf25e-...
[cursor-cloud] cancel cancelled
[cursor-cloud] status: failed: run cancelled
[cursor-cloud] exit requested
```

Both runs were confirmed terminal from the run endpoint afterwards, so the shim left nothing active:

```
$ curl -sS -u "$CURSOR_API_KEY": .../runs/run-e91cf25e-... | jq -c '{status, durationMs, git}'
{"status":"CANCELLED","durationMs":16485,"git":{"branches":[{"repoUrl":"github.com/Faire/backend","branch":"cursor/service-structure-and-endpoints-5d24"}]}}
$ curl -sS -u "$CURSOR_API_KEY": .../runs/run-aff7cd3f-... | jq -c '{status, git}'
{"status":"FINISHED","git":{"branches":[{"repoUrl":"github.com/Faire/backend","branch":"cursor/service-structure-and-endpoints-5d24"}]}}
```

Three shapes in that output differ from what the documented examples suggest, and the adapter follows the live API:

- `git.branches[].repoUrl` carries NO scheme (`github.com/Faire/backend`). A raw string comparison against the task's own `https://...` repository URL would never match, leaving the repository selection silently dead and, on a multi-repository agent, able to attribute another repository's branch and pull request to the task. `reconcile` normalizes both sides to a scheme-less, userless, suffix-less, lowercase identity.
- `agent.url` is `https://cursor.com/agents/<agent-id>`.
- `assistant` and `thinking` events arrive as token DELTAS, several per second, each a fragment of a word. Rendering one prefixed pane line per event buried the run in fragments, so consecutive deltas of the same kind are coalesced onto one line, closed when the kind changes or another event arrives.

A plan-mode run still reported a `git.branches[]` entry with a branch name and no `prUrl`, which is why a `FINISHED` run without a pull request has its own status line rather than being treated as an error.

## Live agent-mode run with a pull request

One captain-approved agent-mode run against the same repository, launched with `autoCreatePR: true` and a prompt whose whole approved change was one line in one file.
It finished in 267557 ms and the pull request URL arrived exactly where the mapping expects it:

```
[cursor-cloud] result FINISHED
[cursor-cloud] PR https://github.com/Faire/backend/pull/289204
[cursor-cloud] status: done: PR https://github.com/Faire/backend/pull/289204
```

```
$ curl -sS -u "$CURSOR_API_KEY": .../runs/run-d4b2ef76-... | jq -c '{status, durationMs, pr: .git.branches[0].prUrl}'
{"status":"FINISHED","durationMs":267557,"pr":"https://github.com/Faire/backend/pull/289204"}
```

This run also delivered 24 live `tool_call` frames, which the plan-mode run never produced, so that renderer is live-verified too.

It exposed one renderer defect worth keeping recorded, because the obvious fix is the wrong one.
The first delta-coalescing attempt closed the open line before ANY non-delta event.
The live stream interleaves frames this renderer prints nothing for, so that blanket close fired between consecutive tokens and re-printed the prefix on every single one - the exact fragmenting the coalescing exists to stop.
The line is now closed only before an event that actually prints something (`status`, `tool_call`, `result`, `error`), and `tests/fm-cursor-cloud.test.sh` drives a silent frame between two deltas so the regression cannot come back.

## Agent status is not run status

`GET /v1/agents` and `GET /v1/agents/{id}` report an AGENT-level `status` from a different vocabulary than a run's: `ACTIVE` or `ARCHIVED`, describing the agent record rather than any work in progress.

```
$ curl -sS -u "$CURSOR_API_KEY": https://api.cursor.com/v1/agents/bc-64b06942-... | jq -c '{status, latestRunId}'
{"status":"ACTIVE","latestRunId":"run-d4b2ef76-..."}
```

That agent read `ACTIVE` while its only run was already `FINISHED`, so an agent reading `ACTIVE` is NOT evidence of a run still consuming resources, and cancelling on that basis would destroy finished work.
Nothing in the adapter reads agent-level status: every liveness and cancellation decision reads the RUN status recorded for the task.

The same call also shows the agent list is ACCOUNT-WIDE, returning agents this fleet never launched, which is the second reason firstmate must never enumerate-and-act: the task's own run record binds exactly one agent and one run, and that binding is the only thing teardown or a cancel ever addresses.

## What is not verified here

- No live `error` frame was observed, so that renderer is test-covered only.
- The `env` object's accepted `type` values are taken from Cursor's documentation; only the `cloud` form is used, and only when `config/cursor-cloud-env` names an environment. The live run passed no `env` and the cloud agent resolved the repository's own environment on its own.
- The dropped-stream reconnect path was not forced live; it is pinned by `tests/fm-cursor-cloud.test.sh`, which drives a stream that ends without a terminal event, a run endpoint that still reads `RUNNING`, and an exhausted retry budget.

## Refresh

```sh
curl -sS -u "$CURSOR_API_KEY": https://api.cursor.com/v1/agents | jq 'keys'
curl -sS -u "$CURSOR_API_KEY": https://api.cursor.com/v1/agents/<agent-id>/runs/<run-id> | jq -c '{status, git}'
curl -sS -u "$CURSOR_API_KEY": https://api.cursor.com/v1/models | jq -r '.items[] | "\(.id)\t\([.parameters[]?.id]|join(","))"'
bash tests/fm-cursor-cloud.test.sh
```
