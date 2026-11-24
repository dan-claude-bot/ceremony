#!/usr/bin/env bash
set -euo pipefail

# runner-lanes.sh — check the two runner-lane rules over a consumer's
# workflow files (#640, handbook 0004 decision ask 4, 0012 lanes):
#
#   1. untrusted-lane jobs declare read-only permissions (job level, or
#      workflow level when the job sets none), reference no secrets.* but
#      GITHUB_TOKEN, and set no environment:;
#   2. deploy-lane jobs have no uses: steps, no container:/services:, and
#      no docker invocation in run:.
#
# A job's lane comes from its runs-on (or, for a reusable-workflow caller,
# its runner input): a literal label matching a lane's label globs, or a
# vars.<NAME> reference matching a lane's variable globs. yq normalizes the
# YAML (anchors exploded); the rules live in runner-lanes.jq, beside this.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflows_dir="${WORKFLOWS_DIR:-.github/workflows}"

log() { printf 'runner-lanes: %s\n' "$*"; }

for tool in yq jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log "FAIL: $tool is not on PATH; the guard cannot read workflow files without it"
    exit 1
  fi
done

if [ ! -d "$workflows_dir" ]; then
  log "no $workflows_dir — nothing to check"
  exit 0
fi

# A comma-separated input → a JSON list of trimmed, non-empty globs.
globs() { jq -cn --arg s "$1" '$s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))'; }

cfg="$(jq -cn \
  --argjson ul "$(globs "${UNTRUSTED_LABELS-untrusted,pr-runner,gig-untrusted,gig-untrusted-*}")" \
  --argjson uv "$(globs "${UNTRUSTED_VARS-LANE_UNTRUSTED,LANE_UNTRUSTED_*}")" \
  --argjson dl "$(globs "${DEPLOY_LABELS-deploy-runner,gig-trusted-deploy}")" \
  --argjson dv "$(globs "${DEPLOY_VARS-LANE_TRUSTED_DEPLOY}")" \
  --argjson inputs "$(globs "${RUNNER_INPUTS-runner}")" \
  '{ul: $ul, uv: $uv, dl: $dl, dv: $dv, inputs: $inputs}')"
if [ "$(jq -r '.inputs | length' <<<"$cfg")" -eq 0 ]; then
  cfg="$(jq -c '.inputs = ["runner"]' <<<"$cfg")"
fi

# to_json <file> — the file as JSON, anchors resolved; non-zero on a parse error.
to_json() { yq -o=json 'explode(.)' "$1" 2>&1; }

# scan <json> <mode> [lane input] — the jq records for one file.
scan() {
  jq -r --argjson cfg "$cfg" --arg mode "$2" --arg lane "${3:-}" --arg input "${4:-}" \
    -f "$here/runner-lanes.jq" <<<"$1"
}

shopt -s nullglob
failures=0
guarded=0
files=("$workflows_dir"/*.yml "$workflows_dir"/*.yaml)

report() { # <file> <records> [prefix] — print records, count, follow callers
  local file="$1" records="$2" prefix="${3:-}" kind job a b c
  while IFS=$'\t' read -r kind job a b c; do
    case "$kind" in
      L)
        guarded=$((guarded + 1))
        log "$file: job $prefix$job is on the $a lane (via $b)"
        ;;
      F)
        failures=$((failures + 1))
        log "FAIL $file: job $prefix$job ($a lane) $b"
        ;;
      N) log "NOTE $file: job $prefix$job $a" ;;
      C) follow "$file" "$prefix$job" "$a" "$b" "$c" ;;
    esac
  done <<<"$records"
}

follow() { # <file> <job> <lane> <callee> <input>
  local file="$1" job="$2" lane="$3" callee="$4" input="$5" path json
  path="${callee#./}"
  path="${path%%@*}"
  if [ ! -f "$path" ]; then
    failures=$((failures + 1))
    log "FAIL $file: job $job ($lane lane) calls $callee, which is not in this tree to read"
    return
  fi
  if ! json="$(to_json "$path")"; then
    failures=$((failures + 1))
    log "FAIL $file: job $job ($lane lane) calls $path, which does not parse: $json"
    return
  fi
  local records
  records="$(scan "$json" callee "$lane" "$input")"
  report "$path" "$records" "$job → "
}

for file in "${files[@]}"; do
  if ! json="$(to_json "$file")"; then
    failures=$((failures + 1))
    log "FAIL $file: does not parse as YAML: $json"
    continue
  fi
  records="$(scan "$json" top)"
  report "$file" "$records"
done

log "${#files[@]} file(s), $guarded job lane(s) guarded, $failures failure(s)"
[ "$failures" -eq 0 ]
