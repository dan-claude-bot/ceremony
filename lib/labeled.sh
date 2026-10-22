#!/usr/bin/env bash
# lib/labeled.sh — the LABELED fact (#628): is a merged, `release`-labeled
# pull request behind MERGE_SHA? Prints `yes` or `no` on stdout, one
# diagnostic line per read on stderr.
#
# Why its own file, and why it retries: lib/facts.sh read it once, with
# `gh api …/commits/<sha>/pulls -q …`, and any failure read as `no`. A
# consumer (heavy-duty/la-familia-site#907) saw that read answer an EMPTY
# body four times on runs whose pull request was labeled `release` — the
# same call outside the job, and the consumer's own guard job in the same
# runs, returned it — so decide row 5 refused real releases and nothing
# shipped until a person pushed the tag. The cause of the empty answer is
# not known; the read is made robust to it rather than to a guess:
#
#   1. The association read, up to 3 times, a pause between
#      (CEREMONY_LABEL_RETRY_SECONDS, default 5; the tests set 0). An answer
#      is usable only when gh exits 0 and the body is a JSON array; an array
#      without a merged `release`-labeled PR is retried too, since an
#      association not computed yet answers `[]`.
#   2. Then once by search: merged pull requests found by the SHA, of which
#      only one whose merge commit IS MERGE_SHA counts — a pull request that
#      merely contains the commit does not.
#   3. Otherwise `no`: fail-closed stays (decide row 5 refuses).
#
# Env in: GITHUB_REPOSITORY, MERGE_SHA, GH_TOKEN (for gh).
set -euo pipefail

: "${GITHUB_REPOSITORY:?labeled: GITHUB_REPOSITORY is required}"
: "${MERGE_SHA:?labeled: MERGE_SHA is required}"
pause="${CEREMONY_LABEL_RETRY_SECONDS:-5}"
attempts=3

# shellcheck disable=SC2016 # jq programs, not shell expansions
association='[.[] | select(.merged_at != null) | .labels[].name] | index("release") != null'
# shellcheck disable=SC2016
by_merge_commit='[.[] | select(.mergeCommit.oid == $sha) | .labels[].name] | index("release") != null'

# read_verdict <rc> <body> <jq program> — usable-yes | usable-no | unusable
read_verdict() {
  if [ "$1" -ne 0 ] || ! printf '%s' "$2" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo unusable
  elif printf '%s' "$2" | jq -e --arg sha "$MERGE_SHA" "$3" >/dev/null 2>&1; then
    echo usable-yes
  else
    echo usable-no
  fi
}

i=1
while [ "$i" -le "$attempts" ]; do
  rc=0
  body="$(gh api "repos/$GITHUB_REPOSITORY/commits/$MERGE_SHA/pulls" 2>/dev/null)" || rc=$?
  verdict="$(read_verdict "$rc" "$body" "$association")"
  echo "labeled: association read $i/$attempts: gh exit $rc, $(printf '%s' "$body" | wc -c | tr -d ' ') bytes, $verdict" >&2
  if [ "$verdict" = usable-yes ]; then
    echo yes
    exit 0
  fi
  [ "$i" -lt "$attempts" ] && sleep "$pause"
  i=$((i + 1))
done

rc=0
body="$(gh pr list -R "$GITHUB_REPOSITORY" --state merged --search "$MERGE_SHA" --json number,labels,mergeCommit 2>/dev/null)" || rc=$?
verdict="$(read_verdict "$rc" "$body" "$by_merge_commit")"
echo "labeled: search read: gh exit $rc, $(printf '%s' "$body" | wc -c | tr -d ' ') bytes, $verdict" >&2
if [ "$verdict" = usable-yes ]; then
  echo yes
else
  echo no
fi
