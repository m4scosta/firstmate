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
  {
    sse_frame status '{"runId":"run-aaaa","status":"RUNNING"}'
    sse_frame assistant '{"text":"working"}'
    sse_frame assistant '{"text":" on"}'
    sse_frame assistant '{"text":" it"}'
    sse_frame result '{"runId":"run-aaaa","status":"FINISHED"}'
    sse_frame 'done' '{}'
  } > "$dir/api/stream.1"
  # repoUrl is quoted exactly as the live API returns it: no scheme, and here
  # alongside another repository's branch, so the case proves the task's own
  # repository is selected rather than whichever branch happens to come first.
  cat > "$dir/api/run.1" <<'JSON'
{"status":"FINISHED","durationMs":1200,"result":{"text":"bumped the date"},
 "git":{"branches":[{"repoUrl":"github.com/other/repo","branch":"cursor/wrong","prUrl":"https://github.com/other/repo/pull/1"},
                    {"repoUrl":"github.com/o/r","branch":"cursor/bump-1","prUrl":"https://github.com/o/r/pull/42"}]}}
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
  [ "$(printf '%s\n' "$out" | grep -c 'assistant: ')" = 1 ] \
    || fail "consecutive assistant deltas must coalesce onto one pane line, got: $out"
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
 "git":{"branches":[{"repoUrl":"github.com/O/R.git","branch":"cursor/x","prUrl":"https://github.com/o/r/pull/7"}]}}
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

# --- 8. pane-process identity -----------------------------------------------
#
# The shim is a `#!` script, and the kernel replaces such a script's own name
# with its interpreter, so the pane process would report `bash` and the tmux
# liveness classifier would call a live cloud worker `dead` - the one verdict
# that can launch a duplicate agent onto a live worktree. bin/fm-spawn.sh's
# launch template defeats that with an explicit `exec -a cursor-cloud`. This
# case proves the whole chain with REAL processes and no tmux: that the explicit
# argv[0] survives into what `ps` reports, that the classifier reads it as an
# agent, and - driving the two apart deliberately - that the same command
# WITHOUT it reads as a shell, so the assertion cannot go quietly vacuous.

