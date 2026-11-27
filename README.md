# gh read

A [gh](https://cli.github.com) extension that gives AI agents read-only access to the GitHub API. It takes the same arguments as `gh api`, refuses anything that could write, and passes the rest to `gh api`.

```sh
gh read repos/cli/cli/pulls/123/comments --jq '.[].body'
gh read search/issues -f q='repo:cli/cli is:open label:bug'
gh read graphql -f query='query { viewer { login } }'
```

## Why

Coding agents read GitHub constantly: review comments, issue threads, check runs, workflow logs, files in other repos. Most of that has no read-only `gh` subcommand, so they use `gh api`. But `gh api` can also write (`-X POST`, `-f body=…`, GraphQL mutations), so it isn't safe to allowlist, and every read becomes a permission prompt. In a month of Claude Code use on my machine that was around 500 prompts, about a quarter of all of them.

Permission rules match command prefixes, so they can't tell a GET from a POST. `gh read` is a separate command you can allowlist with one rule. It checks the arguments itself, after the shell has parsed them.

## Install

```sh
gh extension install dannysmith/gh-read
```

It's a single POSIX shell script, so it runs wherever gh does, including Alpine and other minimal Docker images.

## Usage

Use it exactly like `gh api`, with `read` in place of `api`.

REST calls always run as GET. `-f` and `-F` fields become query-string parameters, so searches and filters work as they do with `gh api -X GET`. GraphQL calls run as usual, as long as they're queries.

When `gh read` refuses a call, nothing is sent to GitHub. It exits with code 2 and prints one line on stderr saying why:

```
$ gh read -X POST repos/cli/cli/issues -f title=hi
gh read: -X POST isn't allowed: gh read only makes GET requests and GraphQL queries. Use gh api for writes.
```

Otherwise it runs `gh api`, so the output and exit codes are gh's own.

### What's allowed

These `gh api` flags work: `-X`/`--method GET`, `-q`/`--jq`, `-t`/`--template`, `--paginate`, `--slurp`, `-i`/`--include`, `--silent`, `--cache`, `-p`/`--preview`, `-f`/`--raw-field`, `-F`/`--field` and `-H`/`--header`.

These are refused:

- Any method other than GET, and `--input`.
- `-F key=@file` and `-F key=@-`, which read a local file or stdin and send it to GitHub.
- Headers other than `Accept` and `X-GitHub-Api-Version`.
- `--hostname`, full URLs, and `GH_HOST` set to anything but `github.com`.
- GraphQL calls with `mutation` or `subscription` anywhere in their arguments.
- `env` or `$ENV` in `--jq`, because gh's jq can read environment variables, which might include `GH_TOKEN`.
- `--verbose`, `--allow-escape-sequences`, `--`, combined short flags like `-XPOST`, and any flag it doesn't recognise.

The checks are strict on purpose. A wrong refusal costs you one `gh api` prompt. A wrong allow could post to GitHub. [SPEC.md](SPEC.md) has the full rules, and [test/cases.sh](test/cases.sh) has a test case for each.

## Using it with Claude Code

### Permissions

Allow `gh read` and keep `gh api` behind a prompt, in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": ["Bash(gh read *)"],
    "ask": ["Bash(gh api *)"]
  }
}
```

Reads then run without asking, and every write through `gh api` still needs your approval.

### The Bash sandbox

If you use Claude Code's Bash sandbox, gh can't read its credentials inside it, which is how it should be. Exclude gh so it runs outside the sandbox with your normal login, governed by the permission rules above:

```json
{
  "sandbox": {
    "excludedCommands": ["gh *"]
  }
}
```

Use `"gh read *"` instead if you only want `gh read` to run outside. Either way, excluded commands still go through your permission rules, but any gh command you approve, including a `gh api` write, runs with your full access.

Claude Code only takes a call out of the sandbox when your excluded commands cover every command in it. Even then, a `cd`, a redirect, a heredoc, `$(...)`, a subshell or a loop keeps it sandboxed (see [`sandbox.excludedCommands`](https://code.claude.com/docs/en/settings-reference#sandbox-excludedcommands)). So `gh read repos/cli/cli | jq .` runs inside the sandbox, because `jq` isn't excluded, and fails to authenticate. Agents need to filter output with `--jq` or `--template`, and run gh commands on their own.

### Telling the agent

Add something like this to your `CLAUDE.md` or `AGENTS.md`:

```markdown
## GitHub

- Use `gh read` for GitHub API reads. It takes the same arguments as `gh api` but only makes GET requests and GraphQL queries. Use `gh api` only to write.
- Run each gh command on its own, without pipes, redirects or `&&`. Filter output with `--jq` or `--template`.
- To read a file from a repo, use `-H 'Accept: application/vnd.github.raw'` or `--jq '.content | @base64d'` rather than piping to `base64`.
- Use gh's own commands where one exists (`gh pr view`, `gh run view --log`, `gh search`).
```

### gh's own read-only commands

These are safe to allowlist too:

```json
"Bash(gh pr view *)", "Bash(gh pr list *)", "Bash(gh pr diff *)", "Bash(gh pr checks *)", "Bash(gh pr status *)",
"Bash(gh issue view *)", "Bash(gh issue list *)", "Bash(gh issue status *)",
"Bash(gh run view *)", "Bash(gh run list *)", "Bash(gh run watch *)",
"Bash(gh workflow view *)", "Bash(gh workflow list *)",
"Bash(gh release view *)", "Bash(gh release list *)",
"Bash(gh repo view *)", "Bash(gh label list *)", "Bash(gh cache list *)",
"Bash(gh search *)", "Bash(gh status *)"
```

Think twice before adding `gh run download` or `gh release download`. With gh excluded from the sandbox, they can write files anywhere on disk.

### Other agents

The same approach works with any agent that allowlists commands: allow `gh read` and keep `gh api` behind approval.

## What it protects against

`gh read` stops an agent (confused, or steered by prompt injection) from writing to GitHub through a command you allowlisted for reading: comments, edits, merges, deletions, workflow runs, gists. It also keeps requests on github.com, which matters because it runs outside the sandbox, where the sandbox's network allowlist doesn't apply. And it stops `--jq` from printing your token.

It doesn't:

- Limit what can be read. Anything your token can read, the agent can read, including private repos.
- Stop the agent leaking what it reads through some other channel it has.
- Protect itself. The extension lives in `~/.local/share/gh/extensions/gh-read`, and anything that can edit it can make it do anything. Install it from GitHub, not with `gh extension install .` from a checkout the agent can write to.

It assumes GitHub's GET endpoints don't change anything, and that its GraphQL API only changes things through mutations.

## Development

```sh
test/run.sh                  # every case, with /bin/sh running gh-read
test/run.sh dash bash ksh    # every case, once per shell
shellcheck gh-read test/run.sh test/fake-gh test/cases.sh
```

The tests point `GH_PATH` at `test/fake-gh`, which records the arguments it receives instead of calling GitHub, so they need no network or login. CI runs them under dash, bash, BusyBox (Alpine) and macOS `/bin/sh`.

To change a rule, add or change cases in `test/cases.sh` first.

## Licence

[MIT](LICENSE)
