# gh read: spec

A gh extension that gives AI agents (and anything else you don't fully trust) read-only access to the GitHub API. It accepts the same arguments as `gh api`, refuses anything that could write, and hands the rest to `gh api`.

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

- Limiting *what* can be read. The token's read scope is unchanged; `gh read` only removes writes.
- Replacing gh's read-only subcommands (`gh pr view`, `gh run view` …). They're already safe to allowlist.
- Supporting every `gh api` flag. Unknown flags are refused rather than guessed at.

## Interface

```
gh read <endpoint> [flags]
gh read graphql -f query='query { … }' [flags]
gh read --help
gh read --dry-run <endpoint> [flags]   # print the gh api command instead of running it
```

`<endpoint>` is a REST path (`repos/{owner}/{repo}/pulls/12/comments`), with gh's `{owner}`, `{repo}` and `{branch}` placeholders, or `graphql`.

## Rules

### REST

Always runs `gh api --method GET <endpoint> …`. With GET, `gh api` sends `-f/-F` fields as query-string parameters, so search queries and filters still work.

Allowed flags (both `--long value` and `--long=value`; short flags as `-x value`):

| Flag                                                | Notes                                         |
| --------------------------------------------------- | --------------------------------------------- |
| `-q, --jq`                                          | gh's built-in jq; can't run commands          |
| `-t, --template`                                    | Go templates; can't run commands              |
| `--paginate`, `--slurp`                             |                                               |
| `-i, --include`, `--silent`                         |                                               |
| `--cache <duration>`                                |                                               |
| `-p, --preview <names>`                             | Only sets an `Accept` header                  |
| `-f, --raw-field key=value`                         | Query params                                  |
| `-F, --field key=value`                             | Query params; value must not start with `@`   |
| `-H, --header key:value`                            | Only `Accept` and `X-GitHub-Api-Version`      |

Refused:

| Input                                         | Why                                                                |
| --------------------------------------------- | ------------------------------------------------------------------ |
| `-X`, `--method`                              | Method is always GET                                               |
| `--input`                                     | Request body                                                       |
| `-F key=@file`, `-F key=@-`                   | Reads a local file or stdin and sends it to GitHub                 |
| Any other header                              | Avoids method-override and similar header tricks                   |
| `--hostname`, a full URL endpoint             | Keeps requests on the default host                                 |
| `GH_HOST` set to anything but `github.com`    | Same                                                               |
| `--verbose`, `--allow-escape-sequences`       | No use to an agent; `--verbose` prints request headers             |
| Attached short values (`-XPOST`, `-q.foo`), `--`, unknown flags | Refuse anything the parser doesn't explicitly recognise |
| More or fewer than one endpoint               |                                                                    |

### GraphQL

`gh read graphql` runs `gh api graphql …` (GraphQL always uses POST). Same flags as REST, plus:

- The query must come from `-f query=…`, `--raw-field query=…` or `-F query=…` (no `@`).
- Refused if the query text contains `mutation` or `subscription` as a word anywhere, including in comments or in other operations in the same document (`operationName` could select them). This check is deliberately crude. A false positive means the agent falls back to `gh api`, which is fine.
- Other fields are GraphQL variables and allowed as above.

### Refusal behaviour

- Exit code 2, nothing sent to GitHub.
- One line on stderr naming the problem and the fallback, eg: `gh read: --method isn't allowed (gh read only makes GET requests and GraphQL queries). For writes, use gh api.`
- Otherwise `exec gh api …`, so gh's own output and exit codes pass straight through.

## Implementation

- **Language:** POSIX `sh`, a single executable `gh-read` at the repo root (what gh extensions expect). Runs on Alpine/BusyBox images without bash. Validation only reads the arguments; it never rebuilds them, so the final call is `exec gh api --method GET "$@"` (REST) or `exec gh api "$@"` (GraphQL).
- **Rules at the top of the file** as plain lists: value flags, boolean flags, allowed headers, blocked GraphQL words. Extending it means adding to a list.
- If POSIX `sh` gets painful, switch to Go as a precompiled extension (`gh extension create --precompiled=go`, released with `cli/gh-extension-precompile`). Same spec and tests.
- No config file or environment knobs in v1.

## Testing

- `--dry-run` prints the exact `gh api` argv instead of running it, so tests need no network or auth.
- `test/cases`: a table of `allow|deny <args>`, covering every rule above and the tricky forms (`--method=POST`, `-XPOST`, `-F body=@/etc/passwd`, `-H 'X-HTTP-Method-Override: DELETE'`, a mutation hidden in a second operation, `--` before `-X`, URL endpoints).
- `test/run.sh` runs the table; CI runs it under `dash`, `busybox sh` and `bash`, plus ShellCheck.

## Install and agent setup (README material)

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

With the Bash sandbox on, gh needs to run outside it to reach its credentials: add `gh *` (or `gh read *`) to `sandbox.excludedCommands`. Excluded commands only leave the sandbox when called bare, so agents should use `--jq` rather than pipes.

The README should also include an `AGENTS.md`/`CLAUDE.md` snippet telling agents to use `gh read` for reads, and a recommended allowlist of gh's own read-only subcommands.

## Threat model

- **Protects against:** an agent (confused, or steered by prompt injection) writing to GitHub through an allowlisted read command: comments, PR/issue edits, merges, deletions, workflow dispatches, gists.
- **Doesn't protect against:**
  - Reading anything the token can read, including private repos.
  - Leaking what it reads through some other channel the agent has.
  - Someone who can modify the installed extension, which lives in `~/.local/share/gh/extensions/`. Keep that outside any sandbox-writable path.
- **Assumes:** GitHub's GET endpoints don't change state, and its GraphQL API only changes state through mutations.

## Open questions

- Endpoint rules: v1 has none. Worth an optional denylist later (eg `/user/*`), or is that out of scope given the non-goals?
- `--cache`: keep it? It writes gh's cache, which is harmless but not strictly a read.
- Should refusal messages also go to stdout so agents that only read stdout see them?
- Licence: MIT.
