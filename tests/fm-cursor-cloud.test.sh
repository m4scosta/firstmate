#!/usr/bin/env bash
# tests/fm-cursor-cloud.test.sh - behavior tests for the cursor-cloud harness
# (bin/fm-cursor-cloud.sh and bin/fm-cursor-cloud-lib.sh).
#
# The HTTP layer is mocked with a fake `curl` on PATH, so every case exercises
# the real request shapes the shim composes without touching the network. The
# fake logs `<METHOD> <url>` for each call, which is what lets a case assert that
# a cancel really was issued rather than only that the shim printed a word.
#
# The load-bearing contracts under test:
#   1. SSE frames are only emitted once complete, multi-line `data:` payloads
#      stay one valid JSON object, and a stream that ends without its final
#      blank line still yields the frame it was accumulating.
#   2. The run-status to firstmate status-line mapping, exactly as
#      docs/cursor-cloud-backend.md states it.
#   3. A steer that arrives while a run is active is QUEUED, says so, and is
#      submitted as a follow-up run once the run reaches a terminal state.
#   4. The literal line `!cancel` cancels the live run instead of queueing.
#   5. A dropped stream is reconciled against the run endpoint, which is the only
#      authority on terminal state; a run still running is reconnected to, and
#      only exhausted retries produce `blocked: lost contact`.
#   6. A missing CURSOR_API_KEY refuses loudly, and the key never reaches a
#      process argument list, a file, or any output.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-cursor-cloud-lib.sh
. "$ROOT/bin/fm-cursor-cloud-lib.sh"

SHIM="$ROOT/bin/fm-cursor-cloud.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-cloud)

# --- the fake HTTP layer ----------------------------------------------------
#
# Scenario files live in $FM_CC_DIR. `stream.<n>` is the SSE body served to the
# n-th stream attempt and `run.<n>` the JSON served to the n-th run read, each
# falling back to the highest-numbered file present, so a case can script a
# sequence without scripting every step.

make_fake_curl() {  # <case-dir> -> prints the fakebin
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: understands only the flags bin/fm-cursor-cloud.sh actually passes.
set -u
# Consume the -K - config on stdin. Asserting the key never appears in argv is
# the point of reading it here instead of from an argument.
config=$(cat)
case "$config" in
  *"$FM_CC_EXPECT_KEY"*) printf 'auth-ok\n' >> "$FM_CC_DIR/auth.log" ;;
  *) printf 'auth-missing\n' >> "$FM_CC_DIR/auth.log" ;;
esac
printf '%s\n' "$*" >> "$FM_CC_DIR/argv.log"

method=GET out= url= prev=
for a in "$@"; do
  case "$prev" in
    -X) method=$a ;;
    -o) out=$a ;;
  esac
  case "$a" in https://*|http://*) url=$a ;; esac
  prev=$a
done
printf '%s %s\n' "$method" "$url" >> "$FM_CC_DIR/call.log"

pick() {  # <prefix> -> a scenario file path, or empty
  local prefix=$1 n counter="$FM_CC_DIR/$1.n" f
  n=$(cat "$counter" 2>/dev/null || printf 0)
  n=$((n + 1))
  printf '%s\n' "$n" > "$counter"
  f="$FM_CC_DIR/$prefix.$n"
  if [ ! -f "$f" ]; then
    f=$(ls "$FM_CC_DIR/$prefix".[0-9]* 2>/dev/null | sort -t. -k2 -n | tail -1)
  fi
  printf '%s' "${f:-}"
}

respond() {  # <file> <code>
  local f=$1 code=$2
  if [ -n "$out" ]; then
    if [ -n "$f" ] && [ -f "$f" ]; then cat "$f" > "$out"; else : > "$out"; fi
    printf '%s' "$code"
  elif [ -n "$f" ] && [ -f "$f" ]; then
    cat "$f"
  fi
}

