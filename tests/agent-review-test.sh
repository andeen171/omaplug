#!/bin/bash
# Tests agent-review.sh's clone/bundle protocol (shared across every agent)
# and each agent-specific adapter, with the real claude/codex/opencode/
# omarchy-default-agent/omarchy-cmd-missing binaries replaced by stubs.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

BIN="$TMP/bin"
LOG="$TMP/calls.log"
STDIN_COPY="$TMP/stdin.txt"
TEST_HOME="$TMP/home"
REPO="$TMP/repo"
mkdir -p -- "$BIN" "$TEST_HOME" "$REPO"

# A fixture repository with the shapes the bundler has to handle: two text
# files, a binary, and one over the per-file cap.
git init -q -b main "$REPO"
git -C "$REPO" config user.name "Omaplug Tests"
git -C "$REPO" config user.email "omaplug-tests@example.invalid"
printf '{"id":"fixture","name":"Fixture"}\n' > "$REPO/manifest.json"
printf 'import QtQuick\nItem { Component.onCompleted: console.log("MARKER_QML") }\n' > "$REPO/Widget.qml"
printf '\x89PNG\r\n\x1a\n\x00\x00BINARY' > "$REPO/preview.png"
head -c $((300 * 1024)) /dev/zero | tr '\0' 'x' > "$REPO/huge.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "fixture"
SHA=$(git -C "$REPO" rev-parse HEAD)

# omarchy-default-agent: reports whatever OMAPLUG_TEST_AGENT says, like the
# real `omarchy default agent` (no args) reading the user's chosen agent.
cat > "$BIN/omarchy-default-agent" <<'STUB'
#!/bin/bash
printf '%s\n' "${OMAPLUG_TEST_AGENT-claude}"
STUB
chmod +x "$BIN/omarchy-default-agent"

# omarchy-cmd-missing: never reports an agent missing in these tests (each
# case controls availability by whether the stub binary exists on PATH).
cat > "$BIN/omarchy-cmd-missing" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$BIN/omarchy-cmd-missing"

# The claude stub records its arguments and stdin, then answers like the real
# CLI's --output-format json does. OMAPLUG_TEST_MODE picks the shape.
cat > "$BIN/claude" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" > "$OMAPLUG_TEST_LOG"
cat > "$OMAPLUG_TEST_STDIN"
case "${OMAPLUG_TEST_MODE:-ok}" in
  ok)
    printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.42,"duration_ms":1234,"result":"{}","structured_output":{"verdict":"caution","summary":"Fixture summary.","capabilities":["logs to console"],"findings":[{"severity":"low","title":"Console logging","file":"Widget.qml","detail":"Logs a marker at startup."}],"prompt_injection_detected":false}}\n'
    ;;
  error)
    printf '{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}\n'
    exit 1
    ;;
  garbage)
    printf 'not json at all\n'
    exit 3
    ;;
esac
STUB
chmod +x "$BIN/claude"

# The codex stub records its arguments and stdin, then writes the schema'd
# JSON to the --output-last-message file the way `codex exec
# --output-schema ... --output-last-message <file>` does.
cat > "$BIN/codex" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" > "$OMAPLUG_TEST_LOG"
cat > "$OMAPLUG_TEST_STDIN"
last=""
prev=""
for arg in "$@"; do
  if [[ $prev == "--output-last-message" ]]; then last="$arg"; fi
  prev="$arg"
done
case "${OMAPLUG_TEST_MODE:-ok}" in
  ok)
    printf '{"verdict":"safe","summary":"Codex fixture summary.","capabilities":["no network"],"findings":[],"prompt_injection_detected":false}' > "$last"
    ;;
  garbage)
    printf 'not json' > "$last"
    ;;
esac
STUB
chmod +x "$BIN/codex"

# The opencode stub records its arguments and stdin, then streams JSONL
# events the way `opencode run --format json` does: a text part carrying the
# answer, and a step_finish part carrying the turn's cost.
cat > "$BIN/opencode" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" > "$OMAPLUG_TEST_LOG"
cat > "$OMAPLUG_TEST_STDIN"
case "${OMAPLUG_TEST_MODE:-ok}" in
  ok)
    printf '{"type":"step_start","part":{"type":"step-start"}}\n'
    printf '{"type":"text","part":{"type":"text","text":"{\\"verdict\\":\\"danger\\",\\"summary\\":\\"Opencode fixture summary.\\",\\"capabilities\\":[],\\"findings\\":[],\\"prompt_injection_detected\\":true}"}}\n'
    printf '{"type":"step_finish","part":{"type":"step-finish","cost":0.0123}}\n'
    ;;
  garbage)
    printf '{"type":"text","part":{"type":"text","text":"not json"}}\n'
    printf '{"type":"step_finish","part":{"type":"step-finish","cost":0}}\n'
    ;;
