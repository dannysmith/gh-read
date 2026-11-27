# Task 1: Build gh read

Build the `gh read` extension described in `SPEC.md`: tests first, then the spec and docs, then the script, then publish and install.

## Decisions

These settle the spec's open questions and the gaps found when checking it against `gh api --help`, the gh v2.105.0 source (`pkg/cmd/api`, `pkg/cmd/extension`) and go-gh v2.17.0. Phase 2 folds them into `SPEC.md`.

**Scope and output**

- No endpoint rules. Limiting what can be read is a non-goal.
- Keep `--cache`. It only writes gh's own cache dir.
- Refusals go to stderr only, exit 2. Nothing goes to stdout, so output that gets parsed stays clean.
- MIT licence.
- No `--dry-run`. Tests use a fake `gh` instead (see Phase 1).

**Method**

- `-X GET`, `-X get`, `--method GET` and `--method=GET` are allowed and passed through. Any other method is refused. Agents already write `-X GET` for search and filtered lists, often after the endpoint. gh uppercases the method (`http.go`).
- The final call is `exec "${GH_PATH:-gh}" api --method GET "$@"` for REST and `exec "${GH_PATH:-gh}" api "$@"` for GraphQL. The arguments are never rebuilt. gh sets `GH_PATH` itself when it runs an extension, after the caller's env (`manager.go`), so the caller can't point it elsewhere.

**Hosts**

`gh read` runs outside the Bash sandbox, so the sandbox's network allowlist doesn't apply to it. These rules stop data being sent to other hosts:

- Refuse `--hostname`.
- Refuse any endpoint containing `://`. gh treats that as a full URL (`http.go`).
- Refuse when `GH_HOST` is set to anything other than `github.com`. `GH_REPO` only fills placeholders and doesn't change the request host, so it needs no check.

**`--jq`**

- Refuse a value containing the word `env`, case-insensitive. This catches `env` and `$ENV`. gh's jq loads `os.Environ()` (`go-gh/pkg/jq`), so `--jq '$ENV.GH_TOKEN'` would print the token when it's set in the env.
- `--template` needs no check. go-gh's template functions can't reach the env.

**GraphQL**

- Refuse if any argument contains `mutation` or `subscription` as a GraphQL name: case-insensitive, with no `[A-Za-z0-9_]` on either side. Scanning every argument, not just `query=`, is simpler and closes gaps like `query[]=`. The name boundary keeps real read fields like `viewerSubscription` working.
- The query can come from `-f`, `--raw-field` or `-F`, never `@file`.
- The endpoint is GraphQL only when it is exactly `graphql`, as in gh. Anything else, like `/graphql` or `graphql?x=1`, is a REST GET. Any endpoint that contains `graphql` (case-insensitive) still gets the word check, so it never matters whether GitHub runs a mutation sent over GET.

**Parsing**

- Flags may come before or after the endpoint.
- Exactly one positional argument (the endpoint).
- Boolean flags are bare only. `--paginate=true` is refused.
- Value flags accept `--long value`, `--long=value` and `-x value`. Refuse attached short values (`-XPOST`, `-q.foo`), combined short flags (`-iX`), `--`, and unknown flags.
- Headers: the name is the text before the first `:`, as in gh. It must equal `Accept` or `X-GitHub-Api-Version`, case-insensitive, with no surrounding whitespace.
- `-F`/`--field`: refuse when the text after the first `=` starts with `@`. `-f key=@x` is a plain string and is allowed.
- `-h`/`--help` anywhere prints our help and exits 0. No arguments is an ordinary refusal ("expected one endpoint").
- Every refusal is exactly one stderr line starting `gh read: `, containing one of the reason phrases listed at the top of `test/cases.sh`. Flag problems are reported in argument order, before the endpoint, host and GraphQL checks. Refusals never echo a multi-line argument.

**Known behaviour to document**

A write-shaped call without `-X`, eg `…/comments/1/replies -f body=hi`, is allowed. It becomes a GET with `body` as a query parameter. That is harmless, and the response (a list or a 404) makes it obvious nothing was posted.

## Phase 1: Test system

An executable spec that needs no network, auth or Claude.

- [x] `test/fake-gh`: writes its argv NUL-separated (`printf '%s\0' "$@"`) to `$FAKE_GH_LOG` and exits with `${FAKE_GH_EXIT:-0}`. NUL separation keeps multi-line GraphQL arguments exact.
- [x] `test/cases.sh`: sourced by the runner. One case per line, in real shell quoting, grouped by rule:
  - `allow <args>`: gh is called with exactly `api --method GET <args>`.
  - `allow_graphql <args>`: gh is called with exactly `api <args>`.
  - `deny <stderr-substring> <args>`: exit 2, gh is never called, and stderr contains the substring.
  - A way to set env for a case (for `GH_HOST`). Don't rely on `VAR=x func`, which behaves differently across shells.
