# shellcheck shell=sh disable=SC2016 # jq and GraphQL use literal $ in single quotes
# The executable spec for gh read. Sourced by test/run.sh.
#
# Each case is the argument list an agent would pass after `gh read`, in normal
# shell quoting:
#
#   allow <args>              REST read: gh gets exactly `api --method GET <args>`
#   allow_graphql <args>      GraphQL query: gh gets exactly `api <args>`
#   deny <reason> <args>      refused: exit 2, gh never runs, one stderr line containing <reason>
#   passes_exit_code <n> <args>   gh's exit code comes back unchanged
#   shows_help <args>         usage on stdout, exit 0
#   with_env 'K=v' <case>     run one case with extra environment variables
#
# Every refusal names its reason with one of these phrases:
#
#   only makes GET requests       a method other than GET
#   sends a request body          --input
#   reads a local file            -F/--field with an @ value
#   only Accept and X-GitHub-Api-Version headers
#   only talks to github.com      --hostname, a full URL endpoint, GH_HOST
#   prints request headers        --verbose
#   escape sequences              --allow-escape-sequences
#   reads environment variables   `env` or `$ENV` in --jq
#   GraphQL mutation              `mutation` anywhere in the arguments of a call
#   GraphQL subscription          `subscription` likewise; both apply when the endpoint contains "graphql"
#   separate arguments            attached short values and combined short flags (-XPOST, -iX)
#   takes no value                a boolean flag given a value (--paginate=true)
#   needs a value                 a value flag with nothing after it
#   ends flag parsing             --
#   unknown flag                  anything else starting with -
#   expected one endpoint         zero or several positional arguments

# --- Real-world REST reads ---------------------------------------------------
# Shapes taken from agents' real gh api usage, with generic names.

