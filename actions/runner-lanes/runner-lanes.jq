# runner-lanes.jq — the pure half of actions/runner-lanes (#640). Input: one
# workflow file, normalized to JSON by `yq 'explode(.)'` (anchors resolved).
# Output: tab-separated records the shell prints, one per line:
#   L <job> <lane> <via>            the job runs on a guarded lane
#   F <job> <lane> <message>        the job breaks that lane's rule
#   N <job> <message>               the guard could not resolve this job's lane
#   C <job> <lane> <callee> <input> a reusable-workflow caller with a local
#                                   callee the shell follows in callee mode
# Arguments: $cfg {ul, uv, dl, dv: [glob], inputs: [name]}, $mode ("top" or
# "callee"), $lane and $input (callee mode only: the caller's lane and the
# input name the runner arrives through).

def globre: "^" + (gsub("(?<c>[.+?^$(){}|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*")) + "$";
def matchany($globs): . as $s | any($globs[]; . as $g | $s | test($g | globre; "i"));

# Every string a runs-on (or runner input) value names: a scalar, a list, or
# a {group, labels} mapping.
def strs:
  if type == "string" then [.]
  elif type == "array" then [.[] | strs[]]
  elif type == "object" then [(.labels // empty | strs[]), (.group // empty | strs[])]
  elif type == "null" then []
  else [tostring] end;

# A string holding a JSON list ('["self-hosted","trusted"]', ceremony's
# runner input shape) names each of its elements.
def expand:
  if test("^\\s*\\[") then (try (fromjson | if type == "array" then map(tostring) else [tostring] end) catch [.])
  else [.] end;

# An expression runs to the first `}}` outside a '…' literal, so a literal
# holding `}}` (format('}}', …)) does not end it early.
def exprs: [match("\\$\\{\\{((?:[^'}]|'[^']*'|\\}(?!\\}))*)\\}\\}"; "g") | .captures[0].string];
def varsin:
  [match("(?:^|[^.A-Za-z0-9_])vars\\s*(?:\\.\\s*([A-Za-z_][A-Za-z0-9_]*)|\\[\\s*['\"]([^'\"]+)['\"]\\s*\\])"; "gi")
   | .captures[] | select(.string != null) | .string];
def literals: [match("'([^']*)'"; "g") | .captures[0].string];

def label_lanes($cfg; $how):
  . as $s
  | (if matchany($cfg.ul) then {lane: "untrusted", via: "\($how) \($s)"} else empty end),
    (if matchany($cfg.dl) then {lane: "deploy", via: "\($how) \($s)"} else empty end);

# [strings] → [{lane, via}], plus unresolved expression texts.
def classify($cfg):
  [ .[] | expand[] | . as $s
    | if test("\\$\\{\\{") then
        ( exprs[] as $e
          | ( $e | varsin[] as $v
              | (if ($v | matchany($cfg.uv)) then {lane: "untrusted", via: "vars.\($v)"} else empty end),
                (if ($v | matchany($cfg.dv)) then {lane: "deploy", via: "vars.\($v)"} else empty end) ),
            ( $e | literals[] | expand[] | label_lanes($cfg; "literal") ) )
      else label_lanes($cfg; "label") end ]
  | unique_by(.lane + .via);

def unresolved($cfg):
  [ .[] | expand[] | select(test("\\$\\{\\{")) | exprs[] | select(([ "${{" + . + "}}" ] | classify($cfg) | length) == 0) | gsub("^\\s+|\\s+$"; "") ];
# matrix.<key> in runs-on → the literal values strategy.matrix and its include give that key.
def matrix_values($job):
  [ match("(?:^|[^.A-Za-z0-9_])matrix\\s*\\.\\s*([A-Za-z0-9_-]+)"; "g") | .captures[0].string as $k
    | ($job.strategy.matrix // {}) | if type == "object" then ((.[$k] // empty), ((.include // []) | if type == "array" then .[] | objects | .[$k] // empty else empty end)) else empty end
    | strs[] ];

def inre($input): ($input | globre | ltrimstr("^") | rtrimstr("$")) as $n
  | "(?:^|[^.A-Za-z0-9_])inputs\\s*(?:\\.\\s*" + $n + "|\\[\\s*['\"]" + $n + "['\"]\\s*\\])(?![A-Za-z0-9_-])";
def runner_vals($job; $cfg): [ ($job.with // {}) | if type == "object" then to_entries[] else empty end | select(.key as $k | $cfg.inputs | index($k)) | .value | strs[] ];
def all_with_vals($job): [ ($job.with // {}) | if type == "object" then to_entries[] else empty end | .value | strs[] ];

def readonly:
  . == "read-all" or . == {} or (type == "object" and all(.[]; . == "read" or . == "none"));

# Secrets named anywhere a job's expressions reach: every ${{ }} in a string
# value, and an `if:` value whole (it is an expression without the braces).
def secret_refs:
  [ paths(strings) as $p | getpath($p) as $v
    | (if ($p[-1] == "if") then [$v] else ($v | exprs) end)[]
    | match("(?:^|[^.A-Za-z0-9_])secrets\\b(\\s*\\.\\s*([A-Za-z0-9_-]+)|\\s*\\[\\s*['\"]([^'\"]*)['\"]\\s*\\])?"; "gi")
    | ((.captures[1].string // .captures[2].string) // null) as $name
    | if $name == null then "secrets (the whole context)"
      elif ($name | ascii_upcase) == "GITHUB_TOKEN" then empty
      else "secrets.\($name)" end ]
  | unique;

# What a deploy-lane step may not do: run a container tool, or fetch code.
def forbidden:
  if type != "string" then empty else
    [ match("(?:^|[^A-Za-z0-9_.-])(docker-compose|dockerd|docker|podman|nerdctl|buildah|containerd|ctr|crictl|skopeo|kubectl|incus|lxc)(?![A-Za-z0-9_])"; "g") | .captures[0].string ]
    + [ match("(?:^|[^A-Za-z0-9_.-])(git\\s+(?:clone|fetch|pull))(?![A-Za-z0-9_-])"; "g") | .captures[0].string | gsub("\\s+"; " ") ]
    + [ match("(?:^|[^A-Za-z0-9_.-])((?:curl|wget)(?![A-Za-z0-9_-])[^|\\n]*\\|\\s*(?:sudo\\s+)?(?:ba)?sh)(?![A-Za-z0-9_-])"; "g") | .captures[0].string | (if test("^curl") then "curl … | sh" else "wget … | sh" end) ]
    | unique | .[] end;
def docker_steps($wf):
  [ ((.steps // []) | if type == "array" then to_entries[] else empty end | select(.value | type == "object")
     | "step \(.key + 1)\(if (.value.name // .value.id) then " (\(.value.name // .value.id))" else "" end)" as $where | .value
     | ((.run // null), (.shell // null)) | forbidden | "\(.) in \($where)"),
    ((.defaults.run.shell // null) | forbidden | "\(.) in job defaults.run.shell"),
    (($wf.defaults.run.shell // null) | forbidden | "\(.) in workflow defaults.run.shell") ];
def objsteps: (.steps // []) | if type == "array" then .[] | select(type == "object") else empty end;

. as $wf
| ($wf.jobs // {}) as $jobs
| if ($jobs | type) != "object" then empty else
  $jobs | to_entries[] | .key as $id | .value as $job
  | if ($job | type) != "object" then empty else
    ([$job["runs-on"] | strs[] | select(test(inre($input); "i"))] | length > 0) as $inherits
    | (runner_vals($job; $cfg)) as $rv
    | (if ($job | has("uses")) and ($rv | length) == 0 then all_with_vals($job) else $rv end) as $src
    | ( if $mode == "callee" then
          # Only jobs routed through the caller's runner input inherit its lane.
          if $inherits then [{lane: $lane, via: "inputs.\($input) from its caller"}] else [] end
        elif ($job | has("uses")) then $src | classify($cfg)
        else ($job["runs-on"] | strs | (. + [.[] | matrix_values($job)[]]) | classify($cfg)) end ) as $lanes
    | ( if $mode == "callee" then []
        elif ($job | has("uses")) then (if ($lanes | length) > 0 then [] else $src | unresolved($cfg) end)
        else (($job["runs-on"] | strs) as $ro | if ($ro + [$ro[] | matrix_values($job)[]] | classify($cfg) | length) > 0 then [] else ($ro | unresolved($cfg)) end) end ) as $unres
    | [ if $mode == "top" and ($job | has("runs-on") | not) and ($job | has("uses") | not) then
          ["F", $id, "unknown", "has neither runs-on: nor uses:, so no lane can be read (an inline merge key the guard cannot resolve reads as an empty job)"]
        elif $mode == "top" and ($job | has("uses")) and ($rv | length) == 0 and ($lanes | length) == 0 then
          ["N", $id, "calls \($job.uses) with no runner input (\($cfg.inputs | join(", "))) and no lane in its with: values; its lane is not judged"]
        elif $mode == "callee" and ($inherits | not) then
          ( ($job["runs-on"] | strs) as $ro
            | if ($ro | map(test("\\$\\{\\{")) | any) and (($ro + [$ro[] | matrix_values($job)[]]) | classify($cfg) | length) == 0 then
                ["F", $id, $lane, "does not take its caller's \($lane) lane through inputs.\($input), and its own runs-on (\($ro | join(", "))) names no lane the guard can read"]
              else ["N", $id, "runs on \($ro | join(", ")), not its caller's \($lane) lane; judged on its own"] end )
        else empty end ] as $shape
    | ($job | has("uses")) as $caller
    | ($job | has("uses")) as $caller
    | (($job.with // {}) | if type == "object" then keys_unsorted else [] end | map(select(. as $k | $cfg.inputs | index($k))) | .[0] // $cfg.inputs[0]) as $inkey
    | (($job.uses // "") | tostring) as $callee
    | ( $shape[],
        ($unres[] | ["N", $id, "lane unresolved: ${{ \(.) }} names no lane variable or label the guard can read"]),
        ( $lanes[] | ["L", $id, .lane, .via] ),
        ( $lanes | map(.lane) | unique[] as $l
          | if $l == "untrusted" then
              ( if $mode == "callee" then empty
                else ( (if $job | has("permissions") then $job.permissions else $wf.permissions end) as $perm
                       | if $perm == null then ["F", $id, $l, "declares no permissions: (job or workflow level), so the token is the repository default, which may write"]
                         elif ($perm | readonly) | not then ["F", $id, $l, "permissions are not read-only: \($perm | tojson)"]
                         else empty end ) end ),
              ( if ($job.secrets // null) == "inherit" then ["F", $id, $l, "passes secrets: inherit to its callee"] else empty end ),
              ( ([$job, ($wf.env // {})] | secret_refs)[] | ["F", $id, $l, "references \(.)"] ),
              ( if $job | has("environment") then ["F", $id, $l, "sets environment: \($job.environment | if type == "string" then . else tojson end)"] else empty end ),
              ( if $caller and ($callee | startswith("./")) then ["C", $id, $l, $callee, $inkey] else empty end )
            else
              ( (($job | objsteps) | select(has("uses")) | ["F", $id, $l, "has a uses: step (\(.uses)); the deploy lane runs bare run: steps only"]),
                (if $job | has("container") then ["F", $id, $l, "sets container:"] else empty end),
                (if $job | has("services") then ["F", $id, $l, "sets services:"] else empty end),
                (($job | docker_steps($wf))[] | ["F", $id, $l, "runs \(.); the deploy lane runs no container tool and fetches no code"]),
                ( if $caller then
                    if ($callee | startswith("./")) then ["C", $id, $l, $callee, $inkey]
                    else ["F", $id, $l, "calls a remote reusable workflow (\($callee)) the guard cannot read; the deploy lane admits only steps it can see"] end
                  else empty end ) )
            end ) )
    | @tsv
  end
end
