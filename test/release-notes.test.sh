#!/usr/bin/env bash
# Contract tests for bin/release-notes (#635): an rc publishes the fragments
# new since the previous rc of its version, every release's notes are capped
# under GitHub's body limit, and validation is changelog-assemble's as before.
# Real git repositories with a bare remote, because the previous rc is found
# by its tag on the remote. set -u, not -e: failing commands are behavior.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"

TOOL="$ROOT/bin/release-notes"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# repo <name> — a work tree whose origin is a bare repository beside it, with
# a CHANGELOG and changelog.d/ at <name>/apps/admin (a prefixed track).
repo() {
  local r="$TMP/$1"
  git init -q --bare -b main "$r.git"
  git init -q -b main "$r"
  git -C "$r" remote add origin "$r.git"
  mkdir -p "$r/apps/admin/changelog.d"
  printf 'Machine-assembled; see heavy-duty/ceremony#112.\n' >"$r/apps/admin/changelog.d/README.md"
  printf '# Changelog\n\n## 1.9.0 — 2026-01-01\n\n- The old entry.\n' >"$r/apps/admin/CHANGELOG.md"
  git -C "$r" add -A
  git -C "$r" commit -q -m init
  git -C "$r" push -q origin main
}

# frag <repo> <name> <text> — a flat fragment.
frag() {
  printf -- '- %s\n' "$3" >"$TMP/$1/apps/admin/changelog.d/$2"
}

# tag <repo> <tag> — commit what is there, tag it, push both.
tag() {
  git -C "$TMP/$1" add -A
  git -C "$TMP/$1" commit -q --allow-empty -m "at $2"
  git -C "$TMP/$1" tag "$2"
  git -C "$TMP/$1" push -q origin main "$2"
}

# notes <repo> <args...> — run the tool from the repo's work tree, like the doors.
notes() {
  local r="$1"
  shift
  (cd "$TMP/$r" && "$TOOL" "$@" --changelog apps/admin/CHANGELOG.md --dir apps/admin/changelog.d)
}

# notes_fresh <repo> <args...> — the same from a fresh shallow clone, which is
# what a runner has: no tags locally, so the previous rc has to be fetched.
notes_fresh() {
  local r="$1" c="$TMP/$1-clone-$RANDOM"
  shift
  git clone -q --depth 1 --no-tags "file://$TMP/$r.git" "$c"
  (cd "$c" && "$TOOL" "$@" --changelog apps/admin/CHANGELOG.md --dir apps/admin/changelog.d)
}

# --- rc after rc: only the new fragments, with the lead line --------------

repo series
frag series 10.md "Ten shipped in rc1 (#10)."
frag series 11.md "Eleven shipped in rc1 (#11)."
tag series admin-2.0.0-rc1
frag series 12.md "Twelve is new in rc2 (#12)."
out="$(notes series 2.0.0-rc2 --tag-prefix admin- --full-url https://x.test/tree/admin-2.0.0-rc2/apps/admin/changelog.d 2>/dev/null)"
check "rc2 names the previous rc and links every entry" 0 "Changes since \`admin-2.0.0-rc1\`. Every entry for 2.0.0 so far: https://x.test/tree/admin-2.0.0-rc2/apps/admin/changelog.d" printf '%s' "$out"
check "rc2 carries the new fragment" 0 "Twelve is new in rc2 (#12)." printf '%s' "$out"
check_absent "rc2 leaves out what rc1 already published" 0 "Ten shipped in rc1" printf '%s' "$out"
check_absent "rc2 leaves out rc1's other fragment" 0 "Eleven shipped in rc1" printf '%s' "$out"
check "the count of new fragments is logged" 0 "1 fragment(s) new since admin-2.0.0-rc1" notes series 2.0.0-rc2 --tag-prefix admin-

