# gh read: spec

A gh extension that gives AI agents (and anything else you don't fully trust) read-only access to the GitHub API. It accepts the same arguments as `gh api`, refuses anything that could write, and hands the rest to `gh api`.

`test/cases.sh` is the executable form of this spec: every rule below has cases there, and the refusal phrases it lists are part of the interface.

## Problem

Coding agents read GitHub constantly: PR review comments, reviews, issue comments, commits, releases, check runs, workflow logs, files in other repos. Most of this has no read-only `gh` subcommand, so agents use `gh api`. But `gh api` can also write (`-X POST`, `-f body=…`, GraphQL mutations), so it can't be safely allowlisted in an agent's permission system, and every read ends up as a permission prompt.

In one month of Claude Code use on one machine, that was ~500 prompts for read-only `gh api` calls, around a quarter of all prompts.

Permission rules can't fix this: they match on command prefixes and can't reliably tell a GET from a POST in the arguments. `gh read` moves that decision into a small program that checks the arguments after the shell has parsed them.

## Context: the setup this comes from

Written for Danny's local Claude Code setup (config in [dannysmith/dotfiles](https://github.com/dannysmith/dotfiles), `claude/settings.json` and `claude/CLAUDE.md`; background in [Claude Code's Bash Sandbox](https://danny.is/notes/claude-codes-bash-sandbox/) and [Reducing permission prompts](https://danny.is/notes/reducing-permission-prompts-bash-sandbox/)):

- **Bash runs in Claude Code's Seatbelt sandbox, in auto mode.** Sandboxed commands can write the project and temp dirs and reach allowlisted hosts (github.com is one). They can't read credential dirs, including `~/.config/gh` and `~/.ssh`, so `gh` can't authenticate inside the sandbox. That's deliberate: sandboxed code (including npm install scripts) should never hold a GitHub token.
- **`gh *` is in `sandbox.excludedCommands`**, so gh runs *outside* the sandbox with its normal credentials, governed by permission rules. A command only leaves the sandbox when every part of it is excluded and it has no `cd`, redirect, `$(...)`, heredoc, subshell or loop. `gh read … | jq` would run sandboxed and fail auth. Agents are told to use `--jq` instead of pipes.
- **Read-only gh subcommands are allowlisted** (`gh pr view/checks/diff`, `gh issue view`, `gh run view`, `gh release view`, `gh search` …). **Writes are in `permissions.ask`** (`gh pr create/merge/comment`, `gh issue create/edit/comment`, `git push` …) so they always prompt. So does `Bash(gh api:*)`, because `gh api` can write.
- **Permission rules match command prefixes only.** No regex, and Claude Code ignores argument matching for Bash. A PreToolUse hook's "allow" can't override an `ask` rule. So "allow `gh api` reads but ask for writes" can't be expressed in config. A separate, allowlistable command can.
- **The auto-mode classifier** reviews anything not decided by a rule, but it blocks rather than prompts, and Danny wants GitHub writes to prompt every time. That's why `gh api` stays in `ask` and reads move to `gh read`.

Target config once `gh read` exists: add `Bash(gh read:*)` to `permissions.allow`, keep `Bash(gh api:*)` in `ask`. No sandbox change needed, because `gh *` is already excluded. Update the CLAUDE.md "GitHub" section to say "use `gh read` for API reads".

## Goals

- Anything `gh read` runs is read-only. If it can't be sure, it refuses.
- Agents already know `gh api`, so `gh read` takes the same arguments: swap `api` for `read`.
- Safe to allowlist with a single rule, eg `Bash(gh read:*)` in Claude Code.
- Installs anywhere gh runs (macOS, Linux servers, Docker images) with `gh extension install`.
- Rules are easy to read and extend.

## Non-goals

- Limiting *what* can be read. The token's read scope is unchanged; `gh read` only removes writes. No endpoint allow- or denylists.
- Replacing gh's read-only subcommands (`gh pr view`, `gh run view` …). They're already safe to allowlist.
- Supporting every `gh api` flag. Unknown flags are refused rather than guessed at.
- GitHub Enterprise Server. Requests stay on github.com.

## Interface

```
gh read <endpoint> [flags]
gh read graphql -f query='query { … }' [flags]
gh read --help
```

`<endpoint>` is a REST path (`repos/{owner}/{repo}/pulls/12/comments`), with gh's `{owner}`, `{repo}` and `{branch}` placeholders, or `graphql`. Flags may come before or after it, as with `gh api`.

## Rules

### Parsing

`gh read` reads its arguments the way gh's flag parser (pflag) does, so both agree on what every argument is:

- A value flag takes the next argument as its value, even if that starts with `-`. `--long=value` is also accepted.
- Boolean flags are bare. `--paginate=true` is refused.
- Short flags stand alone: `-X GET`, not `-XGET`, `-X=GET` or `-iX GET`.
- `--` is refused, because it would stop flag checking.
- Any other argument starting with `-` (including `-` alone) that isn't in the tables below is refused.
- Exactly one argument is left over: the endpoint.

### REST

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
| Any other header | Avoids method-override and similar header tricks |
| `--hostname`, an endpoint containing `://` | Keeps requests on github.com |
| `GH_HOST` set to anything but `github.com` | Same |
| `--verbose`, `--allow-escape-sequences` | No use to an agent; `--verbose` prints request headers |
| `env` as a word in `--jq` | gh's jq can read environment variables, which may include `GH_TOKEN` |
| Malformed or unknown flags, `--` | See Parsing |
| More or fewer than one endpoint | |

Header names are matched case-insensitively, using the text before the first `:` as gh does, with no surrounding whitespace allowed. gh treats any endpoint containing `://` as a full URL, and joins everything else onto `https://api.github.com/`. `GH_REPO` only fills placeholders and doesn't change the host.

The `env` check is a case-insensitive whole-word match (no letter, digit or `_` on either side), so it catches `env`, `$ENV` and `env.HOME` but not `.environment` or `.env_name`. jq has no eval and identifiers can't be escaped, so this is the only route to the environment. Templates have no such function.

### GraphQL

`gh read graphql` runs `gh api graphql <args>`. GraphQL normally uses POST. Same flags as REST, plus:

- The query comes from `-f query=…`, `--raw-field query=…` or `-F query=…` (no `@`). Other fields are GraphQL variables.
- Refused if any argument contains `mutation` or `subscription` as a GraphQL name: case-insensitive, with no letter, digit or `_` on either side. Checking every argument, rather than parsing the query, covers comments, other operations in the same document (`operationName` could select them) and fields like `query[]=`. The name boundary keeps read fields like `viewerSubscription` working. A false positive means the agent falls back to `gh api`, which is fine.

The endpoint is GraphQL only when it is exactly `graphql`, as in gh. Anything else, like `/graphql` or `graphql?x=1`, is a REST GET. An endpoint that contains `graphql` in any case still gets the word check, so it never matters whether GitHub would run a mutation sent over GET.

### Refusal behaviour

- Exit code 2, nothing sent to GitHub, nothing on stdout.
- Exactly one line on stderr, starting `gh read: `, naming the problem and the fallback, eg `gh read: -X POST isn't allowed: gh read only makes GET requests and GraphQL queries. Use gh api for writes.` Refusals never echo a multi-line argument.
- Flag problems are reported in argument order, before the endpoint, host and GraphQL checks.
- `-h`/`--help` anywhere prints usage to stdout and exits 0. No arguments at all is an ordinary refusal.
- Otherwise `exec gh api …`, so gh's own output and exit codes pass straight through.

## Implementation

- **Language:** POSIX `sh`, a single executable `gh-read` at the repo root (what gh extensions expect). Runs on Alpine/BusyBox images without bash.
- **No rebuilding:** validation only reads the arguments. The final call is `exec "${GH_PATH:-gh}" api --method GET "$@"` (REST) or `exec "${GH_PATH:-gh}" api "$@"` (GraphQL). gh sets `GH_PATH` to its own executable when it runs an extension, after the caller's environment, so the caller can't redirect it.
- **Rules at the top of the file** as plain lists: value flags, boolean flags, refused flags with reasons, allowed headers, blocked words. Extending it means adding to a list.
- If POSIX `sh` gets painful, switch to Go as a precompiled extension (`gh extension create --precompiled=go`, released with `cli/gh-extension-precompile`). Same spec and tests.
- No config file or environment knobs.

## Testing

- `test/cases.sh` is a table of cases in plain shell quoting, one per line: `allow <args>`, `allow_graphql <args>`, `deny <reason> <args>`, plus help, exit-code and environment cases. It covers every rule above, the tricky forms, and realistic commands based on real agent usage.
- `test/run.sh [shell …]` runs every case with each given shell running `gh-read`. It sets `GH_PATH` to `test/fake-gh`, which records the arguments it receives, so the tests check the exact `gh api` command without network or auth.
- CI runs the cases under dash, bash, BusyBox (Alpine) and macOS `/bin/sh`, plus ShellCheck.

## Install and agent setup

```
gh extension install dannysmith/gh-read
```

Claude Code (`~/.claude/settings.json`):

```json
{
  "permissions": {
    "allow": ["Bash(gh read:*)"],
    "ask": ["Bash(gh api:*)"]
  }
}
```

With the Bash sandbox on, gh needs to run outside it to reach its credentials: add `gh *` (or `gh read *`) to `sandbox.excludedCommands`. Excluded commands only leave the sandbox when called bare, so agents should use `--jq` rather than pipes. The README has the full setup and an `AGENTS.md`/`CLAUDE.md` snippet.

## Threat model

- **Protects against:** an agent (confused, or steered by prompt injection) writing to GitHub through an allowlisted read command: comments, PR/issue edits, merges, deletions, workflow dispatches, gists. Also against using it to send data elsewhere: with the Bash sandbox, `gh read` runs outside it, so the sandbox's network allowlist doesn't apply, and the host rules are what keep requests on github.com. And against reading the token out of the environment through `--jq`.
- **Doesn't protect against:**
  - Reading anything the token can read, including private repos.
  - Leaking what it reads through some other channel the agent has.
  - Someone who can modify the installed extension, which lives in `~/.local/share/gh/extensions/`. Keep that outside any sandbox-writable path, and install from GitHub rather than linking a local checkout the agent can edit.
- **Assumes:** GitHub's GET endpoints don't change state, and its GraphQL API only changes state through mutations.