case "$method $url" in
  "GET "*/v1/models) respond "$FM_CC_DIR/models.json" 200 ;;
  "POST "*/v1/agents) respond "$FM_CC_DIR/launch.json" 200 ;;
  "POST "*/cancel)
    printf '%s\n' "$url" >> "$FM_CC_DIR/cancel.log"
    respond '' 200
    ;;
  "POST "*/runs) respond "$(pick followup)" 200 ;;
  "GET "*/stream)
    sleep "${FM_CC_STREAM_DELAY:-0}"
    respond "$(pick stream)" 200
    ;;
  "GET "*/runs/*) respond "$(pick run)" 200 ;;
  *) respond '' 404 ;;
esac
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# new_case: a scenario directory plus the firstmate home the shim writes into.
new_case() {  # <name> -> prints "<case-dir>|<home>|<fakebin>|<id>"
  local name=$1 dir home fakebin id
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  id="cc-$name"
  mkdir -p "$dir/api" "$home/state" "$dir/data"
  fakebin=$(make_fake_curl "$dir")
  printf 'do the thing\n' > "$dir/data/brief.md"
  cat > "$dir/api/launch.json" <<'JSON'
{"agent":{"id":"bc-1111","url":"https://cursor.com/agents?id=bc-1111","latestRunId":"run-aaaa"},
 "run":{"id":"run-aaaa","status":"CREATING"}}
JSON
  printf '%s|%s|%s|%s\n' "$dir" "$home" "$fakebin" "$id"
}

run_shim() {  # <case-dir> <home> <fakebin> <id> [extra args...] < stdin
  local dir=$1 home=$2 fakebin=$3 id=$4
  shift 4
  FM_CC_DIR="$dir/api" FM_CC_EXPECT_KEY=test-key-value \
    CURSOR_API_KEY=test-key-value \
    FM_CURSOR_CLOUD_POLL=0.1 FM_CURSOR_CLOUD_CANCEL_WAIT=1 \
    PATH="$fakebin:$PATH" \
    "$SHIM" run --id "$id" --state "$home/state" --worktree "$dir/nowhere" \
    --brief "$dir/data/brief.md" --repo https://github.com/o/r --starting-ref main \
    "$@" 2>&1
}

sse_frame() {  # <event> <json> -> one complete SSE frame
  printf 'event: %s\ndata: %s\n\n' "$1" "$2"
}

# assert_line <file> <exact-line> <msg>: the file holds that line exactly. A
# status append is a whole line with a meaning, so a substring match would let a
# wrong prefix (`working:` where `done:` was required) pass.
assert_line() {
  grep -Fqx -- "$2" "$1" \
    || fail "$3 (missing line: '$2')"$'\n'"--- $1 ---"$'\n'"$(cat "$1" 2>/dev/null)"
}

# assert_no_prefix <file> <prefix> <msg>: no line in the file starts with it.
assert_no_prefix() {
  if grep -q "^$2" "$1" 2>/dev/null; then
    fail "$3 (unexpected '$2' line)"$'\n'"--- $1 ---"$'\n'"$(cat "$1" 2>/dev/null)"
  fi
}

# --- 1. SSE decoding --------------------------------------------------------

test_sse_decode_complete_frames() {
  local out
  out=$(printf 'event: status\ndata: {"status":"RUNNING"}\n\nevent: done\ndata: {}\n\n' \
    | "$SHIM" sse-decode)
  assert_contains "$out" 'status	{"status":"RUNNING"}' 'status frame decoded with its payload'
  assert_contains "$out" 'done	{}' 'done frame decoded'
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ] \
    || fail "two complete frames must decode to exactly two lines, got: $out"
  pass 'sse-decode emits one line per complete frame'
}

test_sse_decode_split_and_partial_frames() {
  local out frame_count
  # A frame whose payload arrives as two data: lines, a keepalive comment and an
  # id: field between frames, CRLF line endings, and a final frame that is never
  # terminated by a blank line because the connection dropped mid-stream.
  out=$(printf 'event: assistant\r\ndata: {"text":\r\ndata: "hello"}\r\n\r\n: keepalive\r\nid: 7\r\nevent: result\r\ndata: {"status":"FINISHED"}\r\n' \
    | "$SHIM" sse-decode)
  assert_contains "$out" 'assistant	{"text": "hello"}' \
    'a data payload split across lines is rejoined into one valid JSON object'
  printf '%s' "$out" | grep -F 'assistant	{"text": "hello"}' | head -1 \
    | cut -f2 | jq -e . >/dev/null \
    || fail "the rejoined payload must still be valid JSON: $out"
  assert_contains "$out" 'result	{"status":"FINISHED"}' \
    'a frame the stream never terminated with a blank line is still emitted at EOF'
  assert_not_contains "$out" 'keepalive' 'comment/keepalive lines carry no frame'
  frame_count=$(printf '%s\n' "$out" | grep -c '	')
  [ "$frame_count" = 2 ] || fail "expected exactly 2 frames, got $frame_count: $out"
  pass 'sse-decode handles split payloads, keepalives, CRLF, and a partial final frame'
}

test_sse_decode_types_an_untagged_frame_from_its_payload() {
  local out
  out=$(printf 'data: {"type":"thinking","text":"hm"}\n\ndata: {"no":"type"}\n\n' \
    | "$SHIM" sse-decode)
  assert_contains "$out" 'thinking	{"type":"thinking","text":"hm"}' \
    'a frame with no event: field is typed from its own payload'
  assert_contains "$out" 'message	{"no":"type"}' \
    'an untypeable frame is reported as message rather than dropped'
  pass 'sse-decode types frames without an event: field'
}

# --- 2. the status-line mapping ---------------------------------------------

test_status_line_mapping() {
  local got
  got=$(fm_cursor_cloud_status_line RUNNING '' '' run-x)
  [ "$got" = 'working: cursor cloud run run-x under way' ] \
    || fail "RUNNING must map to one working: line, got '$got'"
  got=$(fm_cursor_cloud_status_line CREATING '' '' run-x)
  [ "$got" = 'working: cursor cloud run run-x under way' ] \
    || fail "CREATING must map to the same working: line, got '$got'"
  got=$(fm_cursor_cloud_status_line FINISHED 'https://github.com/o/r/pull/9' 'summary' run-x)
  [ "$got" = 'done: PR https://github.com/o/r/pull/9' ] \
    || fail "FINISHED with a PR must report the PR URL, got '$got'"
  got=$(fm_cursor_cloud_status_line FINISHED '' 'read the code only' run-x)
  [ "$got" = 'done: read the code only (no PR opened)' ] \
    || fail "FINISHED without a PR must say so, got '$got'"
  got=$(fm_cursor_cloud_status_line FINISHED '' '' run-x)
  [ "$got" = 'done: run finished (no PR opened)' ] \
    || fail "FINISHED with neither PR nor summary must still be a done: line, got '$got'"
  got=$(fm_cursor_cloud_status_line ERROR '' 'repo clone failed' run-x)
  [ "$got" = 'failed: repo clone failed' ] \
    || fail "ERROR must report its message, got '$got'"
  got=$(fm_cursor_cloud_status_line ERROR '' '' run-x)
  [ "$got" = 'failed: run failed' ] || fail "ERROR with no message, got '$got'"
  got=$(fm_cursor_cloud_status_line CANCELLED '' '' run-x)
  [ "$got" = 'failed: run cancelled' ] || fail "CANCELLED mapping, got '$got'"
  got=$(fm_cursor_cloud_status_line EXPIRED '' '' run-x)
  [ "$got" = 'failed: run expired' ] || fail "EXPIRED mapping, got '$got'"
  got=$(fm_cursor_cloud_lost_contact_line run-x)
  [ "$got" = 'blocked: lost contact with cloud run run-x' ] \
    || fail "a lost stream must be blocked:, never failed:, got '$got'"
  pass 'the run-status to firstmate status-line mapping is exact'
}

test_status_line_never_reports_an_unknown_status_as_finished() {
  local got
  got=$(fm_cursor_cloud_status_line SOMETHING_NEW '' '' run-x)
  case "$got" in
    blocked:*) ;;
    *) fail "an unrecognized status must not be folded into done:/failed:, got '$got'" ;;
  esac
  fm_cursor_cloud_status_terminal SOMETHING_NEW \
    && fail 'an unrecognized status must not classify as terminal'
  fm_cursor_cloud_status_active SOMETHING_NEW \
    && fail 'an unrecognized status must not classify as active'
  pass 'an unrecognized run status is neither terminal nor active'
}

test_one_line_bounds_a_multiline_result() {
  local got
  got=$(fm_cursor_cloud_one_line "$(printf 'first\nsecond\tthird')")
  [ "$got" = 'first second third' ] || fail "newlines must collapse, got '$got'"
  got=$(fm_cursor_cloud_one_line "$(printf 'aaaaaaaaaa')" 4)
  [ "$got" = 'aaaa...' ] || fail "long text must be bounded, got '$got'"
  pass 'a result summary is collapsed to one bounded line'
}

# --- 3. a finished run surfaces its PR --------------------------------------

test_finished_run_reports_pr_and_records_state() {
  local rec dir home fakebin id out status_file
  IFS='|' read -r dir home fakebin id <<EOF
$(new_case finished)
EOF
  sse_frame status '{"runId":"run-aaaa","status":"RUNNING"}' > "$dir/api/stream.1"
  sse_frame assistant '{"text":"working on it"}' >> "$dir/api/stream.1"
  sse_frame result '{"runId":"run-aaaa","status":"FINISHED"}' >> "$dir/api/stream.1"
  sse_frame done '{}' >> "$dir/api/stream.1"
  cat > "$dir/api/run.1" <<'JSON'
{"status":"FINISHED","durationMs":1200,"result":{"text":"bumped the date"},
 "git":{"branches":[{"repoUrl":"https://github.com/o/r","branch":"cursor/bump-1","prUrl":"https://github.com/o/r/pull/42"}]}}
JSON
  out=$(run_shim "$dir" "$home" "$fakebin" "$id" < /dev/null)
  status_file="$home/state/$id.status"
  assert_line "$status_file" 'working: cursor cloud run run-aaaa under way' \
    'the launch appends exactly one working: line'
  assert_line "$status_file" 'done: PR https://github.com/o/r/pull/42' \
    'a finished run surfaces the PR URL as a done: line'
  [ "$(grep -c '^working:' "$status_file")" = 1 ] \
    || fail "working: must be appended once at start, not per event: $(cat "$status_file")"
  rec=$(fm_cursor_cloud_record_get "$home/state" "$id" status)
  [ "$rec" = FINISHED ] || fail "the run record must record the terminal status, got '$rec'"
  rec=$(fm_cursor_cloud_record_get "$home/state" "$id" agent)
  [ "$rec" = bc-1111 ] || fail "the run record must record the agent id, got '$rec'"
  assert_contains "$out" 'assistant: working on it' 'stream events are rendered into the pane'
  assert_line "$dir/api/call.log" 'POST https://api.cursor.com/v1/agents' \
    'the launch is a POST to /v1/agents'
  assert_line "$dir/api/call.log" 'GET https://api.cursor.com/v1/agents/bc-1111/runs/run-aaaa' \
    'the terminal state is reconciled against the run endpoint'
  pass 'a finished run reports its PR, records its status, and renders its stream'
}

# --- 4. steer queueing and !cancel ------------------------------------------

test_steer_queues_while_a_run_is_active_then_submits() {
  local dir home fakebin id out
  IFS='|' read -r dir home fakebin id <<EOF
$(new_case queue)
EOF
  # The first stream stays RUNNING long enough for the steer to arrive, then
  # finishes; the follow-up run's stream finishes immediately.
  {
    sse_frame status '{"runId":"run-aaaa","status":"RUNNING"}'
    printf ': keepalive\n\n'
  } > "$dir/api/stream.1"
  sse_frame result '{"runId":"run-aaaa","status":"FINISHED"}' >> "$dir/api/stream.1"
  sse_frame result '{"runId":"run-bbbb","status":"FINISHED"}' > "$dir/api/stream.2"
  printf '{"status":"FINISHED","result":"first","git":{"branches":[]}}\n' > "$dir/api/run.1"
  printf '{"run":{"id":"run-bbbb","status":"CREATING"}}\n' > "$dir/api/followup.1"
  out=$(printf 'also update the changelog\n' \
    | FM_CC_STREAM_DELAY=5 run_shim "$dir" "$home" "$fakebin" "$id")
  assert_contains "$out" 'steer QUEUED' 'an incoming steer is announced as queued, not delivered'
  assert_contains "$out" 'It has NOT been delivered yet' \
    'the queued line says plainly that the steer has not landed'
  assert_contains "$out" 'steer submitted as run run-bbbb' \
    'the queued steer is submitted once the active run reaches a terminal state'
  assert_line "$dir/api/call.log" 'POST https://api.cursor.com/v1/agents/bc-1111/runs' \
    'the follow-up is a POST to the agent runs endpoint'
  [ "$(fm_cursor_cloud_record_get "$home/state" "$id" stdin_seq)" = 1 ] \
    || fail 'the shim must acknowledge the accepted input line in its record'
  [ "$(fm_cursor_cloud_record_get "$home/state" "$id" run)" = run-bbbb ] \
    || fail 'the record must follow the newest run'
  pass 'a steer sent while a run is active queues loudly and is submitted afterwards'
}

test_steer_submits_immediately_when_no_run_is_active() {
  local dir home fakebin id out
  IFS='|' read -r dir home fakebin id <<EOF
$(new_case immediate)
EOF
  sse_frame result '{"runId":"run-aaaa","status":"FINISHED"}' > "$dir/api/stream.1"
  sse_frame result '{"runId":"run-bbbb","status":"FINISHED"}' > "$dir/api/stream.2"
  printf '{"status":"FINISHED","result":"first","git":{"branches":[]}}\n' > "$dir/api/run.1"
  printf '{"run":{"id":"run-bbbb","status":"CREATING"}}\n' > "$dir/api/followup.1"
  # The steer is written after a delay so the first run is already terminal.
  out=$( (sleep 3; printf 'now do the next bit\n') | run_shim "$dir" "$home" "$fakebin" "$id")
  assert_not_contains "$out" 'steer QUEUED' 'no queueing is claimed when no run is active'
  assert_contains "$out" 'steer submitted as run run-bbbb' 'the steer is submitted at once'
  pass 'a steer arriving with no active run is submitted immediately'
}

test_bang_cancel_cancels_the_live_run() {
  local dir home fakebin id out
  IFS='|' read -r dir home fakebin id <<EOF
$(new_case cancel)
EOF
  {
    sse_frame status '{"runId":"run-aaaa","status":"RUNNING"}'
    printf ': keepalive\n\n'
  } > "$dir/api/stream.1"
  sse_frame result '{"runId":"run-aaaa","status":"CANCELLED"}' >> "$dir/api/stream.1"
  printf '{"status":"CANCELLED"}\n' > "$dir/api/run.1"
  out=$(printf '!cancel\n' | FM_CC_STREAM_DELAY=5 run_shim "$dir" "$home" "$fakebin" "$id")
  assert_not_contains "$out" 'steer QUEUED' '!cancel is a control line, never a queued steer'
  assert_grep 'runs/run-aaaa/cancel' "$dir/api/cancel.log" \
    'the cancel endpoint is actually called'
  assert_contains "$out" 'cancel cancelled' 'the cancel is confirmed from the run endpoint'
  assert_line "$home/state/$id.status" 'failed: run cancelled' \
    'a cancelled run maps to failed: run cancelled'
  pass 'the literal line !cancel cancels the live run'
}

test_bang_exit_stops_the_shim_and_cancels() {
  local dir home fakebin id out code
  IFS='|' read -r dir home fakebin id <<EOF
$(new_case bangexit)
EOF
  {
    sse_frame status '{"runId":"run-aaaa","status":"RUNNING"}'
    printf ': keepalive\n\n'
  } > "$dir/api/stream.1"
  printf '{"status":"CANCELLED"}\n' > "$dir/api/run.1"
  out=$(printf '!exit\n' | FM_CC_STREAM_DELAY=5 run_shim "$dir" "$home" "$fakebin" "$id")
  code=$?
  [ "$code" = 0 ] || fail "!exit must stop the shim cleanly, exit code $code: $out"
  assert_contains "$out" 'exit requested' 'the pane records why the shim stopped'
  assert_grep 'runs/run-aaaa/cancel' "$dir/api/cancel.log" \
    'a shim that exits must not leave a run billing'
  pass 'the literal line !exit stops the shim and cancels the active run'
}

# --- 5. dropped-stream reconciliation ---------------------------------------

test_dropped_stream_reconciles_before_reconnecting() {
  local dir home fakebin id out
  IFS='|' read -r dir home fakebin id <<EOF
$(new_case dropped)
EOF
  # Attempt 1 ends with no terminal event at all; the run endpoint still reads
  # RUNNING, so the shim must reconnect rather than declare an outcome.
  sse_frame assistant '{"text":"halfway"}' > "$dir/api/stream.1"
  sse_frame result '{"runId":"run-aaaa","status":"FINISHED"}' > "$dir/api/stream.2"
  printf '{"status":"RUNNING"}\n' > "$dir/api/run.1"
  printf '{"status":"FINISHED","result":"second attempt","git":{"branches":[]}}\n' > "$dir/api/run.2"
  out=$(run_shim "$dir" "$home" "$fakebin" "$id" < /dev/null)
  assert_contains "$out" 'event stream lost' 'a dropped stream is reported as lost, not finished'
  assert_contains "$out" 'reconnecting in' 'a still-running run is reconnected to'
  assert_not_contains "$out" 'lost contact' 'one drop is not a lost-contact escalation'
  assert_line "$home/state/$id.status" 'done: second attempt (no PR opened)' \
    'the run finishes on the reconnected stream'
  assert_no_prefix "$home/state/$id.status" 'failed:' \
    'a dropped stream is never reported as a failed run'
  pass 'a dropped stream is reconciled against the run endpoint and reconnected'
}

test_dropped_stream_that_already_finished_is_not_reconnected() {
  local dir home fakebin id out
  IFS='|' read -r dir home fakebin id <<EOF
$(new_case dropped_finished)
EOF
  # The stream drops without a terminal event, but the run endpoint - the
  # authority - says it finished, so the outcome comes from there.
  sse_frame assistant '{"text":"halfway"}' > "$dir/api/stream.1"
  cat > "$dir/api/run.1" <<'JSON'
{"status":"FINISHED","result":"finished while the stream was down",
 "git":{"branches":[{"repoUrl":"https://github.com/o/r","branch":"cursor/x","prUrl":"https://github.com/o/r/pull/7"}]}}
JSON
  out=$(run_shim "$dir" "$home" "$fakebin" "$id" < /dev/null)
  assert_contains "$out" 'the run endpoint reports FINISHED' \
    'the run endpoint, not the stream, settles the outcome'
  assert_line "$home/state/$id.status" 'done: PR https://github.com/o/r/pull/7' \
    'the PR is surfaced even though the stream never delivered a result event'
  assert_not_contains "$out" 'reconnecting in' 'a finished run is not reconnected to'
  pass 'a dropped stream whose run already finished is reconciled, not reconnected'
}

test_exhausted_stream_retries_block_rather_than_fail() {
  local dir home fakebin id out
  IFS='|' read -r dir home fakebin id <<EOF
$(new_case lostcontact)
EOF
  # Every stream attempt ends immediately with nothing, and the run endpoint
  # keeps reading RUNNING, so the retry budget is spent.
  : > "$dir/api/stream.1"
  printf '{"status":"RUNNING"}\n' > "$dir/api/run.1"
  out=$(FM_CURSOR_CLOUD_STREAM_RETRIES=2 run_shim "$dir" "$home" "$fakebin" "$id" < /dev/null)
  assert_contains "$out" 'could not be re-established after 2 attempts' \
    'the retry budget is reported when it is spent'
  assert_line "$home/state/$id.status" 'blocked: lost contact with cloud run run-aaaa' \
    'exhausted retries escalate as blocked:, naming the run'
  assert_no_prefix "$home/state/$id.status" 'failed:' \
    'a stream that could not be re-established is never a failed run'
  assert_no_prefix "$home/state/$id.status" 'done:' \
    'a stream that could not be re-established is never a finished run'
  pass 'only exhausted stream retries escalate, and they escalate as blocked'
}

# --- 6. auth ----------------------------------------------------------------

test_missing_api_key_refuses_loudly() {
  local dir home fakebin id out code
  IFS='|' read -r dir home fakebin id <<EOF
$(new_case nokey)
EOF
  code=0
  out=$(FM_CC_DIR="$dir/api" FM_CC_EXPECT_KEY=x PATH="$fakebin:$PATH" \
    env -u CURSOR_API_KEY "$SHIM" run --id "$id" --state "$home/state" \
    --worktree "$dir/nowhere" --brief "$dir/data/brief.md" \
    --repo https://github.com/o/r --starting-ref main 2>&1 < /dev/null) || code=$?
  [ "$code" != 0 ] || fail "a missing CURSOR_API_KEY must refuse, got exit 0: $out"
  assert_contains "$out" 'CURSOR_API_KEY is not set' 'the refusal names the missing variable'
  assert_absent "$dir/api/call.log" 'no request is attempted without a key'
  pass 'a missing CURSOR_API_KEY refuses loudly before any request'
}

test_api_key_never_reaches_argv_output_or_disk() {
  local dir home fakebin id out
  IFS='|' read -r dir home fakebin id <<EOF
$(new_case keysafety)
EOF
  sse_frame result '{"runId":"run-aaaa","status":"FINISHED"}' > "$dir/api/stream.1"
  printf '{"status":"FINISHED","result":"ok","git":{"branches":[]}}\n' > "$dir/api/run.1"
  out=$(run_shim "$dir" "$home" "$fakebin" "$id" < /dev/null)
  assert_grep 'auth-ok' "$dir/api/auth.log" \
    'the key still reaches curl, through its stdin config'
  assert_no_grep 'test-key-value' "$dir/api/argv.log" \
    'the key never appears in a curl argument list'
  assert_not_contains "$out" 'test-key-value' 'the key never appears in pane output'
  if grep -rlF test-key-value "$home/state" >/dev/null 2>&1; then
    fail 'the key must never be written into any firstmate state file'
  fi
  pass 'the API key reaches curl without entering argv, output, or state'
}

# --- 7. the run record ------------------------------------------------------

test_record_set_merges_and_replaces_fields() {
  local state="$TMP_ROOT/record/state"
  mkdir -p "$state"
  fm_cursor_cloud_record_set "$state" t1 agent=bc-1 run=run-1 status=RUNNING
  fm_cursor_cloud_record_set "$state" t1 status=FINISHED stdin_seq=4
  [ "$(fm_cursor_cloud_record_get "$state" t1 agent)" = bc-1 ] \
    || fail 'an unnamed field must be preserved'
  [ "$(fm_cursor_cloud_record_get "$state" t1 status)" = FINISHED ] \
    || fail 'a named field must be replaced'
  [ "$(grep -c '^status=' "$state/t1.cursor-cloud")" = 1 ] \
    || fail "a replaced field must not be duplicated: $(cat "$state/t1.cursor-cloud")"
  [ "$(fm_cursor_cloud_record_get "$state" t1 stdin_seq)" = 4 ] \
    || fail 'a new field must be added'
  [ -z "$(fm_cursor_cloud_record_get "$state" t2 agent)" ] \
    || fail 'an absent record must read as empty, never as a stale value'
  pass 'the run record merges, replaces without duplicating, and reads absent as empty'
}

test_cancel_subcommand_is_idempotent_and_targeted() {
  local dir home fakebin id out
  IFS='|' read -r dir home fakebin id <<EOF
$(new_case cancelcmd)
EOF
  out=$(FM_CC_DIR="$dir/api" FM_CC_EXPECT_KEY=k CURSOR_API_KEY=k \
    PATH="$fakebin:$PATH" "$SHIM" cancel "$home/state" "$id" 2>&1)
  assert_contains "$out" 'none' 'a task with no recorded run has nothing to cancel'
  assert_absent "$dir/api/cancel.log" 'no cancel is issued for a task with no run'

  fm_cursor_cloud_record_set "$home/state" "$id" agent=bc-9 run=run-9 status=FINISHED
  out=$(FM_CC_DIR="$dir/api" FM_CC_EXPECT_KEY=k CURSOR_API_KEY=k \
    PATH="$fakebin:$PATH" "$SHIM" cancel "$home/state" "$id" 2>&1)
  assert_contains "$out" 'already-terminal' 'a finished run is not cancelled again'
  assert_absent "$dir/api/cancel.log" 'no cancel is issued for an already-terminal run'

  printf '{"status":"CANCELLED"}\n' > "$dir/api/run.1"
  fm_cursor_cloud_record_set "$home/state" "$id" status=RUNNING
  out=$(FM_CC_DIR="$dir/api" FM_CC_EXPECT_KEY=k CURSOR_API_KEY=k \
    FM_CURSOR_CLOUD_CANCEL_WAIT=1 FM_CURSOR_CLOUD_POLL=0.1 \
    PATH="$fakebin:$PATH" "$SHIM" cancel "$home/state" "$id" 2>&1)
  assert_contains "$out" 'cancelled' 'an active run is cancelled and confirmed'
  assert_grep 'runs/run-9/cancel' "$dir/api/cancel.log" 'the recorded run is the one cancelled'
  [ "$(fm_cursor_cloud_record_get "$home/state" "$id" status)" = CANCELLED ] \
    || fail 'the confirmed terminal status must be recorded'
  pass 'the cancel subcommand is idempotent and cancels only the recorded run'
}

test_sse_decode_complete_frames
test_sse_decode_split_and_partial_frames
test_sse_decode_types_an_untagged_frame_from_its_payload
test_status_line_mapping
test_status_line_never_reports_an_unknown_status_as_finished
test_one_line_bounds_a_multiline_result
test_record_set_merges_and_replaces_fields
test_finished_run_reports_pr_and_records_state
test_steer_queues_while_a_run_is_active_then_submits
test_steer_submits_immediately_when_no_run_is_active
test_bang_cancel_cancels_the_live_run
test_bang_exit_stops_the_shim_and_cancels
test_dropped_stream_reconciles_before_reconnecting
test_dropped_stream_that_already_finished_is_not_reconnected
test_exhausted_stream_retries_block_rather_than_fail
test_missing_api_key_refuses_loudly
test_api_key_never_reaches_argv_output_or_disk
test_cancel_subcommand_is_idempotent_and_targeted