allow repos/octo-org/octo-repo/releases/latest --jq '{tag: .tag_name, date: .published_at, body: .body}'
allow repos/octo-org/octo-repo/pulls/26 --jq '{title, merged_at, body}'
allow repos/octo-org/octo-repo/issues/164 --jq '{title, state, body}'
allow repos/octo-org/octo-repo/contents/src/components/manifest.json --jq '.content' -H "Accept: application/vnd.github.object+json"
allow repos/octo-org/octo-repo/contents/lib/api.py -H "Accept: application/vnd.github.raw"
allow repos/octo-org/octo-repo/contents/pyproject.toml -H "Accept: application/vnd.github.raw+json"
allow "repos/octo-org/octo-repo/code-scanning/alerts?ref=refs/pull/350/head&state=open" --jq '.[] | "\(.number) \(.rule.id) \(.most_recent_instance.location.path)"'
allow repos/octo-org/octo-repo/pulls/391/comments --paginate --jq '.[] | select(.user.login | test("review-bot")) | "=== \(.id) \(.path):\(.line // .original_line) (reply_to=\(.in_reply_to_id // "none"))\n\(.body)\n"'
allow repos/octo-org/octo-repo/pulls/391/reviews/1000000001/comments --paginate --jq '.[] | "=== \(.id) \(.path):\(.line // .original_line)\n\(.body)\n"'
allow repos/octo-org/octo-repo/pulls/413/comments --paginate --jq '.[] | "=== \(.user.login) \(.path)\n\(.body | gsub("<!--[^>]*-->"; "") | .[0:2500])\n"'
allow repos/octo-org/octo-repo/pulls/401/reviews --jq '.[] | "\(.submitted_at) \(.state) \(.body | split("<details>")[0] | .[0:600])"'
allow repos/octo-org/octo-repo/pulls/357/reviews --jq '.[-2:] | .[] | {id, submitted_at, body: .body[0:4000]}'
allow repos/octo-org/octo-repo/issues/399/comments --paginate --jq '.[] | select(.user.login | startswith("review-bot")) | {id, created: .created_at, updated: .updated_at}'
allow repos/octo-org/octo-repo/issues/comments/1000000002 --jq .body
allow repos/octo-org/octo-repo/issues/362/comments --jq '.[] | select(.user.login=="review-bot[bot]") | .body | capture("(?<x>Actionable comments posted: [0-9]+)").x'
allow repos/octo-org/octo-repo/issues/390/timeline --paginate --jq '.[] | select(.event=="cross-referenced" or .event=="referenced") | {event, commit: .commit_id}'
allow 'repos/octo-org/octo-repo/actions/caches?per_page=100' --jq '.total_count, (.actions_caches[] | "\(.ref)\t\(.size_in_bytes/1048576|floor)MB\t\(.key)")'
allow repos/octo-org/octo-repo/actions/runs/2000000001/jobs --jq '.jobs[] | "\(.name): \(.status) \(.conclusion)"'
allow repos/octo-org/octo-repo/actions/runs/2000000002/attempts/2/jobs --jq '.jobs[] | {name, conclusion, steps: [.steps[] | select(.conclusion != "success") | {name, conclusion}]}'
allow repos/octo-org/octo-repo/actions/jobs/3000000001/logs
allow repos/octo-org/octo-repo/actions/jobs/3000000002 --jq '.conclusion, (.steps[] | "\(.number) \(.name): \(.conclusion)")'
allow "repos/octo-org/octo-repo/contents/crates/runtime/Cargo.toml?ref=dev" -H "Accept: application/vnd.github.raw" --jq .
allow repos/octo-org/octo-repo/pulls/1420/files --jq '.[] | select(.filename=="src/platform/util.rs") | .patch'
allow repos/octo-org/octo-repo/rulesets --jq '.[] | {name, target, enforcement}'
allow repos/octo-org/octo-repo/branches/main/protection
allow repos/octo-org/octo-repo --jq "{pushed_at,updated_at,stars:.stargazers_count,archived,open_issues:.open_issues_count}"
allow "repos/octo-org/octo-repo/commits?since=2026-03-01T00:00:00Z&per_page=40" --jq ".[] | {sha:.sha[0:7],date:.commit.author.date,msg:(.commit.message|split(\"\n\")[0])}"
allow repos/octo-org/octo-repo/contents/src/main/Discovery.java --jq ".content | @base64d"
allow "repos/octo-org/octo-repo/git/trees/main?recursive=1" --jq '[.tree[] | select(.type=="blob") | .path] | map(select(startswith("Sources/"))) | .[]'
allow 'repos/octo-org/octo-repo/git/trees/HEAD' --jq '.tree[].path'
allow "repos/octo-org/octo-repo/contents/docs/Release%20your%20plugin.md?ref=2024-01-01" --jq .name
allow "repos/octo-org/octo-repo/branches" --paginate --jq '.[].name'
allow repos/octo-org/octo-repo/tags --jq '.[0:5][].name'
allow repos/octo-org/octo-repo/releases/tags/v7.0.0 --jq .body
allow repos/octo-org/octo-repo/dependabot/alerts --jq '.[] | select(.state=="open") | "\(.number)\t\(.security_advisory.severity)\t\(.dependency.package.name)"'
allow repos/octo-org/octo-repo/attestations/sha256:3f2a9c --jq '.attestations | length'
allow repos/octo-org/octo-repo/commits/08d3c94a00 --jq '.files[] | "--- " + .filename + "\n" + (.patch // "")'
allow repos/octo-org/octo-repo/contents --jq '.[] | "\(.name) \(.size)"'
allow 'repos/{owner}/{repo}/pulls/344/comments' --jq '.[] | select(.created_at > "2026-10-27T20:00:00Z") | {path, body: .body[0:300]}'
allow repos/octo-org/octo-repo/vulnerability-alerts -i --silent

# Flags after the endpoint, including an explicit GET: agents write these often.
allow -X GET search/commits -f q="repo:octo-org/octo-repo iOS" -f per_page=50 --jq '.items[] | "\(.commit.author.date[:10]) \(.sha[:8])"'
allow repos/octo-org/octo-repo/releases --jq '.[] | "\(.published_at[:10]) \(.tag_name)"' -X GET -f per_page=8
allow repos/octo-org/octo-repo/contents/CHANGELOG.md -f ref=pkg@0.3.0 -X GET --jq '.content | @base64d'
allow repos/octo-org/octo-repo/readme --jq '.content' --method GET -H "Accept: application/vnd.github.raw+json"
allow repos/octo-org/octo-repo/contents/src/read.ts --jq .content --method GET -H "Accept: application/vnd.github+json"

