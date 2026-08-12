#!/usr/bin/env bash
# bin/fm-cursor-cloud-lib.sh - the ONE owner of the cursor-cloud harness's
# durable data contracts: its run record, the Cursor run-status vocabulary, the
# run-status to firstmate status-line mapping, and Server-Sent-Events frame
# decoding.
#
# bin/fm-cursor-cloud.sh owns the network and lifecycle mechanics; this file
# owns only what more than one caller must agree on, so the shim, bin/fm-send.sh,
# bin/fm-control.sh, and bin/fm-teardown.sh can never hold a private copy of it.
# It has no side effects on source, runs no network command, and is safe under
# both `set -u` and `set -e`.
#
# THE RUN RECORD: state/<id>.cursor-cloud, one `key=value` line per field,
# atomically replaced by fm_cursor_cloud_record_set. It is the shim's own
# explicit state, never a reading of rendered pane text:
#
#   v=1                 record version
#   agent=bc-<uuid>     the cloud agent this task launched
#   run=run-<uuid>      the most recent run of that agent
#   status=<STATUS>     that run's last observed status, from the vocabulary below
#   url=<url>           the agent's own web URL, for a human following along
#   stdin_seq=<uint>    how many input lines the shim has accepted, ever
#
# `status` is what lets bin/fm-teardown.sh cancel a still-active run instead of
# leaving it running and billing, and `stdin_seq` is what lets bin/fm-send.sh
# confirm a steer from the shim's own acknowledgement rather than from a
# composer shape the shim does not draw. A missing record means the shim has not
# launched a run yet, which is never the same as a run that finished.
#
# THE STATUS VOCABULARY is Cursor's, verbatim: CREATING and RUNNING are active,
# and FINISHED, ERROR, CANCELLED, and EXPIRED are terminal. Anything else is
# neither, so an unrecognized value can never be mistaken for a finished run.

# The semantic busy-state source name the shim is trusted to write.
# bin/fm-busy-lib.sh's fm_busy_sources_for_harness declares the same name as the
# only source trusted for harness=cursor-cloud; this is the definition the shim
# passes to bin/fm-busy-event.sh, so a rename has exactly two sites.
# shellcheck disable=SC2034  # read by bin/fm-cursor-cloud.sh, which sources this file
FM_CURSOR_CLOUD_BUSY_SOURCE=cursor-cloud-shim

fm_cursor_cloud_record_path() {  # <state-dir> <id>
  printf '%s/%s.cursor-cloud' "$1" "$2"
}

# fm_cursor_cloud_record_get: print one field's value, or nothing when the
# record or the field is absent. The LAST occurrence wins, matching how
# fm_meta_get reads task metadata.
fm_cursor_cloud_record_get() {  # <state-dir> <id> <key>
  local rec line value=''
  rec=$(fm_cursor_cloud_record_path "$1" "$2")
  [ -f "$rec" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$3="*) value=${line#"$3="} ;;
    esac
  done < "$rec"
  printf '%s' "$value"
}

# fm_cursor_cloud_record_set: merge `key=value` pairs into the record and
# replace it atomically, so a reader never sees a half-written record. Keys not
# named are preserved; a named key is replaced rather than duplicated.
fm_cursor_cloud_record_set() {  # <state-dir> <id> <key>=<value>...
  local state=$1 id=$2 rec tmp pair key line
  shift 2
  rec=$(fm_cursor_cloud_record_path "$state" "$id")
  tmp="$rec.tmp.$$"
  {
    printf 'v=1\n'
    if [ -f "$rec" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          v=*) continue ;;
        esac
        key=${line%%=*}
        for pair in "$@"; do
          [ "$key" != "${pair%%=*}" ] || continue 2
        done
        printf '%s\n' "$line"
      done < "$rec"
    fi
    for pair in "$@"; do
      printf '%s\n' "$pair"
    done
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$rec"
}

fm_cursor_cloud_status_active() {  # <status>
  case "${1:-}" in
    CREATING|RUNNING) return 0 ;;
  esac
  return 1
}

fm_cursor_cloud_status_terminal() {  # <status>
  case "${1:-}" in
    FINISHED|ERROR|CANCELLED|EXPIRED) return 0 ;;
  esac
  return 1
}

# fm_cursor_cloud_one_line: collapse whitespace and bound length, so a model's
# multi-paragraph result can never turn one status append into many lines or an
# unbounded one. Prints nothing for empty input.
fm_cursor_cloud_one_line() {  # <text> [max-chars]
  local text=${1:-} max=${2:-160}
  text=$(printf '%s' "$text" | tr '\n\r\t' '   ' | tr -s ' ')
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  [ -n "$text" ] || return 0
  if [ "${#text}" -gt "$max" ]; then
    printf '%s...' "${text:0:$max}"
  else
    printf '%s' "$text"
  fi
}

# fm_cursor_cloud_status_line: the firstmate status line one terminal run
# status deserves, as `<state>: <text>`. The caller owns WHEN to append it;
# this owns WHAT it says. An active status maps to the single `working:` line a
# launch reports, never one line per streamed event.
#
# A FINISHED run with a pull-request URL is the deliverable, so its line
# carries the URL. A FINISHED run without one still finished, and saying so
# explicitly is what keeps a supervisor from waiting for a PR that will never
# arrive. An unrecognized status is reported as unknown rather than folded into
# a finished or failed verdict.
fm_cursor_cloud_status_line() {  # <status> [pr-url] [text] [run-id]
  local status=${1:-} pr=${2:-} text=${3:-} run=${4:-} summary
  summary=$(fm_cursor_cloud_one_line "$text")
  case "$status" in
    CREATING|RUNNING)
      printf 'working: cursor cloud run %s under way' "${run:-unknown}"
      ;;
    FINISHED)
      if [ -n "$pr" ]; then
        printf 'done: PR %s' "$pr"
      else
        printf 'done: %s (no PR opened)' "${summary:-run finished}"
      fi
      ;;
    ERROR)
      printf 'failed: %s' "${summary:-run failed}"
      ;;
    CANCELLED)
      printf 'failed: run cancelled'
      ;;
    EXPIRED)
      printf 'failed: run expired'
      ;;
    *)
      printf 'blocked: cursor cloud run %s reported an unrecognized status %s' \
        "${run:-unknown}" "${status:-none}"
      ;;
  esac
}