esac
STUB
chmod +x "$BIN/opencode"

export PATH="$BIN:/usr/bin:/bin"
export HOME="$TEST_HOME"
export OMAPLUG_TEST_LOG="$LOG"
export OMAPLUG_TEST_STDIN="$STDIN_COPY"

assert_line() {
  local line="$1"
  local file="$2"
  grep -Fqx -- "$line" "$file" || {
    printf 'FAIL: missing line %q in %s\n' "$line" "$file" >&2
    cat "$file" >&2
    exit 1
  }
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || {
    printf 'FAIL: %s does not contain %q\n' "$file" "$needle" >&2
    exit 1
  }
}

# ------------------------------------------------------------ claude happy path

OUT="$TMP/out.claude"
WORK="$TMP/work-claude"
OMAPLUG_TEST_AGENT=claude OMAPLUG_TEST_MODE=ok "$ROOT/agent-review.sh" "$REPO" "$WORK" > "$OUT"
assert_line $'stage\tclone' "$OUT"
assert_line "commit	$SHA" "$OUT"
assert_line $'stage\tbundle' "$OUT"
assert_line $'stage\treview' "$OUT"
# manifest.json + Widget.qml; the png is binary and huge.txt is over the cap.
grep -q $'^files\t2\t[0-9]*\t1$' "$OUT" || { printf 'FAIL: files line wrong\n' >&2; cat "$OUT" >&2; exit 1; }

review=$(grep $'^review\t' "$OUT" | cut -f2-)
[[ -n $review ]] || { printf 'FAIL: no review line\n' >&2; exit 1; }
[[ $(printf '%s' "$review" | jq -r .verdict) == caution ]] || { printf 'FAIL: verdict\n' >&2; exit 1; }
[[ $(printf '%s' "$review" | jq -r .commit) == "$SHA" ]] || { printf 'FAIL: commit not attached\n' >&2; exit 1; }
[[ $(printf '%s' "$review" | jq -r .agent) == claude ]] || { printf 'FAIL: agent not attached\n' >&2; exit 1; }
[[ $(printf '%s' "$review" | jq -r .model) == claude/claude-fable-5-1 ]] || { printf 'FAIL: default model\n' >&2; exit 1; }
[[ $(printf '%s' "$review" | jq -r .cost_usd) == 0.42 ]] || { printf 'FAIL: cost not attached\n' >&2; exit 1; }
[[ $(printf '%s' "$review" | jq -r .truncated) == true ]] || { printf 'FAIL: truncated flag\n' >&2; exit 1; }
[[ $(printf '%s' "$review" | jq -r '.findings | length') == 1 ]] || { printf 'FAIL: findings\n' >&2; exit 1; }
[[ -s "$WORK/review.json" ]] || { printf 'FAIL: review.json not written\n' >&2; exit 1; }

# The reviewer got the source, the skip list, and the default flags.
assert_contains "MARKER_QML" "$STDIN_COPY"
assert_contains "BEGIN FILE Widget.qml" "$STDIN_COPY"
assert_contains "huge.txt" "$STDIN_COPY"
assert_contains "preview.png (binary)" "$STDIN_COPY"
grep -q 'BEGIN FILE preview.png' "$STDIN_COPY" && { printf 'FAIL: binary was bundled\n' >&2; exit 1; }
assert_contains "--tools  --disable-slash-commands" "$LOG"
assert_contains "--model claude-fable-5-1" "$LOG"
assert_contains "--json-schema" "$LOG"
assert_contains "--no-session-persistence" "$LOG"

# The delimiter nonce is per run, so a file cannot forge a boundary.
nonce=$(grep -o 'token [0-9a-f]\{24\}' "$STDIN_COPY" | head -n 1 | cut -d' ' -f2)
[[ -n $nonce ]] || { printf 'FAIL: no nonce in prompt\n' >&2; exit 1; }
assert_contains "===== $nonce BEGIN FILE manifest.json" "$STDIN_COPY"

# ------------------------------------------------------------ codex happy path

OUT2="$TMP/out.codex"
OMAPLUG_TEST_AGENT=codex OMAPLUG_TEST_MODE=ok "$ROOT/agent-review.sh" "$REPO" "$TMP/work-codex" > "$OUT2"
review2=$(grep $'^review\t' "$OUT2" | cut -f2-)
[[ $(printf '%s' "$review2" | jq -r .verdict) == safe ]] || { printf 'FAIL: codex verdict\n' >&2; exit 1; }
[[ $(printf '%s' "$review2" | jq -r .agent) == codex ]] || { printf 'FAIL: codex agent tag\n' >&2; exit 1; }
assert_contains "--ignore-user-config" "$LOG"
assert_contains "--disable shell_tool" "$LOG"
assert_contains "--sandbox read-only" "$LOG"

