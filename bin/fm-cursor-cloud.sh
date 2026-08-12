#!/usr/bin/env bash
# bin/fm-cursor-cloud.sh - the cursor-cloud harness shim: the long-running
# foreground process a cursor-cloud task's pane runs instead of a terminal UI.
#
# cursor-cloud is a HARNESS, not a runtime backend. The task still gets an
# ordinary isolated worktree and an ordinary pane on the session provider
# firstmate already uses; what differs is only what runs inside that pane. The
# work itself happens in Cursor's cloud, driven through its Agents REST API, so
# this shim is what makes a remote agent supervisable by the same pane, status,
# busy-state, control, and teardown machinery as a local one:
#
#   * it launches the cloud agent (POST /v1/agents),
#   * it consumes that run's event stream (GET .../runs/{runId}/stream) and
#     renders it to stdout, so the pane is human-readable,
#     appends firstmate status lines sparsely,
#   * it records its own explicit state in the run record owned by
#     bin/fm-cursor-cloud-lib.sh, so the busy verdict and the teardown
#     cancellation read a fact rather than a rendered screen, and
#   * it reads STDIN line by line, so bin/fm-send.sh steers it exactly as it
#     steers a terminal UI.
#
# Usage:
#   fm-cursor-cloud.sh run --id <task-id> --state <state-dir> --worktree <path>
#                          --brief <path> [--busy-gen <token>]
#                          [--repo <url>] [--starting-ref <ref>]
#                          [--model <id[k=v,...]>] [--effort <level>]
#                          [--mode agent|plan] [--no-pr] [--env-name <name>]
#   fm-cursor-cloud.sh cancel <state-dir> <id>
#   fm-cursor-cloud.sh sse-decode        decode an SSE stream on stdin
#
# ONE RUN AT A TIME. The API allows a single active run per agent, so an
# incoming steer that arrives while a run is CREATING or RUNNING is QUEUED and
# submitted as the next run (POST /v1/agents/{id}/runs) once the current one
# reaches a terminal state. The pane says so explicitly on the line it queues,
# because a supervisor reading the pane must never be left thinking a queued
# steer already landed. The single exception is the literal line `!cancel`,
# which cancels the live run instead of queueing. The literal line `!exit`
# cancels any live run and stops the shim, and is what bin/fm-control.sh's
# `exit` verb submits.
#
# DELIVERY IS direct-PR ONLY. Firstmate's own validation pipeline cannot run
# inside the cloud agent, so the run is launched with autoCreatePR and the pull
# request the cloud agent opens IS the deliverable. See
# docs/cursor-cloud-backend.md.
#
# AUTH is CURSOR_API_KEY, sent as HTTP basic auth with the key as the username
# and an empty password. It is handed to curl through a `-K -` config on stdin,
# so it appears neither in a process argument list nor on disk, and it is never
# printed - including on error paths and in status lines.
#
# COST. A launched cloud run bills until it finishes or is cancelled, so the
# shim cancels any still-active run when it exits, and bin/fm-teardown.sh
# cancels one independently in case the shim is already gone.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-cursor-cloud-lib.sh
. "$SCRIPT_DIR/fm-cursor-cloud-lib.sh"