# A write-shaped call without a method becomes a harmless GET with `body` as a
# query parameter. The response (a list or a 404) shows nothing was posted.
allow repos/octo-org/octo-repo/pulls/64/comments/1000000003/replies -f body='Fixed in abc1234: values are now quoted.'

# --- Real-world GraphQL queries ----------------------------------------------

allow_graphql graphql --paginate -f query='query($endCursor: String) { repository(owner: "octo-org", name: "octo-repo") { issues(first: 100, after: $endCursor) { pageInfo { hasNextPage endCursor } nodes { author { login } } } } }' --jq '.data.repository.issues.nodes[].author.login'
allow_graphql graphql -f query='query { a: repository(owner:"octo-org",name:"one"){...r} b: repository(owner:"octo-org",name:"two"){...r} } fragment r on Repository { nameWithOwner isArchived stargazerCount pushedAt }'
allow_graphql graphql -f query='query { repository(owner: "octo-org", name: "octo-repo") { pullRequest(number: 385) { reviewThreads(first: 20) { nodes { id isResolved path comments(first: 1) { nodes { databaseId } } } } } } }' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | "\(.id) \(.isResolved)"'
allow_graphql graphql -f query='query { repository(owner:"octo-org", name:"octo-repo") { pullRequest(number:66) { reviewThreads(first:50) { nodes { id isResolved } } } } }' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not) | .id'
allow_graphql graphql -F owner='{owner}' -F name='{repo}' -f query='
  query($name: String!, $owner: String!) {
    repository(owner: $owner, name: $name) {
      releases(last: 3) {
        nodes { tagName }
      }
    }
  }
