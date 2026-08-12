# Verification: the cursor-cloud harness

Active empirical evidence for firstmate's `cursor-cloud` adapter.
[`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts and [`../cursor-cloud-harness.md`](../cursor-cloud-harness.md) owns operator setup; this record owns how the API surface was established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Surface | Cursor Agents REST API, base `https://api.cursor.com` |
| Verified | 2026-08-12 |
| Platform | macOS arm64 (Darwin 25.5.0), `curl` 8.x, `jq` 1.7.1 |
| Auth | HTTP basic, `CURSOR_API_KEY` as username with an empty password |

Every probe below is a READ, so none of it launched an agent or incurred run cost.
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

## What is not verified here

- The launch, follow-up, run-read, stream, and cancel responses are exercised against a mocked HTTP layer in `tests/fm-cursor-cloud.test.sh` and against Cursor's documented shapes, not yet against a live run. A live end-to-end smoke needs a captain-approved target repository, because launching a cloud agent that opens a pull request is outward-facing.
- The `env` object's accepted `type` values are taken from Cursor's documentation; only the `cloud` form is used, and only when `config/cursor-cloud-env` names an environment.
- No Server-Sent-Events frame has been read from the live stream endpoint. The decoder is pinned instead by `tests/fm-cursor-cloud.test.sh`, which drives complete frames, a payload split across `data:` lines, keepalive comments, CRLF line endings, and a frame the stream never terminated.

## Refresh

```sh
curl -sS -u "$CURSOR_API_KEY": https://api.cursor.com/v1/agents | jq 'keys'
curl -sS -u "$CURSOR_API_KEY": https://api.cursor.com/v1/models | jq -r '.items[] | "\(.id)\t\([.parameters[]?.id]|join(","))"'
bash tests/fm-cursor-cloud.test.sh
```