CC_BASE=${FM_CURSOR_CLOUD_BASE:-https://api.cursor.com}
CC_STREAM_RETRIES=${FM_CURSOR_CLOUD_STREAM_RETRIES:-5}
CC_CANCEL_WAIT=${FM_CURSOR_CLOUD_CANCEL_WAIT:-20}
CC_POLL=${FM_CURSOR_CLOUD_POLL:-1}
# `read -t` takes a WHOLE-SECOND timeout on bash 3.2, the /bin/bash macOS still
# ships, where a fractional one fails outright rather than degrading - which
# would spin the wait loop without ever reading its channels. The wait loop
# therefore rounds up to whole seconds instead of depending on bash 4+, while
# CC_POLL keeps its exact value for the sleeps that accept a fraction.
CC_READ_TIMEOUT=$(awk -v p="$CC_POLL" 'BEGIN{t=int(p); if (t < p) t++; if (t < 1) t = 1; print t}')
# U+001F UNIT SEPARATOR: the one field separator that is not IFS whitespace, so
# `read` preserves empty fields instead of collapsing a run of them.
CC_US=$(printf '\037')

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {  # <message>
  printf 'error: %s\n' "$1" >&2
  exit 1
}

say() {  # <message>
  printf '[cursor-cloud] %s\n' "$1"
}

require_api_key() {
  [ -n "${CURSOR_API_KEY:-}" ] \
    || die "CURSOR_API_KEY is not set; the cursor-cloud harness cannot reach the Cursor Agents API without it. Export it in the environment this pane inherits, and never write it into a file firstmate tracks."
}

# cc_curl: one curl invocation with the API key supplied through a `-K -`
# config on stdin. The key is deliberately kept out of the argument list, and
# stdin is the config pipe rather than this process's own stdin, so a network
# call can never consume a steer typed into the pane.
cc_curl() {  # <curl-args>...
  printf 'user = "%s:"\n' "$CURSOR_API_KEY" | curl -sS -K - "$@"
}

# cc_api: <method> <path> [body-file] -> body in $CC_RESP, HTTP status on stdout.
cc_api() {
  local method=$1 path=$2 body=${3:-}
  local args
  args=(-X "$method" -o "$CC_RESP" -w '%{http_code}')
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' --data-binary "@$body")
  fi
  cc_curl "${args[@]}" "$CC_BASE$path"
}

cc_api_error() {  # <what> <code>
  local message
  message=$(jq -r '(.error.message // .message // empty)' "$CC_RESP" 2>/dev/null) || message=
  [ -n "$message" ] || message=$(head -c 300 "$CC_RESP" 2>/dev/null | tr '\n' ' ')
  printf '%s failed (HTTP %s): %s' "$1" "$2" "${message:-no response body}"
}

# --- cancel -----------------------------------------------------------------

# cc_cancel_run: cancel one run and confirm it from GET .../runs/{runId}, the
# only authority on terminal state. Prints the outcome:
#   none              no active run is recorded for this task
#   already-terminal  the recorded run had already stopped
#   cancelled         the run is confirmed terminal after the cancel
#   unconfirmed       the cancel was accepted but no terminal state was observed
cc_cancel_run() {  # <state-dir> <id>
  local state=$1 id=$2 agent run status code elapsed=0
  agent=$(fm_cursor_cloud_record_get "$state" "$id" agent)
  run=$(fm_cursor_cloud_record_get "$state" "$id" run)
  status=$(fm_cursor_cloud_record_get "$state" "$id" status)
  if [ -z "$agent" ] || [ -z "$run" ]; then
    printf 'none'
    return 0
  fi
  if fm_cursor_cloud_status_terminal "$status"; then
    printf 'already-terminal'
    return 0
  fi
  code=$(cc_api POST "/v1/agents/$agent/runs/$run/cancel") || code=000
  case "$code" in
    2*) ;;
    *)
      printf 'unconfirmed'
      return 0
      ;;
  esac
  while :; do
    code=$(cc_api GET "/v1/agents/$agent/runs/$run") || code=000
    case "$code" in
      2*)
        status=$(jq -r '.status // empty' "$CC_RESP" 2>/dev/null) || status=
        if fm_cursor_cloud_status_terminal "$status"; then
          fm_cursor_cloud_record_set "$state" "$id" "status=$status" || true
          printf 'cancelled'
          return 0
        fi
        ;;
    esac
    awk -v e="$elapsed" -v t="$CC_CANCEL_WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$CC_POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$CC_POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf 'unconfirmed'
}

# --- the run subcommand -----------------------------------------------------

ID=
STATE=
WT=
BRIEF=
BUSY_GEN=
REPO=
STARTING_REF=
MODEL=
EFFORT=
RUN_MODE=agent
AUTO_PR=true
ENV_NAME=
AGENT_ID=
RUN_ID=
RUN_STATUS=
WORKING_ANNOUNCED=0
STDIN_OPEN=1
STDIN_SEQ=0
STDIN_FAIL_BURST=0
LOST_CONTACT=0
STREAM_PID=
CC_TMP=
CC_RESP=
STEER_QUEUE=
STEER_QUEUE_N=0

cleanup() {
  local outcome
  if [ -n "$STREAM_PID" ]; then
    kill "$STREAM_PID" 2>/dev/null || true
    STREAM_PID=
  fi
  if [ -n "$AGENT_ID" ] && [ -n "$RUN_ID" ] && [ -n "$STATE" ] && [ -n "$ID" ]; then
    if ! fm_cursor_cloud_status_terminal "$RUN_STATUS"; then
      # A run left running bills until it stops, and nothing consumes its
      # output once this shim is gone.
      outcome=$(cc_cancel_run "$STATE" "$ID" 2>/dev/null || printf 'unconfirmed')
      say "shim exiting: active run cancel=$outcome"
    fi
  fi
  [ -z "$CC_TMP" ] || rm -rf "$CC_TMP"
}

