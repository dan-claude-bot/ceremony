#!/usr/bin/env bash
# Contract tests for actions/runner-lanes (#640). Constructed fixture trees —
# a dir holding a workflows directory — as the guards beside it. Each rule
# has a passing and a failing workflow. set -u, not -e: failing commands are
# behavior for the harness to inspect. The guard needs yq; ci.yml sets
# CEREMONY_REQUIRE_YQ so a missing yq is a failure there, not a skip.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/harness.sh
. "$ROOT/test/harness.sh"

SCRIPT="$ROOT/actions/runner-lanes/runner-lanes.sh"

if ! command -v yq >/dev/null 2>&1; then
  if [ -n "${CEREMONY_REQUIRE_YQ:-}" ]; then
    echo "FAIL: CEREMONY_REQUIRE_YQ is set but yq is missing — the runner-lanes cases did not run"
    exit 1
  fi
  echo "skip: yq not installed — runner-lanes cases not run"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

in_tree() {
  local dir="$1"
  shift
  (cd "$TMP/$dir" && bash "$SCRIPT" "$@")
}
wf() {
  mkdir -p "$TMP/$1/.github/workflows"
  cat >"$TMP/$1/.github/workflows/$2"
}

# --- rule 1: untrusted lane ---------------------------------------------------

wf u-pass ci.yml <<'YAML'
on: pull_request
permissions:
  contents: read
jobs:
  test:
    runs-on: [self-hosted, untrusted]
    steps:
      - uses: actions/checkout@v4
      - run: echo "no secrets here"; npm test
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          X: ${{ inputs.secrets }}
  lint:
    runs-on: ${{ vars.LANE_UNTRUSTED }}
    permissions: read-all
    steps:
      - run: echo lint
  big:
    runs-on: ${{ vars.lane_untrusted_big }}
    permissions: {}
    steps:
      - run: echo big
  gig:
    runs-on: gig-untrusted
    steps:
      - run: echo gig
YAML
check "untrusted: read-only, GITHUB_TOKEN only, passes" 0 "4 job lane(s) guarded, 0 failure(s)" in_tree u-pass
check "untrusted: lane read from a variable" 0 "job lint is on the untrusted lane (via vars.LANE_UNTRUSTED)" in_tree u-pass
check "untrusted: a flavor variable, any case" 0 "job big is on the untrusted lane (via vars.lane_untrusted_big)" in_tree u-pass

wf u-noperm ci.yml <<'YAML'
on: pull_request
jobs:
  test:
    runs-on: [self-hosted, untrusted]
    steps:
      - run: echo test
YAML
check "untrusted: no permissions anywhere fails" 1 "declares no permissions" in_tree u-noperm

wf u-write ci.yml <<'YAML'
on: pull_request
permissions:
  contents: read
jobs:
  test:
    runs-on: pr-runner
    permissions:
      contents: read
      issues: write
    steps:
      - run: echo test
YAML
check "untrusted: a job-level write fails" 1 'permissions are not read-only: {"contents":"read","issues":"write"}' in_tree u-write

wf u-override ci.yml <<'YAML'
on: pull_request
permissions: write-all
jobs:
  test:
    runs-on: [self-hosted, untrusted]
    permissions:
      contents: read
    steps:
      - run: echo test
  other:
    runs-on: [self-hosted, untrusted]
    steps:
      - run: echo test
YAML
check "untrusted: workflow write-all reaches a job that sets none" 1 "job other (untrusted lane) permissions are not read-only" in_tree u-override
check_absent "untrusted: a job's own read-only block overrides the workflow" 1 "job test (untrusted lane)" in_tree u-override

wf u-secrets ci.yml <<'YAML'
on: pull_request
permissions:
  contents: read
env:
  TOP: ${{ secrets.TOP_LEVEL }}
jobs:
  test:
    runs-on: [self-hosted, untrusted]
    steps:
      - run: echo "$A $B $C"
        env:
          A: ${{ secrets.NPM_TOKEN }}
          B: ${{ secrets['BRACKET'] }}
          C: ${{ toJSON(secrets) }}
YAML
check "untrusted: a named secret fails" 1 "references secrets.NPM_TOKEN" in_tree u-secrets
check "untrusted: a bracketed secret fails" 1 "references secrets.BRACKET" in_tree u-secrets
check "untrusted: the whole secrets context fails" 1 "references secrets (the whole context)" in_tree u-secrets
check "untrusted: a workflow-level env secret reaches the job" 1 "references secrets.TOP_LEVEL" in_tree u-secrets

wf u-env ci.yml <<'YAML'
on: pull_request
permissions: read-all
jobs:
  test:
    runs-on: [self-hosted, untrusted]
    environment: staging
    steps:
      - run: echo test