- [x] Corpus cases based on `research/real-gh-api-commands.local.jsonl`, using generic owners, repos and bodies (`octo-org/octo-repo`), never copied verbatim. Cover:
  - Reads: `--jq` with complex filters, raw `Accept` headers, `?ref=` query strings, `-X GET -f q=…` search, `--paginate`, flags after the endpoint, `{owner}/{repo}` placeholders.
  - GraphQL reads with fragments, aliases and `$endCursor` pagination.
  - Writes: `-X PATCH` with fields, `-F body=@file` replies, `-f body=` replies, batched `resolveReviewThread` mutations.
- [x] Edge cases for every rule above, including:
  - Method: `--method=POST`, `-XPOST`, `-iX POST`, `--` followed by `-X`.
  - Fields and headers: `-F body=@/etc/passwd`, `-F x=@-`, `-H 'X-HTTP-Method-Override: DELETE'`, `-H 'Accept : x'`.
  - Hosts: `https://` endpoints, `--hostname`, `GH_HOST`.
  - GraphQL: a mutation in a second operation, a mutation in a comment, `viewerSubscription` (allowed), `-F query=@q.graphql`.
  - `--jq '$ENV.GH_TOKEN'` and `--jq 'env'`.
  - Arguments: zero endpoints, two endpoints, `--paginate=true`.
- [x] A test that gh's exit code passes through (`FAKE_GH_EXIT=3`).
- [x] `test/run.sh [shell …]`: runs every case with each given shell running `./gh-read`, prints failures in full, exits non-zero on any failure. Defaults to `/bin/sh`.
- [x] Run it against a stub `gh-read` and confirm the cases fail for the right reasons.

## Phase 2: Spec and boilerplate

- [x] Update `SPEC.md` with the decisions above. Remove the open questions, replace the `--dry-run` testing section, and add the exfiltration reasoning to the threat model.
- [x] `README.md`: what it is and why, install, usage, what's refused, and Claude Code setup (permissions, `sandbox.excludedCommands`, the bare-command caveat). Also:
  - An `AGENTS.md`/`CLAUDE.md` snippet: use `gh read` for API reads, one call per command, `--jq` instead of pipes, `--jq '.content | @base64d'` or `-H 'Accept: application/vnd.github.raw'` instead of piping to `base64`.
  - A recommended allowlist of gh's read-only subcommands.
  - A threat model summary.
- [x] `LICENSE` (MIT).
- [x] `.github/workflows/test.yml`:
  - Ubuntu: `dash`, `bash`, ShellCheck.
  - Alpine container: BusyBox `sh`, `grep` and `tr`, as found in many Docker images.
  - macOS: `/bin/sh`, which is bash 3.2 in POSIX mode.

## Phase 3: Build

- [x] `gh-read`: a single POSIX `sh` executable at the repo root. Rule lists at the top (value flags, boolean flags, allowed headers, blocked GraphQL words). One `for arg do … done` pass that validates without touching `"$@"`, then `exec`.
- [x] Every case passes under `/bin/sh`, `dash`, `bash` and `ksh` locally, and ShellCheck is clean.

## Phase 4: Tidy and publish

- [x] Check the README's Claude Code instructions against the current docs: permission rule syntax (`Bash(gh read:*)` vs `Bash(gh read *)`), how compound commands are matched, and the `excludedCommands` behaviour.
- [x] Read everything through once more for simplicity.
- [x] `git init`. Confirm `research/*.local.*` is ignored before the first commit.
- [x] **Ask Danny** before creating `github.com/dannysmith/gh-read` and pushing. Make it public and add the `gh-extension` topic.
- [x] Confirm CI passes on GitHub.

## Phase 5: Install and dotfiles

- [ ] `gh extension install dannysmith/gh-read` from GitHub, not `gh extension install .`. A local install is a symlink into `~/dev/gh-read`, which sandboxed commands can write. The spec's threat model requires the installed extension to live outside any sandbox-writable path.
- [ ] Smoke test a few real reads and refusals by hand.
- [ ] Propose dotfiles edits for Danny to make or approve. Both files are write-protected from the sandbox.
  - `claude/settings.json`: add `Bash(gh read:*)` to `permissions.allow`, matching the file's existing `:*` style (the docs treat `:*` and ` *` as equivalent). Keep `Bash(gh api:*)` in `ask`.
  - `claude/CLAUDE.md` "GitHub" section: use `gh read` for API reads, falling back to `gh api` only for writes.