status_append() {  # <line>
  [ -n "$STATE" ] && [ -n "$ID" ] || return 0
  printf '%s\n' "$1" >> "$STATE/$ID.status"
  say "status: $1"
}

busy_apply() {  # <busy|idle|unknown> <event>
  [ -n "$BUSY_GEN" ] || return 0
  "$FM_ROOT/bin/fm-busy-event.sh" apply "$STATE" "$ID" "$1" \
    --gen "$BUSY_GEN" --source "$FM_CURSOR_CLOUD_BUSY_SOURCE" --event "$2" \
    >/dev/null 2>&1 || true
}

record_set() {  # <key>=<value>...
  fm_cursor_cloud_record_set "$STATE" "$ID" "$@" || say "warning: the run record could not be updated"
}

# resolve_repo: the remote this task's local copy came from, as the https URL
# the API expects. Derived from the worktree rather than configured, so the
# cloud agent always works on the same repository the task was dispatched
# against.
resolve_repo() {
  local url
  url=$(git -C "$WT" remote get-url origin 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  case "$url" in
    git@*:*)
      url=${url#git@}
      url="https://${url%%:*}/${url#*:}"
      ;;
    ssh://git@*)
      url="https://${url#ssh://git@}"
      ;;
  esac
  printf '%s' "${url%.git}"
}

# resolve_starting_ref: the repository's own default branch. A cursor-cloud
# task's local branch exists only locally, so it can never be a starting ref
# the cloud agent could resolve.
resolve_starting_ref() {
  local ref
  ref=$(git -C "$WT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || ref=
  [ -n "$ref" ] || return 1
  printf '%s' "${ref#origin/}"
}

# model_json: the `model` member of a launch body, or `null` when neither a
# model nor an effort was requested.
#
# Cursor expresses reasoning effort as a MODEL PARAMETER rather than a flag, and
# which parameter carries it differs by model family - `effort` for the Claude,
# Grok, and Gemini models, `reasoning` for the GPT, Kimi, and GLM ones - so the
# parameter is resolved from GET /v1/models, the vendor's own authoritative
# catalog, instead of from a table here that would rot on the next model
# release. An effort the chosen model does not accept is dropped with a printed
# notice rather than sent as a known-bad value. The bracket form
# `claude-opus-5[effort=high]` is accepted too, and its explicit parameters win.
model_json() {
  local id=$1 effort=$2 inline='' code catalog='' key
  case "$id" in
    *'['*']')
      inline=${id#*[}
      inline=${inline%]}
      id=${id%%[*}
      ;;
  esac
  if [ -z "$id" ] && [ -z "$effort" ]; then
    printf 'null'
    return 0
  fi
  [ -n "$id" ] || {
    say "warning: an effort was requested without a model, so it cannot be resolved to a model parameter; ignoring it"
    printf 'null'
    return 0
  }
  if [ -n "$effort" ]; then
    code=$(cc_api GET /v1/models) || code=000
    case "$code" in
      2*) catalog=$CC_RESP ;;
      *) say "warning: the model catalog could not be read (HTTP $code), so effort '$effort' is omitted" ;;
    esac
    if [ -n "$catalog" ]; then
      key=$(jq -r --arg id "$id" --arg v "$effort" '
        (.items[]? | select(.id == $id) | .parameters[]?
         | select(.id == "effort" or .id == "reasoning")
         | select([.values[]?.value] | index($v))
         | .id) // empty' "$catalog" 2>/dev/null | head -1) || key=
      if [ -n "$key" ]; then
        inline="${inline:+$inline,}$key=$effort"
      else
        say "warning: model '$id' does not accept effort '$effort', so it is omitted"
      fi
    fi
  fi
  jq -n --arg id "$id" --arg inline "$inline" '
    {id: $id}
    + (if $inline == "" then {}
       else {params: ($inline | split(",") | map(select(length > 0) | split("=")
             | {key: .[0], value: (.[1] // "")}) | from_entries)}
       end)'
}

launch_run() {
  local body code model env_json='' pr_flag
  model=$(model_json "$MODEL" "$EFFORT")
  if [ -n "$ENV_NAME" ]; then
    env_json=$(jq -n --arg n "$ENV_NAME" '{type: "cloud", name: $n}')
  fi
  pr_flag=$AUTO_PR
  body="$CC_TMP/launch.json"
  jq -n \
    --rawfile prompt "$BRIEF" \
    --arg repo "$REPO" \
    --arg ref "$STARTING_REF" \
    --arg mode "$RUN_MODE" \
    --argjson pr "$pr_flag" \
    --argjson model "$model" \
    --argjson env "${env_json:-null}" '
    {prompt: {text: $prompt},
     repos: [{url: $repo, startingRef: $ref}],
     autoCreatePR: $pr,
     mode: $mode}
    + (if $model == null then {} else {model: $model} end)
    + (if $env == null then {} else {env: $env} end)' > "$body" \
    || die "the launch request body could not be built"
  code=$(cc_api POST /v1/agents "$body") || code=000
  case "$code" in
    2*) ;;
    *)
      status_append "failed: $(cc_api_error 'cursor cloud agent launch' "$code")"
      die "$(cc_api_error 'cursor cloud agent launch' "$code")"
      ;;
  esac
  AGENT_ID=$(jq -r '.agent.id // .id // empty' "$CC_RESP" 2>/dev/null) || AGENT_ID=
  RUN_ID=$(jq -r '.run.id // .agent.latestRunId // empty' "$CC_RESP" 2>/dev/null) || RUN_ID=
  RUN_STATUS=$(jq -r '.run.status // empty' "$CC_RESP" 2>/dev/null) || RUN_STATUS=
  [ -n "$RUN_STATUS" ] || RUN_STATUS=CREATING
  local url
  url=$(jq -r '.agent.url // empty' "$CC_RESP" 2>/dev/null) || url=
  [ -n "$AGENT_ID" ] && [ -n "$RUN_ID" ] \
    || die "the launch response carried no agent and run id; refusing to supervise a run this shim cannot address"
  record_set "agent=$AGENT_ID" "run=$RUN_ID" "status=$RUN_STATUS" "url=$url"
  say "agent $AGENT_ID run $RUN_ID ($RUN_STATUS)${url:+ $url}"
  busy_apply busy run-created
  if [ "$WORKING_ANNOUNCED" = 0 ]; then
    status_append "$(fm_cursor_cloud_status_line "$RUN_STATUS" '' '' "$RUN_ID")"
    WORKING_ANNOUNCED=1
  fi
}

submit_followup() {  # <text>
  local body code new_run
  body="$CC_TMP/followup.json"
  jq -n --arg text "$1" --arg mode "$RUN_MODE" \
    '{prompt: {text: $text}, mode: $mode}' > "$body" \
    || { say "warning: the follow-up request body could not be built; the steer was NOT sent"; return 1; }
  code=$(cc_api POST "/v1/agents/$AGENT_ID/runs" "$body") || code=000
  case "$code" in
    2*) ;;
    *)
      say "warning: $(cc_api_error 'follow-up submission' "$code"); the steer was NOT sent"
      return 1
      ;;
  esac
  new_run=$(jq -r '.run.id // .id // empty' "$CC_RESP" 2>/dev/null) || new_run=
  [ -n "$new_run" ] || { say "warning: the follow-up response carried no run id; the steer may not have started"; return 1; }
  RUN_ID=$new_run
  RUN_STATUS=$(jq -r '.run.status // .status // empty' "$CC_RESP" 2>/dev/null) || RUN_STATUS=
  [ -n "$RUN_STATUS" ] || RUN_STATUS=CREATING
  record_set "run=$RUN_ID" "status=$RUN_STATUS"
  say "steer submitted as run $RUN_ID ($RUN_STATUS)"
  busy_apply busy run-created
}

# reconcile: read the run's authoritative state. GET .../runs/{runId}, never the
# stream, decides whether a run is terminal, so a dropped connection can never
# be reported as a finished or failed run. Prints
# `<status><US><pr-url><US><branch><US><result-text>` where <US> is U+001F; an
# unreadable run prints an empty status, which the caller must treat as "still
# unknown".
#
# The separator is deliberately NOT a tab: tab is IFS whitespace, so `read`
# COLLAPSES runs of it, and a run with no pull request would silently shift its
# result text into the pull-request field. U+001F is not IFS whitespace, so empty
# fields survive.
reconcile() {
  local code
  code=$(cc_api GET "/v1/agents/$AGENT_ID/runs/$RUN_ID") || code=000
  case "$code" in
    2*) ;;
    *)
      printf '%s' "$CC_US$CC_US$CC_US"
      return 0
      ;;
  esac
  jq -r --arg repo "$REPO" '
    def clean: (. // "") | tostring | gsub("[\n\r\t\u001f]"; " ");
    ([.git.branches[]? | select((.repoUrl // $repo) | sub("\\.git$"; "") == $repo)] + [.git.branches[]?])[0] as $b
    | [ (.status // "" | clean),
        ($b.prUrl // "" | clean),
        ($b.branch // "" | clean),
        ((.result | if type == "string" then . elif type == "object" then (.text // "") else "" end) | clean)
      ] | join("\u001f")' "$CC_RESP" 2>/dev/null || printf '%s' "$CC_US$CC_US$CC_US"
}

# fetch_branch: bring the branch the cloud agent pushed into this task's local
# copy as a remote-tracking ref, so the work is inspectable from the pane's own
# worktree. Deliberately NOT checked out and deliberately no local branch: the
# deliverable is the pull request, and inventing local commits or refs here
# would leave litter in the shared repository and could confuse the landed-work
# test bin/fm-teardown.sh owns. Best-effort; a failure is reported, never fatal.
fetch_branch() {  # <branch>
  local branch=$1
  [ -n "$branch" ] || return 0
  [ -d "$WT" ] || return 0
  if git -C "$WT" fetch --quiet origin "$branch" 2>/dev/null; then
    say "fetched origin/$branch into the local copy"
  else
    say "warning: origin/$branch could not be fetched into the local copy; inspect it on the remote"
  fi
}

finalize_run() {  # <status> <pr> <branch> <text>
  local status=$1 pr=$2 branch=$3 text=$4
  RUN_STATUS=$status
  record_set "status=$status"
  [ -z "$pr" ] || say "PR $pr"
  fetch_branch "$branch"
  status_append "$(fm_cursor_cloud_status_line "$status" "$pr" "$text" "$RUN_ID")"
  busy_apply idle "run-$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')"
}

# stream_run: consume the run's event stream, render it to the pane, and report
# exactly one outcome line to the notification FIFO. Runs as a child so the main
# loop stays free to read steers from stdin.
stream_run() {  # <fifo>
  local fifo=$1 marker="$CC_TMP/terminal" type data text name tool_status status
  rm -f "$marker"
  cc_curl -N -H 'Accept: text/event-stream' \
    "$CC_BASE/v1/agents/$AGENT_ID/runs/$RUN_ID/stream" 2>/dev/null \
    | fm_cursor_cloud_sse_decode \
    | while IFS=$'\t' read -r type data; do
        case "$type" in
          status)
            status=$(printf '%s' "$data" | jq -r '.status // empty' 2>/dev/null) || status=
            [ -z "$status" ] || say "run $RUN_ID status $status"
            if fm_cursor_cloud_status_terminal "$status"; then
              printf '%s\n' "$status" > "$marker"
            fi
            ;;
          assistant|thinking)
            text=$(printf '%s' "$data" | jq -r '.text // empty' 2>/dev/null) || text=
            [ -z "$text" ] || printf '%s\n' "$text" | sed "s/^/[cursor-cloud] $type: /"
            ;;
          tool_call)
            name=$(printf '%s' "$data" | jq -r '.name // "tool"' 2>/dev/null) || name=tool
            tool_status=$(printf '%s' "$data" | jq -r '.status // empty' 2>/dev/null) || tool_status=
            say "tool $name${tool_status:+ ($tool_status)}"
            ;;
          result)
            status=$(printf '%s' "$data" | jq -r '.status // empty' 2>/dev/null) || status=
            say "result ${status:-unknown}"
            if fm_cursor_cloud_status_terminal "$status"; then
              printf '%s\n' "$status" > "$marker"
            fi
            ;;
          error)
            text=$(printf '%s' "$data" | jq -r '[(.code // empty), (.message // empty)] | map(select(. != "")) | join(": ")' 2>/dev/null) || text=
            say "stream error ${text:-unknown}"
            ;;
          done) ;;
          *) ;;
        esac
      done
  if [ -s "$marker" ]; then
    printf 'terminal\t%s\n' "$(cat "$marker")" > "$fifo"
  else
    printf 'dropped\t\n' > "$fifo"
  fi
}

start_stream() {  # <fifo>
  stream_run "$1" &
  STREAM_PID=$!
}

# handle_steer: one line read from stdin. `!cancel` and `!exit` are the shim's
# only control lines; every other non-empty line is a steer, submitted at once
# when no run is active and QUEUED - loudly - when one is.
handle_steer() {  # <line>
  local line=$1 outcome
  line=${line%$'\r'}
  case "$line" in
    '') return 0 ;;
  esac
  STDIN_SEQ=$((STDIN_SEQ + 1))
  record_set "stdin_seq=$STDIN_SEQ"
  case "$line" in
    '!cancel')
      if fm_cursor_cloud_status_terminal "$RUN_STATUS"; then
        say "no active run to cancel (last run $RUN_ID is $RUN_STATUS)"
        return 0
      fi
      say "cancelling run $RUN_ID"
      outcome=$(cc_cancel_run "$STATE" "$ID")
      say "cancel $outcome"
      RUN_STATUS=$(fm_cursor_cloud_record_get "$STATE" "$ID" status)
      return 0
      ;;
    '!exit')
      say "exit requested"
      exit 0
      ;;
  esac
  if fm_cursor_cloud_status_terminal "$RUN_STATUS" || [ -z "$RUN_ID" ]; then
    submit_followup "$line" || true
    if ! fm_cursor_cloud_status_terminal "$RUN_STATUS"; then
      start_stream "$FIFO"
    fi
  else
    STEER_QUEUE=${STEER_QUEUE:+$STEER_QUEUE$'\n'}$line
    STEER_QUEUE_N=$((STEER_QUEUE_N + 1))
    say "steer QUEUED ($STEER_QUEUE_N waiting): run $RUN_ID is $RUN_STATUS and only one run may be active. It has NOT been delivered yet; it is submitted when this run finishes. Send the single line !cancel to stop the run instead."
  fi
}

drain_queue() {
  local joined
  [ -n "$STEER_QUEUE" ] || return 0
  joined=$STEER_QUEUE
  STEER_QUEUE=
  STEER_QUEUE_N=0
  say "submitting queued steer(s) now that the run is $RUN_STATUS"
  if submit_followup "$joined"; then
    start_stream "$FIFO"
  fi
}

run_main() {
  local kind payload status pr branch text attempts=0 backoff=1 rc read_started
  require_api_key
  [ -n "$ID" ] || die "--id is required"
  [ -n "$STATE" ] || die "--state is required"
  [ -d "$STATE" ] || die "--state '$STATE' is not a directory"
  [ -n "$WT" ] || die "--worktree is required"
  [ -n "$BRIEF" ] || die "--brief is required"
  [ -f "$BRIEF" ] || die "--brief '$BRIEF' is not a readable file"
  case "$RUN_MODE" in
    agent|plan) ;;
    *) die "--mode must be agent or plan" ;;
  esac
  CC_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-cursor-cloud.XXXXXX") || die "no temp dir"
  CC_RESP="$CC_TMP/resp.json"
  trap cleanup EXIT
  trap 'exit 143' TERM HUP INT
  [ -n "$REPO" ] || REPO=$(resolve_repo) \
    || die "no repository URL: pass --repo, or run in a local copy with an 'origin' remote"
  [ -n "$STARTING_REF" ] || STARTING_REF=$(resolve_starting_ref) \
    || die "no starting ref: pass --starting-ref, or run in a local copy whose origin/HEAD is known"
  say "repo $REPO ref $STARTING_REF mode $RUN_MODE autoCreatePR $AUTO_PR${ENV_NAME:+ env $ENV_NAME}"
  FIFO="$CC_TMP/notify"
  mkfifo "$FIFO" || die "the notification channel could not be created"
  exec 3<> "$FIFO"
  launch_run
  start_stream "$FIFO"
  while :; do
    # Steers are read BEFORE stream notifications so a `!cancel` typed into the
    # pane is acted on promptly rather than behind a whole poll interval.
    if [ "$STDIN_OPEN" = 1 ]; then
      # `read`'s own status must be captured directly: a bare `if read ...; then`
      # whose condition is false leaves $? at the compound statement's own 0, so
      # reading it afterwards would report success for every timeout.
      rc=0
      line=
      read_started=$SECONDS
      IFS= read -r -t "$CC_READ_TIMEOUT" line || rc=$?
      if [ "$rc" -eq 0 ]; then
        STDIN_FAIL_BURST=0
        handle_steer "$line"
        continue
      fi
      # A final line with no trailing newline arrives with a failing status.
      [ -z "$line" ] || handle_steer "$line"
      # bash 3.2 - the /bin/bash macOS still ships - returns 1 for BOTH a
      # `read -t` timeout and end of input, so the two are told apart by how long
      # the read took rather than by its status: a timed-out read consumes its
      # whole second, while an at-EOF read returns instantly. Two consecutive
      # instant failures is end of input. Recognizing it is what keeps a pane
      # whose terminal has gone from spinning this loop at full speed forever;
      # a live pane's tty never reaches it.
      if [ "$SECONDS" -eq "$read_started" ]; then
        STDIN_FAIL_BURST=$((STDIN_FAIL_BURST + 1))
      else
        STDIN_FAIL_BURST=0
      fi
      if [ "$STDIN_FAIL_BURST" -ge 2 ]; then
        STDIN_OPEN=0
        say "input closed"
      fi
    fi
    if IFS=$'\t' read -r -t "$CC_READ_TIMEOUT" -u 3 kind payload; then
      case "$kind" in
        terminal)
          STREAM_PID=
          attempts=0
          backoff=1
          IFS=$CC_US read -r status pr branch text <<EOF