YAML
check "untrusted: environment: fails" 1 "sets environment: staging" in_tree u-env

# --- rule 2: deploy lane ------------------------------------------------------

wf d-pass deploy.yml <<'YAML'
on:
  push:
    branches: [main]
permissions: {}
jobs:
  trigger:
    runs-on: [self-hosted, deploy-runner]
    environment: production
    steps:
      - run: |
          curl -fsS -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
            -H "Authorization: Bearer ${{ secrets.DEPLOY_TOKEN }}" https://deploy.example/api
  gig:
    runs-on: ${{ vars.LANE_TRUSTED_DEPLOY }}
    steps:
      - run: curl -fsS https://deploy.example/api
YAML
check "deploy: bare curl passes" 0 "2 job lane(s) guarded, 0 failure(s)" in_tree d-pass
check "deploy: lane read from its variable" 0 "job gig is on the deploy lane (via vars.LANE_TRUSTED_DEPLOY)" in_tree d-pass

wf d-fail deploy.yml <<'YAML'
on: push
jobs:
  trigger:
    runs-on: [self-hosted, deploy-runner]
    container: node:22
    services:
      db:
        image: postgres
    steps:
      - uses: actions/checkout@v4
      - name: build
        run: docker build .
      - name: up
        run: docker-compose up -d
YAML
check "deploy: actions/checkout fails" 1 "has a uses: step (actions/checkout@v4)" in_tree d-fail
check "deploy: container: fails" 1 "sets container:" in_tree d-fail
check "deploy: services: fails" 1 "sets services:" in_tree d-fail
check "deploy: docker in run: fails" 1 "invokes a container tool (step build)" in_tree d-fail
check "deploy: docker-compose in run: fails" 1 "invokes a container tool (step up)" in_tree d-fail

# --- reusable-workflow callers ------------------------------------------------

wf c-untrusted callers.yml <<'YAML'
on: pull_request
jobs:
  labels:
    uses: heavy-duty/ceremony/.github/workflows/labels.yml@0.7.12
    secrets: inherit
    with:
      runner: '["self-hosted","untrusted"]'
YAML
check "caller: runner input classifies the lane" 1 'job labels is on the untrusted lane (via label untrusted)' in_tree c-untrusted
check "caller: untrusted with no permissions fails" 1 "declares no permissions" in_tree c-untrusted
check "caller: secrets: inherit fails" 1 "passes secrets: inherit" in_tree c-untrusted

wf c-deploy-remote deploy.yml <<'YAML'
on: push
jobs:
  deploy:
    uses: example/repo/.github/workflows/deploy.yml@v1
    with:
      runner: ${{ vars.LANE_TRUSTED_DEPLOY }}
YAML
check "caller: deploy lane to a remote callee fails" 1 "calls a remote reusable workflow (example/repo/.github/workflows/deploy.yml@v1)" in_tree c-deploy-remote

wf c-deploy-local deploy.yml <<'YAML'
on: push
jobs:
  deploy:
    uses: ./.github/workflows/callee.yml
    with:
      runner: '["self-hosted","deploy-runner"]'
YAML
wf c-deploy-local callee.yml <<'YAML'
on:
  workflow_call:
    inputs:
      runner: {type: string}
jobs:
  go:
    runs-on: ${{ fromJSON(inputs.runner) }}
    steps:
      - run: curl -fsS https://deploy.example/api
YAML
check "caller: a clean local callee on the deploy lane passes" 0 "job deploy → go is on the deploy lane (via inputs.runner from its caller)" in_tree c-deploy-local
check "callee alone: its input-routed lane is a NOTE, never silence" 0 "NOTE .github/workflows/callee.yml: job go lane unresolved" in_tree c-deploy-local

wf c-deploy-dirty deploy.yml <<'YAML'
on: push
jobs:
  deploy:
    uses: ./.github/workflows/callee.yml
    with:
      runner: deploy-runner
YAML
wf c-deploy-dirty callee.yml <<'YAML'
on: workflow_call
jobs:
  go:
    runs-on: ${{ inputs.runner }}
    steps:
      - uses: actions/checkout@v4
YAML
check "caller: a local callee's uses: step fails on the deploy lane" 1 "FAIL .github/workflows/callee.yml: job deploy → go (deploy lane) has a uses: step" in_tree c-deploy-dirty

# --- classification edges -----------------------------------------------------

