# gh read: design

The rules `gh read` enforces, and why. The README covers what it's for and how to set it up. `test/cases.sh` is the executable form of this document: every rule here has cases there, and the refusal phrases it lists are part of the interface.

## Goals

- Anything `gh read` runs is read-only. If it can't be sure, it refuses.
- Agents already know `gh api`, so `gh read` takes the same arguments.
- Safe to allowlist with a single rule, eg `Bash(gh read *)` in Claude Code.
- Installs anywhere gh and a POSIX shell run, with `gh extension install`.
- Rules are easy to read and extend.

## Non-goals

- Limiting *what* can be read. The token's read scope is unchanged; `gh read` only removes writes. No endpoint allow- or denylists.
- Replacing gh's read-only subcommands (`gh pr view`, `gh run view` …). They're already safe to allowlist.
- Supporting every `gh api` flag. Unknown flags are refused rather than guessed at.
- GitHub Enterprise Server. Requests stay on github.com.

## Parsing

`gh read` reads its arguments the way gh's flag parser (pflag) does, so both agree on what every argument is. If they disagreed, an argument `gh read` took for a value could reach gh as a flag.

- A value flag takes the next argument as its value, even if that starts with `-`. `--long=value` is also accepted.
- Boolean flags are bare. `--paginate=true` is refused.
- Short flags stand alone: `-X GET`, not `-XGET`, `-X=GET` or `-iX GET`.
- `--` is refused, because it would stop flag checking.
- Any other argument starting with `-` (including `-` alone) that isn't in the tables below is refused.
- Exactly one argument is left over: the endpoint. Flags can come before or after it.

## REST

Runs `gh api --method GET <args>`. With GET, `gh api` sends `-f/-F` fields as query-string parameters, so search queries and filters still work.

Allowed flags:

| Flag | Notes |
| --- | --- |
| `-X, --method` | Only `GET`, in any case. Agents often add it for search and filters |
| `-q, --jq` | gh's built-in jq. Refused if it contains the word `env` (see below) |
| `-t, --template` | Go templates; can't run commands or read the environment |
| `--paginate`, `--slurp` | |
| `-i, --include`, `--silent` | |
| `--cache <duration>` | Only writes gh's own cache dir |
| `-p, --preview <names>` | Only sets an `Accept` header |
| `-f, --raw-field key=value` | Query params. Values are plain strings, so `@` is fine |
| `-F, --field key=value` | Query params. Refused if it starts with `@` or contains `=@` |
| `-H, --header key:value` | Only `Accept` and `X-GitHub-Api-Version` |

Refused:

| Input | Why |
| --- | --- |
| `-X`/`--method` other than `GET` | Only GET requests |
| `--input` | Request body |
| `-F key=@file`, `-F key=@-` | Reads a local file or stdin and sends it to GitHub |
| Any other header, or a header containing a line break | Avoids method-override and similar header tricks |
| `--hostname`, an endpoint containing `://` | Keeps requests on github.com |
| `GH_HOST` set to anything but `github.com` | Same |
| `--verbose`, `--allow-escape-sequences` | No use to an agent; `--verbose` prints request headers |
| `env` as a word in `--jq` | gh's jq can read environment variables, which may include `GH_TOKEN` |
| Malformed or unknown flags, `--` | See Parsing |
| More or fewer than one endpoint | |

Header names are matched case-insensitively, using the text before the first `:` as gh does, with no surrounding whitespace allowed.

gh treats any endpoint containing `://` as a full URL, and joins everything else onto `https://api.github.com/`. `GH_REPO` only fills placeholders and doesn't change the host.

The `env` check is a case-insensitive whole-word match (no letter, digit or `_` on either side), so it catches `env`, `$ENV` and `env.HOME` but not `.environment` or `.env_name`. jq has no eval and identifiers can't be escaped, so this is the only route to the environment. Templates have no such function.

## GraphQL