$(reconcile)
EOF
          # The stream said terminal; the run endpoint is what confirms it.
          if ! fm_cursor_cloud_status_terminal "$status"; then
            status=$payload
          fi
          finalize_run "$status" "$pr" "$branch" "$text"
          drain_queue
          ;;
        dropped)
          STREAM_PID=
          IFS=$CC_US read -r status pr branch text <<EOF
$(reconcile)
EOF
          if fm_cursor_cloud_status_terminal "$status"; then
            say "stream ended; the run endpoint reports $status"
            finalize_run "$status" "$pr" "$branch" "$text"
            drain_queue
          else
            attempts=$((attempts + 1))
            if [ "$attempts" -gt "$CC_STREAM_RETRIES" ]; then
              say "the event stream could not be re-established after $CC_STREAM_RETRIES attempts; run $RUN_ID may still be running"
              busy_apply unknown stream-lost
              status_append "$(fm_cursor_cloud_lost_contact_line "$RUN_ID")"
              RUN_STATUS=${status:-$RUN_STATUS}
              LOST_CONTACT=1
            else
              say "event stream lost (run reads ${status:-unreadable}); reconnecting in ${backoff}s (attempt $attempts/$CC_STREAM_RETRIES)"
              sleep "$backoff"
              backoff=$((backoff * 2))
              start_stream "$FIFO"
            fi
          fi
          ;;
      esac
      continue
    fi
    # Nothing left to wait for: no live run to watch, no queued steer, no more
    # input. A run whose stream could not be re-established counts here too -
    # its `blocked:` line is already durable, and spinning would report nothing
    # further - but its status stays non-terminal so the exit path still cancels
    # it rather than leaving it running and billing.
    if [ "$STDIN_OPEN" = 0 ] && [ -z "$STREAM_PID" ] \
       && [ -z "$STEER_QUEUE" ] \
       && { fm_cursor_cloud_status_terminal "$RUN_STATUS" || [ "$LOST_CONTACT" = 1 ]; }; then
      return 0
    fi
  done
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  sse-decode)
    fm_cursor_cloud_sse_decode
    exit 0
    ;;
  cancel)
    shift
    STATE=${1:-}
    ID=${2:-}
    [ -n "$STATE" ] && [ -n "$ID" ] || { usage >&2; exit 2; }
    [ -d "$STATE" ] || die "state dir '$STATE' is not a directory"
    require_api_key
    CC_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-cursor-cloud.XXXXXX") || die "no temp dir"
    CC_RESP="$CC_TMP/resp.json"
    trap 'rm -rf "$CC_TMP"' EXIT
    cc_cancel_run "$STATE" "$ID"
    printf '\n'
    exit 0
    ;;
  run) shift ;;
  *) usage >&2; exit 2 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --id) ID=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --state) STATE=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --worktree) WT=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --brief) BRIEF=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --busy-gen) BUSY_GEN=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --repo) REPO=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --starting-ref) STARTING_REF=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --model) MODEL=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --effort) EFFORT=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --mode) RUN_MODE=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --env-name) ENV_NAME=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --no-pr) AUTO_PR=false; shift ;;
    *) die "unexpected argument '$1'" ;;
  esac
done

run_main