wf edges ci.yml <<'YAML'
on: pull_request
permissions: read-all
jobs:
  trusted:
    runs-on: ${{ vars.LANE_TRUSTED }}
    steps:
      - uses: actions/checkout@v4
  matrix:
    runs-on: ${{ matrix.os }}
    steps:
      - run: echo m
  fallback:
    runs-on: ${{ vars.SOMETHING || 'untrusted' }}
    environment: x
    steps:
      - run: echo f
  anchored:
    runs-on: &deploy [self-hosted, deploy-runner]
    steps:
      - run: echo a
  aliased:
    runs-on: *deploy
    steps:
      - uses: actions/checkout@v4
  grouped:
    runs-on:
      group: org-runners
      labels: [gig-trusted-deploy]
    steps:
      - run: echo g
YAML
check_absent "edges: the trusted lane is not guarded" 1 "job trusted is on" in_tree edges
check "edges: an unresolvable expression is a NOTE" 1 "NOTE .github/workflows/ci.yml: job matrix lane unresolved: \${{ matrix.os }}" in_tree edges
check "edges: a literal fallback inside an expression classifies" 1 "job fallback (untrusted lane) sets environment: x" in_tree edges
check "edges: an alias is its anchor's value" 1 "job aliased (deploy lane) has a uses: step" in_tree edges
check "edges: a {group, labels} runs-on reads its labels" 1 "job grouped is on the deploy lane (via label gig-trusted-deploy)" in_tree edges

# --- inputs -------------------------------------------------------------------

wf custom ci.yml <<'YAML'
on: pull_request
jobs:
  test:
    runs-on: [self-hosted, sandbox]
    steps:
      - run: echo t
  ship:
    runs-on: ${{ vars.MY_DEPLOY }}
    steps:
      - uses: actions/checkout@v4
YAML
check "inputs: default sets see nothing here" 0 "0 job lane(s) guarded" in_tree custom
check "inputs: custom untrusted labels" 1 "job test (untrusted lane) declares no permissions" \
  env UNTRUSTED_LABELS='sandbox' DEPLOY_VARS='MY_DEPLOY' bash -c "cd '$TMP/custom' && bash '$SCRIPT'"
check "inputs: custom deploy variables" 1 "job ship (deploy lane) has a uses: step" \
  env UNTRUSTED_LABELS='sandbox' DEPLOY_VARS='MY_DEPLOY' bash -c "cd '$TMP/custom' && bash '$SCRIPT'"

mkdir -p "$TMP/empty"
check "a missing workflows dir passes" 0 "nothing to check" in_tree empty

wf broken ci.yml <<'YAML'
jobs: [unclosed
YAML
check "a file that does not parse fails" 1 "does not parse as YAML" in_tree broken

# --- round 1 findings ---------------------------------------------------------

wf r1 ci.yml <<'YAML'
on: pull_request
jobs:
  multiline:
    runs-on: >-
      ${{
      vars.LANE_UNTRUSTED }}
    steps:
      - run: echo
  hidden:
    runs-on: gig-untrusted
    permissions: read-all
    steps:
      - run: "echo ${{\n secrets.Y }}"
  shell:
    runs-on: deploy-runner
    steps:
      - shell: docker run --rm alpine sh {0}
        run: echo hi
  flavor:
    runs-on: ${{ vars.LANE_TRUSTED_DEPLOY_ARM }}
    steps:
      - uses: actions/checkout@v4
  other:
    runs-on: ${{ fromJSON(vars.RUNNERS).pr }}
    steps:
      - run: echo
  matrix:
    strategy:
      matrix:
        r: [gig-untrusted]
    runs-on: ${{ matrix.r }}
    steps:
      - run: echo
YAML
check "r1: a multi-line expression still classifies" 1 "job multiline (untrusted lane) declares no permissions" in_tree r1
check "r1: a multi-line secret reference is found" 1 "job hidden (untrusted lane) references secrets.Y" in_tree r1
check "r1: docker as a step shell fails" 1 "job shell (deploy lane) invokes a container tool" in_tree r1
check "r1: a deploy flavor variable is the deploy lane" 1 "job flavor (deploy lane) has a uses: step" in_tree r1
check "r1: a non-lane variable is a NOTE" 1 "NOTE .github/workflows/ci.yml: job other lane unresolved" in_tree r1
check "r1: a matrix key resolves to its literal labels" 1 "job matrix (untrusted lane) declares no permissions" in_tree r1

wf r1-shape ci.yml <<'YAML'
on: push
jobs:
  x:
    runs-on: deploy-runner
    steps: ["oops", {run: ls}]
YAML
wf r1-shape z.yml <<'YAML'
on: push
jobs:
  y:
    runs-on: deploy-runner
    steps:
      - uses: actions/checkout@v4
YAML
check "r1: a malformed step does not stop later files" 1 "job y (deploy lane) has a uses: step" in_tree r1-shape

summary