test_shim_pane_process_classifies_as_an_agent() {
  local named_pid plain_pid named_argv plain_argv verdict stand_in
  FM_BACKEND_LIB_DIR="$ROOT/bin"
  # shellcheck source=bin/backends/tmux.sh
  . "$ROOT/bin/backends/tmux.sh"

  # A stand-in for the shim rather than the shim itself: it must be a MULTI-
  # statement script run as `bash <path>`, which is exactly the shape the launch
  # template produces. A single simple command would not do - bash execs straight
  # into it, replacing the argv[0] under test.
  stand_in="$TMP_ROOT/stand-in-shim.sh"
  mkdir -p "$TMP_ROOT"
  printf '#!/usr/bin/env bash\nsleep 30\nexit 0\n' > "$stand_in"
  exec -a cursor-cloud bash "$stand_in" &
  named_pid=$!
  bash "$stand_in" &
  plain_pid=$!
  named_argv=$(LC_ALL=C ps -p "$named_pid" -o args= 2>/dev/null)
  named_argv=${named_argv#"${named_argv%%[![:space:]]*}"}
  named_argv=${named_argv%%[[:space:]]*}
  plain_argv=$(LC_ALL=C ps -p "$plain_pid" -o args= 2>/dev/null)
  plain_argv=${plain_argv#"${plain_argv%%[![:space:]]*}"}
  plain_argv=${plain_argv%%[[:space:]]*}
  kill "$named_pid" "$plain_pid" 2>/dev/null || true

  [ "$(basename -- "$named_argv")" = cursor-cloud ] \
    || fail "exec -a must put cursor-cloud in argv[0]; ps reported '$named_argv'"
  [ "$(basename -- "$plain_argv")" != cursor-cloud ] \
    || fail "the control process must NOT carry the shim's argv[0]; ps reported '$plain_argv'"

  verdict=$(fm_backend_tmux_classify_process_name '' "$named_argv")
  [ "$verdict" = agent ] \
    || fail "the shim's pane process must classify as an agent, got '$verdict' for '$named_argv'"
  verdict=$(fm_backend_tmux_classify_process_name '' "$plain_argv")
  [ "$verdict" != agent ] \
    || fail "without the explicit argv[0] the same process must NOT read as an agent, got '$verdict' for '$plain_argv'"
  # The interpreter carrying the shim reports `bash` as its process name, so the
  # explicit argv[0] has to outrank that shell name rather than lose to it.
  verdict=$(fm_backend_tmux_classify_process_name bash cursor-cloud)
  [ "$verdict" = agent ] \
    || fail "argv[0] must outrank the interpreter's own name, got '$verdict'"
  # macOS reports the overridden argv[0] through `ps -o comm=` while Linux
  # reports the interpreter, so BOTH sources must carry the verdict on their own.
  verdict=$(fm_backend_tmux_classify_process_name cursor-cloud)
  [ "$verdict" = agent ] \
    || fail "the name source alone must carry the verdict, got '$verdict'"
  verdict=$(fm_backend_tmux_classify_process_name cursor-cloudy)
  [ "$verdict" != agent ] \
    || fail 'a name that merely starts with cursor-cloud must not read as an agent'
  verdict=$(fm_backend_tmux_classify_process_name '' cursor-cloudy)
  [ "$verdict" != agent ] \
    || fail 'an argv[0] that merely starts with cursor-cloud must not read as an agent'
  verdict=$(fm_backend_tmux_classify_process_name bash bash)
  [ "$verdict" = shell ] \
    || fail "a plain interpreter must still read as a shell, got '$verdict'"
  pass 'the shim pane process is identified as a live agent, and only with its explicit argv[0]'
}

# --- 9. the control-plane and busy-state tables ------------------------------

test_control_tables_declare_cursor_cloud() {
  local got
  # shellcheck source=bin/fm-control-lib.sh
  . "$ROOT/bin/fm-control-lib.sh"
  # shellcheck source=bin/fm-busy-lib.sh
  . "$ROOT/bin/fm-busy-lib.sh"

  fm_control_harness_supported cursor-cloud || fail 'cursor-cloud must be a supported control harness'
  [ "$(fm_control_harness_family cursor-cloud)" = cursor-cloud ] \
    || fail 'the recorded harness must map to the cursor-cloud family'
  fm_control_harness_supports_kind cursor-cloud ship || fail 'cursor-cloud must run a ship task'
  fm_control_harness_supports_kind cursor-cloud scout || fail 'cursor-cloud must run a scout task'
  fm_control_harness_supports_kind cursor-cloud secondmate \
    && fail 'cursor-cloud must be refused for a secondmate: its pane runs one cloud task, not a firstmate'

  got=$(fm_control_interrupt_transport cursor-cloud)
  [ "$got" = api ] || fail "cursor-cloud must interrupt over the API, got '$got'"
  fm_control_interrupt_key cursor-cloud >/dev/null 2>&1 \
    && fail 'cursor-cloud must expose no interrupt KEY: a key press cannot stop a cloud run'
  [ "$(fm_control_interrupt_ack_source cursor-cloud)" = cursor-cloud-run-terminal ] \
    || fail 'the cancellation acknowledgement must come from the run endpoint'
  [ "$(fm_control_exit_command cursor-cloud)" = '!exit' ] \
    || fail 'the exit command must be the shim line that cancels and stops'
  [ "$(fm_control_harness_wiring_paths cursor-cloud /wt /st id1)" = /st/id1.cursor-cloud ] \
    || fail 'the run record must be retired as per-task wiring on a relaunch'

  got=$(fm_busy_sources_for_harness cursor-cloud)
  case " $got " in
    *" $FM_CURSOR_CLOUD_BUSY_SOURCE "*) ;;
    *) fail "the shim's busy source must be trusted for cursor-cloud, got '$got'" ;;
  esac
  case " $(fm_busy_sources_for_harness claude) " in
    *" $FM_CURSOR_CLOUD_BUSY_SOURCE "*)
      fail 'the shim busy source must not be trusted for another adapter' ;;
  esac
  pass 'the control-plane and busy-state tables declare cursor-cloud correctly'
}

# --- 10. the spawn and teardown paths ---------------------------------------
#
# These drive the REAL bin/fm-spawn.sh and bin/fm-teardown.sh with a fake tmux,
# a fake treehouse, and a fake curl, the same shape tests/fm-grok-harness.test.sh
# uses. Nothing here touches a real session provider, a real worktree pool, or
# the network.

make_spawn_fakebin() {  # <case-dir> -> prints the fakebin
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  send-keys) printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
cat >/dev/null
prev= out= url= method=GET
for a in "$@"; do
  case "$prev" in -X) method=$a ;; -o) out=$a ;; esac
  case "$a" in https://*) url=$a ;; esac
  prev=$a
