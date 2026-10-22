# git-bouncer

Git hooks (POSIX shell) that check who is committing and keep secrets out of
your commits. They are driven by a `.git-bouncer-config` file at the
repository root, or by a global config written by `setup.sh`.

- **Author check** (pre-commit): if the repository has no local
  `user.name` / `user.email`, you pick an identity from a list before you can commit.
- **Content check** (pre-commit): blocks the commit if a line you added
  matches a censored pattern. Files are never modified.
- **Message censoring** (commit-msg): every match in the commit message is
  replaced with `***`.

## Installation

### Global installation (all repositories)

```sh
./setup.sh --scan ~/code
```

`setup.sh` asks its questions on the terminal and:

1. copies the hooks to `~/.config/git-bouncer/hooks/` (or
   `$XDG_CONFIG_HOME/git-bouncer/hooks/`) and runs
   `git config --global core.hooksPath` on that directory. If another global
   `core.hooksPath` is already set, it asks before replacing it.
2. finds every git repository under each `--scan` directory (the option can be
   repeated). If `--scan` is not given, it asks for a directory, and an empty
   answer skips the scan. It then lists everyone who authored or committed
   there, most commits first, plus your global `user.name` / `user.email`:

   ```
     1) Jane Smith <jane@company.com>  (142 commits)
     2) John Doe <john@company.com>  (37 commits)
     3) Me <me@example.com>  (global git identity)
   Authors to add [e.g. 1,3-5 | a = all | empty = none]:
   ```

   Entries are grouped by email, ignoring case, and use the most common name.
   GitHub's `noreply@github.com` web-flow committer is left out.
3. writes `~/.config/git-bouncer/config` with the chosen `[authors]` and the
   default `[censor]` patterns from [`defaults/censor-patterns`](defaults/censor-patterns).
   If the config already exists, it asks before overwriting it. If you say no,
   only the hooks are updated.

| Option | Effect |
|---|---|
| `--scan DIR` | Offer the committers of the repositories under `DIR` |
| `--patterns FILE` | Start `[censor]` from `FILE` instead of `defaults/censor-patterns` |
| `--uninstall` | Unset the global `core.hooksPath` (only if it points at git-bouncer). Files are kept |

With a global installation:

- A repository's own `.git-bouncer-config`, if there is one, is used instead
  of the global config (it is not merged with it).
- A repository that sets its own `core.hooksPath` (for example husky, or the
  per-repository installation below) keeps it, because the local setting wins.
- A global `core.hooksPath` makes git ignore `.git/hooks/`. To keep existing
  hooks working, git-bouncer runs `.git/hooks/pre-commit` and
  `.git/hooks/commit-msg` after its own checks, when they exist and are
  executable. Other hooks in `.git/hooks/` (such as `pre-push`) do not run.
- The author check runs in every repository without a local `user.name` /
  `user.email`, even when a global identity is set.

#### Default censor patterns

[`defaults/censor-patterns`](defaults/censor-patterns) contains patterns for
common secrets: private key blocks, AWS, GitHub, Slack, OpenAI/Anthropic and
Google keys, credentials in URLs, quoted `password = "..."`-style assignments, and
Claude co-author commit trailers. Edit it to change what `setup.sh` puts in new
configs. It uses the same syntax as `[censor]` and must not contain `[section]` lines.

### Per-repository installation

Copy `.githooks/` and `.git-bouncer-config` into your repository, then enable
the hooks (once per clone):

```sh
git config core.hooksPath .githooks
```

The hook files must be executable. They are committed with the executable bit.
If it gets lost (for example, after copying the files on Windows), run:

```sh
chmod +x .githooks/*
git update-index --chmod=+x .githooks/pre-commit .githooks/commit-msg .githooks/commit-check.sh
```

| File | Role |
|---|---|
| `.githooks/commit-check.sh` | All the logic |
| `.githooks/pre-commit` | Calls `commit-check.sh pre-commit` |
| `.githooks/commit-msg` | Calls `commit-check.sh commit-msg <file>` |

The wrappers call the script through `sh` and do not use symlinks, so they also
work with Git for Windows.

## Configuration

```ini
# Lines starting with # and blank lines are ignored.

[authors]
John Doe <john@company.com>
Jane Smith <jane@company.com>

[censor]
*password*
api_key=*
secret-project-*
/token[[:space:]]*[:=][[:space:]]*[^[:space:]]+/
```

### `[authors]`

One `Name <email>` per line. Malformed entries are ignored with a warning.

### `[censor]`

One pattern per line. Matching is case-insensitive, and a pattern can match
anywhere inside a line.

- **Glob** (default): `*` matches any sequence of characters, `?` matches
  exactly one character, and every other character is literal. Because `*`
  is greedy, `api_key=*` matches up to the end of the line.
- **Regular expression**: write it between slashes, `/.../`. It is a POSIX
  extended regex (as in `grep -E`/`awk`), e.g. `[[:space:]]`, `+`, `|`, `(...)`.

Patterns that would match empty text (such as `*` on its own) are ignored with
a warning. An invalid regex blocks the commit with an error.

A missing config file or section turns off the matching feature. Without
`[censor]`, nothing is checked or censored. Without `[authors]`, the author
check asks you to type a name and email.

## Behavior

### Author check

If `git config --local user.name` and `user.email` are not both set, a menu
appears:

```
git-bouncer: no commit author is configured for this repository.
Who is committing?
  1) John Doe <john@company.com>
  2) Jane Smith <jane@company.com>
  3) Enter another identity
Choice [1-3]:
```

The choice is saved with `git config --local`. The commit is then stopped,
because Git has already chosen the author of the commit in progress. Run the
same commit again.

The menu reads from `/dev/tty`. When no terminal is available (IDE, GUI
client), the hook prints the `git config --local ...` commands to run and blocks
the commit.

### Content check

Only lines **added** in the staged changes (`git diff --cached`) are checked.
The report gives the file, the line number and the pattern. The matched text
itself is not printed:

```
git-bouncer: commit blocked, staged changes match censored patterns:
  src/db.js:3: matches *password*
```

`.git-bouncer-config` itself is never checked. To commit anyway, use
`git commit --no-verify`.

### Message censoring

```
$ git commit -m "deploy secret-project-x"
git-bouncer: censored 1 occurrence(s) of secret-project-* on line 1
```

This step never blocks the commit and needs no terminal.