git -C "$TMP/series" add -A && git -C "$TMP/series" commit -q -m "rc2 work" && git -C "$TMP/series" push -q origin main
check "a fresh shallow clone fetches the previous rc tag and gets the same notes" 0 "Twelve is new in rc2 (#12)." notes_fresh series 2.0.0-rc2 --tag-prefix admin-
check_absent "the fresh clone also leaves out rc1's fragments" 0 "Ten shipped in rc1" notes_fresh series 2.0.0-rc2 --tag-prefix admin-

# rc3 when the remote has rc1 and rc2: rc2 is the previous one.
tag series admin-2.0.0-rc2
frag series 13.md "Thirteen is new in rc3 (#13)."
out="$(notes series 2.0.0-rc3 --tag-prefix admin- 2>/dev/null)"
check "rc3 reads from rc2, the highest lower rc" 0 "Changes since \`admin-2.0.0-rc2\`." printf '%s' "$out"
check_absent "rc3 leaves out rc2's fragment" 0 "Twelve is new" printf '%s' "$out"
check "rc3 carries its own" 0 "Thirteen is new in rc3" printf '%s' "$out"

# A gap: rc5 with only rc1 and rc2 tagged reads from rc2.
check "a gap in the series reads from the highest lower rc" 0 "Changes since \`admin-2.0.0-rc2\`." notes series 2.0.0-rc5 --tag-prefix admin-

# A higher rc tag never counts as previous.
git -C "$TMP/series" tag admin-2.0.0-rc9 && git -C "$TMP/series" push -q origin admin-2.0.0-rc9
check_absent "a higher rc is never the previous one" 0 "admin-2.0.0-rc9" notes series 2.0.0-rc3 --tag-prefix admin-

# --- tracks and versions don't mix -----------------------------------------

repo tracks
frag tracks 20.md "Twenty (#20)."
tag tracks site-2.0.0-rc1
tag tracks admin-1.9.0-rc4
frag tracks 21.md "Twenty-one (#21)."
out="$(notes tracks 2.0.0-rc2 --tag-prefix admin- 2>&1)"
check "another track's rc is ignored: no previous rc, every fragment" 0 "no previous rc of 2.0.0; publishing every fragment" printf '%s' "$out"
check "another version's rc is ignored too, so every fragment is published" 0 "Twenty (#20)." printf '%s' "$out"

# --- first rc, missing tag, explicit --since ------------------------------

repo first
frag first 30.md "Thirty (#30)."
frag first 31.md "Thirty-one (#31)."
out="$(notes first 3.0.0-rc1 --tag-prefix admin- 2>/dev/null)"
check "the first rc publishes every fragment" 0 "Thirty (#30)." printf '%s' "$out"
check "the first rc publishes the other fragment too" 0 "Thirty-one (#31)." printf '%s' "$out"
check_absent "the first rc has no lead line" 0 "Changes since" printf '%s' "$out"
check "the first rc's notes equal changelog-assemble --check (the old behaviour)" 0 "" \
  test "$out" = "$(cd "$TMP/first" && "$ROOT/bin/changelog-assemble" 3.0.0-rc1 --check --changelog apps/admin/CHANGELOG.md --dir apps/admin/changelog.d)"
check "a --since that can't be read falls back to every fragment" 0 "could not be read; publishing every fragment" notes first 3.0.0-rc2 --since admin-3.0.0-rc1
check "no remote at all falls back to every fragment" 0 "Thirty (#30)." notes first 3.0.0-rc2 --tag-prefix admin- --remote nowhere

# --- an rc with nothing new ------------------------------------------------

repo quiet
frag quiet 40.md "Forty (#40)."
tag quiet 4.0.0-rc1
check "an rc with no new fragments says so and still publishes" 0 "No new changelog entries since \`4.0.0-rc1\`." notes quiet 4.0.0-rc2

# --- grouped fragments keep their groups -----------------------------------