# fm_cursor_cloud_lost_contact_line: the status line for a stream that could
# not be re-established. It is deliberately `blocked:` and never `failed:`: the
# run itself may still be running, and only GET /v1/agents/{id}/runs/{runId} is
# authority on that.
fm_cursor_cloud_lost_contact_line() {  # <run-id>
  printf 'blocked: lost contact with cloud run %s' "${1:-unknown}"
}

# _fm_cursor_cloud_sse_emit: print one decoded frame as `<type><TAB><data>`.
# The `event:` field wins; a frame with only a data payload is typed from its
# own `type` member, and an untypeable frame is `message` rather than dropped,
# so nothing is silently lost.
_fm_cursor_cloud_sse_emit() {  # <event> <data> <have-data>
  local ev=${1:-} data=${2:-} have=${3:-0} type
  [ -n "$ev" ] || [ "$have" = 1 ] || return 0
  type=$ev
  if [ -z "$type" ] && [ "$have" = 1 ]; then
    type=$(printf '%s' "$data" \
      | jq -r 'if type == "object" and has("type") then .type else empty end' 2>/dev/null) || type=
  fi
  [ -n "$type" ] || type=message
  case "$type" in
    *[!A-Za-z0-9._-]*) type=message ;;
  esac
  printf '%s\t%s\n' "$type" "$data"
}
# fm_cursor_cloud_sse_decode: decode a Server-Sent-Events stream on stdin into
# one tab-separated `<type><TAB><json>` line per frame on stdout.
#
# The three shapes that make a hand-rolled decoder wrong are all handled here.
# A frame's fields arrive as separate lines and are only complete at the blank
# line that ends it, so nothing is emitted before that. Multiple `data:` lines
# in one frame are joined with a space rather than a newline, which keeps a JSON
# payload valid while keeping the decoded frame on exactly one output line. And
# a stream that ends without its final blank line still emits the frame it was
# accumulating, because a dropped connection must not silently discard the last
# event received before it dropped.
#
# Comment/keepalive lines (`:` ...) and the `id:` and `retry:` fields carry no
# frame content and are skipped. Unknown fields are skipped for the same reason.
fm_cursor_cloud_sse_decode() {
  local line ev='' data='' have=0 field
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      '')
        _fm_cursor_cloud_sse_emit "$ev" "$data" "$have"
        ev=''
        data=''
        have=0
        ;;
      :*) ;;
      event:*)
        field=${line#event:}
        ev=${field# }
        ;;
      data:*)
        field=${line#data:}
        field=${field# }
        if [ "$have" = 1 ]; then
          data="$data $field"
        else
          data=$field
          have=1
        fi
        ;;
      *) ;;
    esac
  done
  _fm_cursor_cloud_sse_emit "$ev" "$data" "$have"
}

# fm_cursor_cloud_submit: deliver one line of text to the shim and confirm it
# from the shim's OWN acknowledgement - its accepted-input counter advancing -
# rather than from a composer shape. The shim is not a TUI and draws no
# composer, so every composer-shaped verdict would be `unknown` and every
# genuine delivery would be reported unconfirmed.
#
# Prints the same vocabulary the composer path prints, so callers need no new
# verdict handling: `empty` for a confirmed delivery, `pending` when the counter
# never advanced, and `send-failed` when the text could not be typed at all.
#
# Typing still goes through the backend's own verified submit primitive, so each
# session provider keeps owning how bytes and Enter reach its pane; only the
# VERDICT is replaced. Its composer-shaped answer is discarded rather than
# trusted, and an extra Enter it may send while chasing that answer is harmless
# here: the shim ignores an empty input line without counting it.
# Requires bin/fm-backend.sh to be sourced already.
fm_cursor_cloud_submit() {  # <state-dir> <id> <backend> <target> <text> <retries> <sleep>
  local state=$1 id=$2 backend=$3 target=$4 text=$5 retries=${6:-3} sleep_s=${7:-0.4}
  local before after i=0 typed
  before=$(fm_cursor_cloud_record_get "$state" "$id" stdin_seq)
  case "$before" in
    ''|*[!0-9]*) before=0 ;;
  esac
  typed=$(fm_backend_send_text_submit "$backend" "$target" "$text" "$retries" "$sleep_s" 0.3) \
    || { printf 'send-failed'; return 0; }
  [ "$typed" != send-failed ] || { printf 'send-failed'; return 0; }
  while [ "$i" -lt "$retries" ]; do
    sleep "$sleep_s"
    after=$(fm_cursor_cloud_record_get "$state" "$id" stdin_seq)
    [ -n "$after" ] || after=0
    case "$after" in
      *[!0-9]*) after=0 ;;
    esac
    if [ "$after" -gt "$before" ] 2>/dev/null; then
      printf 'empty'
      return 0
    fi
    i=$((i + 1))
  done
  printf 'pending'
}