done
printf '%s %s\n' "$method" "$url" >> "$FM_FAKE_CURL_LOG"
case "$url" in
  */cancel) [ -z "$out" ] || : > "$out"; printf '200' ;;
  */runs/*) [ -z "$out" ] || printf '{"status":"CANCELLED"}' > "$out"; printf '200' ;;
  *) [ -z "$out" ] || : > "$out"; printf '200' ;;
esac
SH
  chmod +x "$fakebin/curl"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

new_spawn_case() {  # <name> -> prints "<dir>|<home>|<proj>|<wt>|<fakebin>|<id>"
  local name=$1 dir home proj wt fakebin id
  dir="$TMP_ROOT/spawn-$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  id="cc-spawn-$name"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$dir/api"
  printf 'do the thing\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  fakebin=$(make_spawn_fakebin "$dir")
  printf '%s|%s|%s|%s|%s|%s\n' "$dir" "$home" "$proj" "$wt" "$fakebin" "$id"
}

run_spawn() {  # <dir> <home> <proj> <wt> <fakebin> <id> [spawn args...]
  local dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_CURL_LOG="$dir/curl.log" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" cursor-cloud --mode direct-PR --yolo off "$@" 2>&1
}

test_spawn_launches_the_shim_with_its_own_identity() {
  local dir home proj wt fakebin id out status launch gen
  IFS='|' read -r dir home proj wt fakebin id <<EOF
$(new_spawn_case plain)
EOF
  out=$(run_spawn "$dir" "$home" "$proj" "$wt" "$fakebin" "$id" \
    --model claude-opus-5 --effort high)
  status=$?
  expect_code 0 "$status" "a cursor-cloud spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=cursor-cloud" 'the spawn must report the harness'

  launch=$(grep -F 'fm-cursor-cloud.sh' "$dir/tmux.log" | head -1)
  [ -n "$launch" ] || fail "no shim launch command reached the pane: $(cat "$dir/tmux.log")"
  assert_contains "$launch" 'exec -a cursor-cloud bash ' \
    'the launch must give the pane process its own argv[0], or a live worker reads as a shell'
  assert_contains "$launch" "run --id '$id'" 'the shim must be told which task it serves'
  assert_contains "$launch" "--brief '$home/data/$id/brief.md'" \
    'the brief must be passed as a path, not typed'
  assert_contains "$launch" '--worktree ' 'the shim must be told its local copy'
  assert_contains "$launch" "--model 'claude-opus-5'" 'the model must reach the shim'
  assert_contains "$launch" "--effort 'high'" 'the effort must reach the shim'
  assert_not_contains "$launch" '--env-name' 'no environment is pinned without the config file'

  gen=$(sed -n 's/^busy_gen=//p' "$home/state/$id.meta")
  [ -n "$gen" ] || fail "the busy contract must be armed for a cursor-cloud task: $(cat "$home/state/$id.meta")"
  assert_contains "$launch" "--busy-gen '$gen'" \
    'the shim must carry the armed generation so its own lifecycle can write the busy record'
  assert_line "$home/state/$id.meta" 'harness=cursor-cloud' 'the harness must be recorded'
  pass 'a cursor-cloud spawn launches the shim with its own pane identity and task wiring'
}

test_spawn_pins_a_configured_cursor_environment() {
  local dir home proj wt fakebin id out launch
  IFS='|' read -r dir home proj wt fakebin id <<EOF
$(new_spawn_case env)
EOF
  printf '# a comment\n\nMy service (cloud agent)\nignored second line\n' \
    > "$home/config/cursor-cloud-env"
  out=$(run_spawn "$dir" "$home" "$proj" "$wt" "$fakebin" "$id") \
    || fail "spawn with a pinned environment failed: $out"
  launch=$(grep -F 'fm-cursor-cloud.sh' "$dir/tmux.log" | head -1)
  assert_contains "$launch" "--env-name 'My service (cloud agent)'" \
    'the configured environment name must reach the shim, quoted'
  pass 'config/cursor-cloud-env pins the run to a configured Cursor environment'
}

test_spawn_refuses_a_secondmate() {
  local dir home proj wt fakebin id out status
  IFS='|' read -r dir home proj wt fakebin id <<EOF
$(new_spawn_case secondmate)
EOF
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_CURL_LOG="$dir/curl.log" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" --secondmate "$id" "$dir/nowhere" cursor-cloud 2>&1)
  status=$?
  [ "$status" != 0 ] || fail "a cursor-cloud secondmate must be refused: $out"
  assert_contains "$out" 'crewmate/scout adapter only' \
    'the refusal must name the crewmate/scout boundary rather than a generic error'
  pass 'a cursor-cloud secondmate spawn is refused'
}

test_teardown_cancels_a_still_active_run() {
  local dir home proj wt fakebin id out
  IFS='|' read -r dir home proj wt fakebin id <<EOF
$(new_spawn_case teardown)
EOF
  out=$(run_spawn "$dir" "$home" "$proj" "$wt" "$fakebin" "$id") \
    || fail "spawn before teardown failed: $out"
  # The shim would normally write this itself; the case stands in for one that
  # launched a run and then died, which is exactly what teardown backstops.
  fm_cursor_cloud_record_set "$home/state" "$id" agent=bc-77 run=run-77 status=RUNNING
  : > "$dir/curl.log"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_CURL_LOG="$dir/curl.log" \
    CURSOR_API_KEY=teardown-key FM_CURSOR_CLOUD_CANCEL_WAIT=1 FM_CURSOR_CLOUD_POLL=0.1 \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1) \
    || fail "teardown failed: $out"

  assert_grep 'agents/bc-77/runs/run-77/cancel' "$dir/curl.log" \
    'teardown must cancel a still-active cloud run rather than leave it billing'
  assert_absent "$home/state/$id.cursor-cloud" 'teardown must remove the run record'
  pass 'teardown cancels a still-active cloud run and removes its record'
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
test_shim_pane_process_classifies_as_an_agent
test_control_tables_declare_cursor_cloud
test_spawn_launches_the_shim_with_its_own_identity
test_spawn_pins_a_configured_cursor_environment
test_spawn_refuses_a_secondmate
test_teardown_cancels_a_still_active_run