repo grouped
printf 'grouped\n' >"$TMP/grouped/apps/admin/changelog.d/shape"
printf '### Added\n\n- Fifty (#50).\n' >"$TMP/grouped/apps/admin/changelog.d/50.md"
tag grouped 5.0.0-rc1
printf '### Fixed\n\n- Fifty-one (#51).\n' >"$TMP/grouped/apps/admin/changelog.d/51.md"
out="$(notes grouped 5.0.0-rc2 2>/dev/null)"
check "a grouped rc keeps its group heading" 0 "### Fixed" printf '%s' "$out"
check_absent "a grouped rc leaves out the earlier group" 0 "### Added" printf '%s' "$out"

# --- validation is changelog-assemble's -----------------------------------

repo bad
frag bad 60.md "Sixty (#60)."
tag bad 6.0.0-rc1
printf '## Smuggled heading\n- bad\n' >"$TMP/bad/apps/admin/changelog.d/61.md"
check "a malformed fragment still refuses the rc" 1 "changelog-assemble:" notes bad 6.0.0-rc2
repo empty
check "zero fragments still refuses the rc" 1 "zero fragments" notes empty 7.0.0-rc1

# --- finals ----------------------------------------------------------------

repo final
printf '# Changelog\n\n## 8.0.0 — 2026-11-20\n\n- The final entry (#80).\n\n## 1.9.0 — 2026-01-01\n\n- The old entry.\n' >"$TMP/final/apps/admin/CHANGELOG.md"
check "a final publishes its stamped section" 0 "The final entry (#80)." notes final 8.0.0
check_absent "a final publishes only its own section" 0 "The old entry" notes final 8.0.0
check "a final without its section refuses" 1 "no '## 8.0.1' section" notes final 8.0.1

# --- the cap ---------------------------------------------------------------

repo big
for i in $(seq 100 399); do
  frag big "$i.md" "Entry $i: $(printf 'x%.0s' $(seq 1 250)) (#$i)."
done
out="$(notes big 9.0.0-rc1 --limit 20000 --full-url https://x.test/full 2>"$TMP/big.err")"
size="$(printf '%s\n' "$out" | wc -c | tr -d ' ')"
check "over-limit notes are cut to the limit" 0 "" test "$size" -le 20000
check "the cut notes are still most of the limit" 0 "" test "$size" -ge 19000
check "the cut notes end with the link to every entry" 0 "Every entry: https://x.test/full" printf '%s' "$(printf '%s\n' "$out" | tail -n 1)"
check "the cut is logged" 0 "cut the notes from" cat "$TMP/big.err"
check "the cut lands on a whole entry: every kept line ends its fragment" 0 "" \
  bash -c 'printf "%s\n" "$1" | grep "^- Entry" | grep -vq "(#[0-9]*)\.$" && exit 1 || exit 0' _ "$out"
out="$(notes big 9.0.0-rc1 2>/dev/null)"
size="$(printf '%s\n' "$out" | wc -c | tr -d ' ')"
check "the default limit keeps 120 KB of notes whole" 0 "" test "$size" -lt 120000
check_absent "notes under the default limit are not cut" 0 "were cut" printf '%s' "$out"

repo bigfinal
{
  printf '# Changelog\n\n## 9.1.0 — 2026-11-20\n\n'
  for i in $(seq 1 400); do printf -- '- Final entry %s: %s.\n' "$i" "$(printf 'y%.0s' $(seq 1 400))"; done
} >"$TMP/bigfinal/apps/admin/CHANGELOG.md"
out="$(notes bigfinal 9.1.0 --full-url https://x.test/blob/9.1.0/apps/admin/CHANGELOG.md 2>/dev/null)"
size="$(printf '%s\n' "$out" | wc -c | tr -d ' ')"
check "a final over GitHub's limit is cut under the default 120000 bytes" 0 "" test "$size" -le 120000
check "the cut final links to the changelog" 0 "Every entry: https://x.test/blob/9.1.0/apps/admin/CHANGELOG.md" printf '%s' "$out"

check "a limit under 1000 bytes is refused" 1 "--limit must be" notes big 9.0.0-rc1 --limit 10
check "no version is a usage error" 2 "usage:" "$TOOL"

summary