'
allow_graphql graphql --paginate --slurp -f query='
  query($endCursor: String) {
    viewer {
      repositories(first: 100, after: $endCursor) {
        nodes { isFork }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
'

# --- Real-world writes -------------------------------------------------------

deny 'only makes GET requests' -X PATCH repos/octo-org/octo-repo/code-scanning/alerts/18 -f state=dismissed -f dismissed_reason="false positive" -f dismissed_comment="Not reachable from user input."
deny 'only makes GET requests' -X PATCH repos/octo-org/octo-repo -F delete_branch_on_merge=true --jq .delete_branch_on_merge
deny 'only makes GET requests' -X PATCH repos/octo-org/octo-repo/issues/comments/1000000002 -F body=@/tmp/comment.md --jq .html_url
deny 'only makes GET requests' -X PATCH repos/octo-org/octo-repo/dependabot/alerts/1 -f state=dismissed -f dismissed_reason=tolerable_risk -f "dismissed_comment=No fix upstream yet."
deny 'reads a local file' repos/octo-org/octo-repo/pulls/386/comments/1000000004/replies -F body=@/tmp/reply.md --jq .html_url
deny 'GraphQL mutation' graphql -f query='mutation { a: resolveReviewThread(input: {threadId: "PRRT_one"}) { thread { isResolved } } b: resolveReviewThread(input: {threadId: "PRRT_two"}) { thread { isResolved } } }' --jq '[.data.a.thread.isResolved, .data.b.thread.isResolved]'

# --- Method ------------------------------------------------------------------

allow -X GET repos/octo-org/octo-repo
allow -X get repos/octo-org/octo-repo
allow --method GET repos/octo-org/octo-repo
allow --method=GET repos/octo-org/octo-repo
allow --method=Get repos/octo-org/octo-repo
deny 'only makes GET requests' -X POST repos/octo-org/octo-repo/issues -f title=hi
deny 'only makes GET requests' -X post repos/octo-org/octo-repo/issues -f title=hi
deny 'only makes GET requests' -X PUT repos/octo-org/octo-repo/subscription
deny 'only makes GET requests' -X DELETE repos/octo-org/octo-repo
deny 'only makes GET requests' -X HEAD repos/octo-org/octo-repo
deny 'only makes GET requests' --method POST repos/octo-org/octo-repo/issues
deny 'only makes GET requests' --method=POST repos/octo-org/octo-repo/issues
deny 'only makes GET requests' repos/octo-org/octo-repo/issues -f title=hi --method=PATCH
deny 'only makes GET requests' -X GET repos/octo-org/octo-repo -X POST
deny 'only makes GET requests' --method= repos/octo-org/octo-repo
deny 'separate arguments' -XPOST repos/octo-org/octo-repo/issues
deny 'separate arguments' -XGET repos/octo-org/octo-repo
deny 'separate arguments' -X=GET repos/octo-org/octo-repo
deny 'separate arguments' -iX POST repos/octo-org/octo-repo/issues
deny 'needs a value' repos/octo-org/octo-repo -X

# --- Request body and fields -------------------------------------------------

deny 'sends a request body' --input body.json repos/octo-org/octo-repo/rulesets
deny 'sends a request body' --input - repos/octo-org/octo-repo/rulesets
deny 'sends a request body' --input=body.json repos/octo-org/octo-repo/rulesets
deny 'reads a local file' gists -F 'files[myfile.txt][content]=@myfile.txt'
deny 'reads a local file' search/issues -F q=@/etc/passwd
deny 'reads a local file' search/issues -F q=@-
deny 'reads a local file' search/issues --field q=@/etc/passwd
deny 'reads a local file' search/issues --field=q=@/etc/passwd
deny 'reads a local file' search/issues -F @/etc/passwd
deny 'reads a local file' search/issues -F 'q=x=@y'
allow search/issues -F per_page=50 -F 'q={owner}'
allow search/issues -F 'q=user@example.com'
allow search/issues -f q=@octocat
allow search/issues --raw-field q=@octocat
allow search/issues --raw-field=q=@octocat
allow 'repos/octo-org/octo-repo/issues' -f 'labels[]=bug' -f 'labels[]=docs'

# --- Headers -----------------------------------------------------------------

allow repos/octo-org/octo-repo -H 'Accept: application/vnd.github.raw'
allow repos/octo-org/octo-repo -H 'accept:application/vnd.github.raw'
allow repos/octo-org/octo-repo -H 'ACCEPT: application/json'
allow repos/octo-org/octo-repo -H 'X-GitHub-Api-Version: 2022-11-28'
allow repos/octo-org/octo-repo -H 'x-github-api-version:2022-11-28'
allow repos/octo-org/octo-repo --header 'Accept: application/vnd.github.raw'
allow repos/octo-org/octo-repo '--header=Accept: application/vnd.github.raw'
allow repos/octo-org/octo-repo -H 'Accept: application/vnd.github.raw' -H 'X-GitHub-Api-Version: 2022-11-28'
deny 'only Accept and X-GitHub-Api-Version headers' repos/octo-org/octo-repo -H 'X-HTTP-Method-Override: DELETE'
deny 'only Accept and X-GitHub-Api-Version headers' repos/octo-org/octo-repo -H 'Content-Type: application/json'
deny 'only Accept and X-GitHub-Api-Version headers' repos/octo-org/octo-repo -H 'Authorization: token abc'
deny 'only Accept and X-GitHub-Api-Version headers' repos/octo-org/octo-repo -H 'Accept : application/json'
deny 'only Accept and X-GitHub-Api-Version headers' repos/octo-org/octo-repo -H ' Accept: application/json'
deny 'only Accept and X-GitHub-Api-Version headers' repos/octo-org/octo-repo -H 'Accept'
deny 'only Accept and X-GitHub-Api-Version headers' repos/octo-org/octo-repo -H 'AcceptX: y'
deny 'only Accept and X-GitHub-Api-Version headers' repos/octo-org/octo-repo -H -X
deny 'only Accept and X-GitHub-Api-Version headers' repos/octo-org/octo-repo -H "$(printf 'Accept: x\r\nX-HTTP-Method-Override: DELETE')"
deny 'only Accept and X-GitHub-Api-Version headers' repos/octo-org/octo-repo -H 'Accept: x
X-HTTP-Method-Override: DELETE'

# --- Hosts -------------------------------------------------------------------

deny 'only talks to github.com' --hostname example.com repos/octo-org/octo-repo
deny 'only talks to github.com' --hostname=github.com repos/octo-org/octo-repo
deny 'only talks to github.com' https://api.github.com/repos/octo-org/octo-repo
deny 'only talks to github.com' http://example.com/collect -f data=secret
deny 'only talks to github.com' HTTPS://example.com/collect
deny 'only talks to github.com' 'repos/octo-org/octo-repo?next=https://example.com'
with_env GH_HOST=example.com deny 'only talks to github.com' repos/octo-org/octo-repo
with_env GH_HOST=github.com allow repos/octo-org/octo-repo
with_env GH_HOST= allow repos/octo-org/octo-repo
# gh joins non-URL paths onto https://api.github.com/, so these stay on GitHub.
allow //example.com/collect
allow api.github.com/user

# --- Output flags ------------------------------------------------------------

allow user --jq .login
allow user -q .login
allow user --jq=.login
allow repos/octo-org/octo-repo/issues --template '{{range .}}{{.title}}{{"\n"}}{{end}}'
allow repos/octo-org/octo-repo/issues -t '{{range .}}{{.title}}{{"\n"}}{{end}}'
allow repos/octo-org/octo-repo/issues --template='{{.env}}'
allow repos/octo-org/octo-repo/issues --paginate --slurp
allow repos/octo-org/octo-repo -i
allow repos/octo-org/octo-repo --include
allow repos/octo-org/octo-repo --silent
allow repos/octo-org/octo-repo --cache 1h
allow repos/octo-org/octo-repo --cache=3600s
allow repos/octo-org/octo-repo -p corsair,scarlet-witch
allow repos/octo-org/octo-repo --preview corsair --preview scarlet-witch
allow repos/octo-org/octo-repo --preview=baptiste
deny 'prints request headers' repos/octo-org/octo-repo --verbose
deny 'escape sequences' repos/octo-org/octo-repo --allow-escape-sequences
deny 'escape sequences' repos/octo-org/octo-repo --allow-escape-sequences=true
deny 'takes no value' repos/octo-org/octo-repo --paginate=true
deny 'takes no value' repos/octo-org/octo-repo --silent=false
deny 'takes no value' repos/octo-org/octo-repo --include=true
deny 'separate arguments' repos/octo-org/octo-repo -i=true
deny 'separate arguments' user -q.login
deny 'separate arguments' user -iq .login
deny 'needs a value' user --jq
deny 'needs a value' user -H

# A value flag takes the next argument as its value even if it starts with -,
# exactly as gh's flag parser does. gh's jq then fails on these; nothing is sent.
allow user --jq --method=POST
allow user --jq -X

# --- jq and environment variables --------------------------------------------
# gh's jq can read the environment, which may hold GH_TOKEN.

deny 'reads environment variables' user --jq '$ENV.GH_TOKEN'
deny 'reads environment variables' user --jq 'env.GH_TOKEN'
deny 'reads environment variables' user --jq '[env[]]'
deny 'reads environment variables' user -q '$ENV | keys'
deny 'reads environment variables' user --jq='$ENV'
deny 'reads environment variables' user --jq 'ENV'
# Crude on purpose: a field called env is refused too.
deny 'reads environment variables' repos/octo-org/octo-repo/deployments --jq '.[].env'
allow repos/octo-org/octo-repo/deployments --jq '.[].environment'
allow repos/octo-org/octo-repo/deployments --jq '.[].env_name'
allow repos/octo-org/octo-repo/deployments --jq '.[] | .payload.envoy'

# --- GraphQL -----------------------------------------------------------------

allow_graphql graphql -f query='query { viewer { login } }'
allow_graphql graphql --raw-field query='{ viewer { login } }'
allow_graphql graphql -F query='query { viewer { login } }'
allow_graphql graphql --field=query='query { viewer { login } }'
allow_graphql graphql -f query='query($n: Int!) { viewer { repositories(first: $n) { nodes { name } } } }' -F n=10
allow_graphql graphql -f query='query { repository(owner: "octo-org", name: "octo-repo") { viewerSubscription } }'
allow_graphql graphql -f query='query { viewer { login } }' -f operationName=Viewer
allow_graphql graphql -X GET -f query='query { viewer { login } }'
deny 'GraphQL mutation' graphql -f query='mutation { addStar(input: {starrableId: "R_1"}) { clientMutationId } }'
deny 'GraphQL mutation' graphql -f query='mutation AddStar { addStar(input: {starrableId: "R_1"}) { clientMutationId } }'
deny 'GraphQL mutation' graphql -f query='mutation($id: ID!) { addStar(input: {starrableId: $id}) { clientMutationId } }' -f id=R_1
deny 'GraphQL mutation' graphql -f query='mutation,{ addStar(input: {starrableId: "R_1"}) { clientMutationId } }'
deny 'GraphQL mutation' graphql -f query='MUTATION { addStar(input: {starrableId: "R_1"}) { clientMutationId } }'
deny 'GraphQL subscription' graphql -f query='subscription { issueUpdated { title } }'
# A second operation selected by operationName.
deny 'GraphQL mutation' graphql -f query='query Read { viewer { login } } mutation Write { addStar(input: {starrableId: "R_1"}) { clientMutationId } }' -f operationName=Write
# Multi-line, with the mutation after a comment.
deny 'GraphQL mutation' graphql -f query='
  # just reading, honest
  mutation {
    addStar(input: {starrableId: "R_1"}) { clientMutationId }
  }
'
# Crude on purpose: the word anywhere in the arguments is refused.
deny 'GraphQL mutation' graphql -f query='query { viewer { login } } # mutation'
deny 'GraphQL mutation' graphql -f query='query { viewer { login } }' --jq '.data.mutation'
deny 'GraphQL mutation' graphql -f 'query[]=mutation { addStar(input: {starrableId: "R_1"}) { clientMutationId } }'
deny 'reads a local file' graphql -F query=@query.graphql
deny 'sends a request body' graphql --input query.json
# The word only matters for GraphQL.
allow search/issues -f q=mutation
allow search/issues -f q=subscription
# Only the exact endpoint `graphql` is GraphQL, as in gh; anything else is a GET.
# Endpoints that mention graphql still get the word check, so GitHub's handling
# of a GET to its GraphQL endpoint never matters.
allow /graphql -f query='query { viewer { login } }'
deny 'GraphQL mutation' /graphql -f query='mutation { addStar(input: {starrableId: "R_1"}) { clientMutationId } }'
deny 'GraphQL mutation' 'graphql?query=mutation{addStar(input:{starrableId:"R_1"}){clientMutationId}}'
deny 'GraphQL mutation' GRAPHQL/ -f query='mutation { addStar(input: {starrableId: "R_1"}) { clientMutationId } }'

# --- Positional arguments and odd flags --------------------------------------

deny 'expected one endpoint'
deny 'expected one endpoint' --jq .login
deny 'expected one endpoint' repos/octo-org/octo-repo POST
deny 'expected one endpoint' repos/octo-org/octo-repo --paginate false
deny 'expected one endpoint' repos/octo-org/one repos/octo-org/two
deny 'ends flag parsing' repos/octo-org/octo-repo -- -X POST
deny 'ends flag parsing' -- repos/octo-org/octo-repo
deny 'unknown flag' repos/octo-org/octo-repo --output out.json
deny 'unknown flag' repos/octo-org/octo-repo -R octo-org/octo-repo
deny 'unknown flag' repos/octo-org/octo-repo --repo octo-org/octo-repo
deny 'unknown flag' repos/octo-org/octo-repo --dry-run
deny 'unknown flag' repos/octo-org/octo-repo -
deny 'unknown flag' repos/octo-org/octo-repo ---method=POST
deny 'unknown flag' repos/octo-org/octo-repo --meth POST
deny 'unknown flag' repos/octo-org/octo-repo --JQ .x

# --- Help and exit codes -----------------------------------------------------

shows_help --help
shows_help -h
shows_help repos/octo-org/octo-repo --help
passes_exit_code 1 repos/octo-org/octo-repo/issues/999999
passes_exit_code 4 user
