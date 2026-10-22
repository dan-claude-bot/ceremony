#!/usr/bin/env bash
# Contract tests for lib/labeled.sh (#628): the release-label read retries an
# empty answer, falls back to a merge-SHA search, and still reads `no` when
# nothing shows the label. A gh stub on PATH answers each call from a script
# and logs it, so the number and kind of calls are asserted, offline. set -u,
# not -e: failing commands are behavior for the harness to inspect.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"

LABELED="$ROOT/lib/labeled.sh"
SHA="0123456789abcdef0123456789abcdef01234567"
OTHER="fedcba9876543210fedcba9876543210fedcba98"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The stub: the Nth `gh api` call answers line N of $GH_API_SCRIPT
# ("<exit code> <body>"; a body of `-` is empty); `gh pr list` answers
# $GH_SEARCH_BODY with exit $GH_SEARCH_RC. Every call is logged.
mkdir -p "$TMP/stub"
cat >"$TMP/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$1 ${2:-}" >>"$GH_LOG"
case "$1 ${2:-}" in
  "api "*)
    n="$(grep -c '^api' "$GH_LOG")"
    line="$(sed -n "${n}p" "$GH_API_SCRIPT")"
    rc="${line%% *}"
    body="${line#* }"
    [ "$body" = - ] || printf '%s\n' "$body"
    exit "${rc:-1}"
    ;;
  "pr list")
    [ "${GH_SEARCH_BODY:--}" = - ] || printf '%s\n' "$GH_SEARCH_BODY"
    exit "${GH_SEARCH_RC:-0}"
    ;;
  *)
    echo "gh stub: unexpected call: gh $*" >&2
    exit 97
    ;;
esac
STUB
chmod +x "$TMP/stub/gh"

LABELLED='[{"number":905,"merged_at":"2026-10-22T16:07:45Z","labels":[{"name":"scope:site"},{"name":"release"}]}]'
UNLABELLED='[{"number":905,"merged_at":"2026-10-22T16:07:45Z","labels":[{"name":"scope:site"}]}]'

# run <name> <api script lines...> — run labeled.sh against the stub; leave
# stdout in $TMP/<name>.out, stderr in .err and the call log in .log.
run() {
  local name="$1"
  shift
  printf '%s\n' "$@" >"$TMP/$name.script"
  : >"$TMP/$name.log"
  env PATH="$TMP/stub:$PATH" GITHUB_REPOSITORY=fixture/fixture MERGE_SHA="$SHA" GH_TOKEN=stub \
    CEREMONY_LABEL_RETRY_SECONDS=0 GH_LOG="$TMP/$name.log" GH_API_SCRIPT="$TMP/$name.script" \
    bash "$LABELED" >"$TMP/$name.out" 2>"$TMP/$name.err"
}
calls() { grep -c "^$2" "$TMP/$1.log" || true; }
verdict() { cat "$TMP/$1.out"; }

# --- an empty answer twice, then the labelled pull request -----------------
run twice "0 -" "0 -" "0 $LABELLED"
check "empty twice, then labelled: yes" 0 "yes" verdict twice
check "…after exactly 3 association calls" 0 "3" calls twice api
check "…and no search call" 0 "0" calls twice "pr list"
check "each attempt logs its exit code, size and verdict" 0 "labeled: association read 1/3: gh exit 0, 0 bytes, unusable" cat "$TMP/twice.err"
check "…the third one usable-yes" 0 "association read 3/3: gh exit 0, ${#LABELLED} bytes, usable-yes" cat "$TMP/twice.err"

# --- empty three times; the search finds the merge commit, labelled --------
export GH_SEARCH_BODY="[{\"number\":905,\"mergeCommit\":{\"oid\":\"$SHA\"},\"labels\":[{\"name\":\"release\"}]}]"
run search "0 -" "0 -" "0 -"
check "empty ×3, the search labelled at MERGE_SHA: yes" 0 "yes" verdict search
check "…after 3 association calls" 0 "3" calls search api
check "…and 1 search call" 0 "1" calls search "pr list"
check "the search read logs its line" 0 "labeled: search read: gh exit 0" cat "$TMP/search.err"

# --- the search's only entries merged another commit, or carry no label ----
export GH_SEARCH_BODY="[{\"number\":7,\"mergeCommit\":{\"oid\":\"$OTHER\"},\"labels\":[{\"name\":\"release\"}]}]"
run othercommit "0 -" "0 -" "0 -"
check "a labelled pull request merged at another commit does not count: no" 0 "no" verdict othercommit
export GH_SEARCH_BODY="[{\"number\":905,\"mergeCommit\":{\"oid\":\"$SHA\"},\"labels\":[{\"name\":\"scope:site\"}]}]"
run nolabel "0 $UNLABELLED" "0 $UNLABELLED" "0 $UNLABELLED"
check "the pull request has no release label anywhere: no" 0 "no" verdict nolabel
check "…an array without the label is retried, 3 association calls" 0 "3" calls nolabel api
check "…logged usable-no" 0 "association read 1/3: gh exit 0" cat "$TMP/nolabel.err"
check "…and usable-no, not unusable" 0 "usable-no" cat "$TMP/nolabel.err"

# --- gh failing on every call: fail-closed ----------------------------------
export GH_SEARCH_RC=1 GH_SEARCH_BODY=-
run failing "1 -" "1 -" "1 -"
check "gh failing on every call: no (fail-closed)" 0 "no" verdict failing
check "…after 3 association calls" 0 "3" calls failing api
check "…and 1 search call" 0 "1" calls failing "pr list"
check "…each logged with gh's exit code" 0 "association read 2/3: gh exit 1, 0 bytes, unusable" cat "$TMP/failing.err"
check "…the search too" 0 "labeled: search read: gh exit 1, 0 bytes, unusable" cat "$TMP/failing.err"
unset GH_SEARCH_RC

# --- a non-JSON body is unusable, never parsed as a verdict -----------------
export GH_SEARCH_BODY=-
run garbage "0 <html>oops</html>" "0 {\"message\":\"x\"}" "0 $LABELLED"
check "a non-JSON body, then an object, then the label: yes on the third" 0 "yes" verdict garbage
check "…the object is unusable (not an array)" 0 "association read 2/3: gh exit 0, 15 bytes, unusable" cat "$TMP/garbage.err"

# --- the first answer usable: one call, nothing else -----------------------
run first "0 $LABELLED"
check "labelled at once: yes after 1 call" 0 "1" calls first api
check "…stdout is exactly yes" 0 "yes" verdict first

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