# ------------------------------------------------------------ opencode happy path

OUT3="$TMP/out.opencode"
OMAPLUG_TEST_AGENT=opencode OMAPLUG_TEST_MODE=ok "$ROOT/agent-review.sh" "$REPO" "$TMP/work-opencode" > "$OUT3"
review3=$(grep $'^review\t' "$OUT3" | cut -f2-)
[[ $(printf '%s' "$review3" | jq -r .verdict) == danger ]] || { printf 'FAIL: opencode verdict\n' >&2; exit 1; }
[[ $(printf '%s' "$review3" | jq -r .prompt_injection_detected) == true ]] || { printf 'FAIL: opencode prompt injection flag\n' >&2; exit 1; }
[[ $(printf '%s' "$review3" | jq -r .cost_usd) == 0.0123 ]] || { printf 'FAIL: opencode cost\n' >&2; exit 1; }
assert_contains "--agent reviewer" "$LOG"
assert_contains "--dir $TMP/work-opencode/scratch" "$LOG"
[[ -f "$TMP/work-opencode/scratch/.opencode/agent/reviewer.md" ]] || { printf 'FAIL: reviewer agent file not written\n' >&2; exit 1; }
grep -q '^mode: primary$' "$TMP/work-opencode/scratch/.opencode/agent/reviewer.md" || { printf 'FAIL: reviewer agent not primary mode\n' >&2; exit 1; }
for perm in edit bash webfetch websearch task todowrite question read glob grep list lsp skill; do
  grep -q "^  $perm: deny$" "$TMP/work-opencode/scratch/.opencode/agent/reviewer.md" \
    || { printf 'FAIL: reviewer agent does not deny %s\n' "$perm" >&2; exit 1; }
done

# ------------------------------------------------------------ unsupported / missing agent

OUT4="$TMP/out.unsupported"
if OMAPLUG_TEST_AGENT=grok "$ROOT/agent-review.sh" "$REPO" "$TMP/work-unsupported" > "$OUT4"; then
  printf 'FAIL: unsupported agent should fail the helper\n' >&2; exit 1
fi
assert_contains $'error\tpre-install review is not available for' "$OUT4"

OUT5="$TMP/out.noagent"
if OMAPLUG_TEST_AGENT="" "$ROOT/agent-review.sh" "$REPO" "$TMP/work-noagent" > "$OUT5"; then
  printf 'FAIL: no default agent should fail the helper\n' >&2; exit 1
fi
assert_contains $'error\tno default coding agent set' "$OUT5"

OUT6="$TMP/out.nobinary"
mkdir -p "$TMP/bin-no-claude"
for f in omarchy-default-agent omarchy-cmd-missing codex opencode; do
  ln -s "$BIN/$f" "$TMP/bin-no-claude/$f" 2>/dev/null || true
done
if OMAPLUG_TEST_AGENT=claude PATH="$TMP/bin-no-claude:/usr/bin:/bin" "$ROOT/agent-review.sh" "$REPO" "$TMP/work-nobinary" > "$OUT6"; then
  printf 'FAIL: missing claude binary should fail the helper\n' >&2; exit 1
fi
assert_contains $'error\tclaude CLI not found' "$OUT6"

# ------------------------------------------------------------ failures (shared path)

OUT7="$TMP/out.err"
if OMAPLUG_TEST_AGENT=claude OMAPLUG_TEST_MODE=error "$ROOT/agent-review.sh" "$REPO" "$TMP/work-err" > "$OUT7"; then
  printf 'FAIL: claude error should fail the helper\n' >&2; exit 1
fi
assert_contains $'error\tclaude: Not logged in' "$OUT7"
grep -q $'^review\t' "$OUT7" && { printf 'FAIL: review line on error\n' >&2; exit 1; }

OUT8="$TMP/out.garbage"
if OMAPLUG_TEST_AGENT=claude OMAPLUG_TEST_MODE=garbage "$ROOT/agent-review.sh" "$REPO" "$TMP/work-garbage" > "$OUT8"; then
  printf 'FAIL: garbage output should fail the helper\n' >&2; exit 1
fi
assert_contains $'error\tclaude produced no JSON (exit 3)' "$OUT8"

OUT9="$TMP/out.noclone"
if OMAPLUG_TEST_AGENT=claude "$ROOT/agent-review.sh" "$TMP/does-not-exist" "$TMP/work-noclone" > "$OUT9"; then
  printf 'FAIL: bad URL should fail the helper\n' >&2; exit 1
fi
assert_contains $'error\tclone failed' "$OUT9"

printf 'agent-review-test: ok\n'