`gh read graphql` runs `gh api graphql <args>`. GraphQL normally uses POST. Same flags as REST, plus:

- The query comes from `-f query=…`, `--raw-field query=…` or `-F query=…` (no `@`). Other fields are GraphQL variables.
- Refused if any argument contains `mutation` or `subscription` as a GraphQL name: case-insensitive, with no letter, digit or `_` on either side. Checking every argument, rather than parsing the query, covers comments, other operations in the same document (`operationName` could select them) and fields like `query[]=`. The name boundary keeps read fields like `viewerSubscription` working. A false positive means the agent falls back to `gh api`, which is fine.

The endpoint is GraphQL only when it is exactly `graphql`, as in gh. Anything else, like `/graphql` or `graphql?x=1`, is a REST GET. An endpoint that contains `graphql` in any case still gets the word check, so it never matters whether GitHub would run a mutation sent over GET.

## Refusals

- Exit code 2, nothing sent to GitHub, nothing on stdout.
- Exactly one line on stderr, starting `gh read: `, naming the problem and the fallback, eg `gh read: -X POST isn't allowed: gh read only makes GET requests and GraphQL queries. Use gh api for writes.` Refusals never echo a multi-line argument.
- Flag problems are reported in argument order, before the endpoint, host and GraphQL checks.
- `-h`/`--help` anywhere prints usage to stdout and exits 0. No arguments at all is an ordinary refusal.
- Otherwise `exec gh api …`, so gh's own output and exit codes pass straight through.

## Implementation

- **Language:** POSIX `sh`, a single executable `gh-read` at the repo root, which is what gh extensions expect. Runs on Alpine/BusyBox images without bash.
- **No rebuilding:** validation only reads the arguments. The final call is `exec "${GH_PATH:-gh}" api --method GET "$@"` (REST) or `exec "${GH_PATH:-gh}" api "$@"` (GraphQL). gh sets `GH_PATH` to its own executable when it runs an extension, after the caller's environment, so the caller can't redirect it.
- **Rules at the top of the file** as plain lists: value flags, boolean flags, refused flags with reasons, allowed headers, blocked words. Extending it means adding to a list, and adding cases first.
- If POSIX `sh` gets painful, switch to Go as a precompiled extension (`gh extension create --precompiled=go`, released with `cli/gh-extension-precompile`). Same rules and tests.
- No config file or environment knobs.

## Testing

- `test/cases.sh` lists the cases in plain shell quoting, one per line: `allow <args>`, `allow_graphql <args>`, `deny <reason> <args>`, plus help, exit-code and environment cases. It covers every rule above, the tricky forms, and realistic commands based on real agent usage.
- `test/run.sh [shell …]` runs every case with each given shell running `gh-read`. It sets `GH_PATH` to `test/fake-gh`, which records the arguments it receives, so the tests check the exact `gh api` command without network or auth.
- CI runs the cases under dash, bash, BusyBox (Alpine) and macOS `/bin/sh`, plus ShellCheck.

## Threat model

- **Protects against:** an agent (confused, or steered by prompt injection) writing to GitHub through an allowlisted read command: comments, PR/issue edits, merges, deletions, workflow dispatches, gists. Also:
  - **Sending data elsewhere:** with Claude Code's Bash sandbox, gh usually runs outside it so it can reach its credentials, which means the sandbox's network allowlist doesn't apply. The host rules are what keep requests on github.com.
  - **Reading the token:** `--jq` can't read the token out of the environment.
- **Doesn't protect against:**
  - Reading anything the token can read, including private repos.
  - Leaking what it reads through some other channel the agent has.
  - Someone who can modify the installed extension, which lives in `~/.local/share/gh/extensions/`. Keep that outside any sandbox-writable path, and install from GitHub rather than linking a local checkout the agent can edit.
- **Assumes:** GitHub's GET endpoints don't change state, and its GraphQL API only changes state through mutations.
