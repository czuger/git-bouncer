# git-bouncer

> **Every commit gets checked at the door: the right name on it, and no secrets inside.**

Ever pushed a commit with your personal email to a work project, or the other way
around? Ever committed a password or an API key by accident? Both mistakes are easy to
make and hard to undo, because once something is in a repository's history it tends to
stay there. Bonus: it removes that “Co-Authored-By:” trailer you’ve been desperately trying to avoid, by default.

git-bouncer stands at the door of every commit and checks two things:

- **Who you are.** In a new repository, it asks which identity to use instead of
  quietly picking one for you, so work and personal projects stay separate.
- **What you bring in.** If your changes contain something that looks like a password,
  a key or a token, it stops the commit and shows you where it is, before the secret
  ever leaves your machine. Secrets in commit messages are removed automatically.

You install it once, it works in all your repositories, and it stays out of the way
until it is needed. No server, no account, nothing to run in the background.

## How it works

POSIX-shell git hooks that check who is committing and keep secrets out of commits.
They read one global config: `~/.config/git-bouncer/config` (or `$XDG_CONFIG_HOME/git-bouncer/config`).

- **Author check** (pre-commit): if the repo has no local `user.name`/`user.email`,
  pick an identity from a menu. It is saved with `git config --local`, then the commit
  is stopped (git already chose its author): run it again. Without a terminal (IDE, GUI),
  the hook prints the `git config --local` commands and blocks.
- **Content check** (pre-commit): blocks the commit if a line *added* in the staged
  diff matches a censored pattern. Reports file, line and pattern, never the matched
  text. Files are never modified. Bypass with `git commit --no-verify`.
- **Message censoring** (commit-msg): removes every match from the message.
  Never blocks, needs no terminal.

```
git-bouncer: no commit author is configured for this repository.
Who is committing?
  1) John Doe <john@company.com>
  2) Enter another identity
Choice [1-2]:

git-bouncer: commit blocked, staged changes match censored patterns:
  src/db.js:3: matches *password*
```

## Install

### Global (all repositories)

```sh
./setup.sh --scan ~/code
```

`setup.sh` (interactive):
1. Copies the hooks to `~/.config/git-bouncer/hooks/` and sets
   `git config --global core.hooksPath` to it (asks before replacing an existing one).
2. Lists everyone who authored/committed in the git repos under each `--scan` dir
   (repeatable; asked for if omitted, empty skips), plus your global identity, grouped
   by email, most commits first. GitHub's `noreply@github.com` is left out. You pick
   with `1,3-5`, `a` (all) or empty (none).
3. Writes the config with those `[authors]` and the default `[censor]` patterns
   (asks before overwriting; on no, the config is kept).
4. Offers to remove the global `user.name`/`user.email` (default: no) and prints the
   restore commands. It is not needed, and where hooks don't run (`--no-verify`, a repo
   with its own `core.hooksPath`) git would silently use it. Don't use
   `user.useConfigOnly` instead: git refuses before pre-commit runs, so no menu.

| Option | Effect |
|---|---|
| `--scan DIR` | Offer the committers of the repositories under `DIR` |
| `--patterns FILE` | Start `[censor]` from `FILE` instead of `defaults/censor-patterns` |
| `--uninstall` | Unset the global `core.hooksPath` (only if it points at git-bouncer). Files are kept |

Notes:
- A repo's own `core.hooksPath` (husky, per-repo install) wins over the global one.
- A global `core.hooksPath` makes git ignore `.git/hooks/`; git-bouncer still runs
  `.git/hooks/pre-commit` and `commit-msg` after its checks if executable. Other hooks
  (e.g. `pre-push`) don't run.
- The author check runs in every repo without a local identity, even if a global one is set.

### Per-repository

Copy `.githooks/` into the repo, then (once per clone):

```sh
git config core.hooksPath .githooks
```

| File | Role |
|---|---|
| `.githooks/commit-check.sh` | All the logic |
| `.githooks/pre-commit` | Calls `commit-check.sh pre-commit` |
| `.githooks/commit-msg` | Calls `commit-check.sh commit-msg <file>` |

Wrappers call the script via `sh` (no symlinks), so they work on Git for Windows.
If the executable bit gets lost:

```sh
chmod +x .githooks/*
git update-index --chmod=+x .githooks/pre-commit .githooks/commit-msg .githooks/commit-check.sh
```

## Configuration

```ini
# Comments and blank lines are ignored.
[authors]
John Doe <john@company.com>

[censor]
*password*
api_key=*
/token[[:space:]]*[:=][[:space:]]*[^[:space:]]+/
```

- `[authors]`: one `Name <email>` per line; malformed lines are ignored with a warning.
  Missing → the author check asks you to type a name and email.
- `[censor]`: one pattern per line, case-insensitive, matching anywhere in a line.
  Missing → nothing is checked or censored.
  - **Glob** (default): `*` any run, `?` one char, all else literal. `*` is greedy, so
    `api_key=*` matches to end of line.
  - **Regex**: `/.../`, POSIX ERE (as in `grep -E`).
  - Patterns matching empty text (e.g. `*`) are ignored with a warning; an invalid
    regex blocks the commit.

[`defaults/censor-patterns`](defaults/censor-patterns) seeds new configs: private keys,
AWS/GitHub/Slack/OpenAI/Anthropic/Google keys, credentials in URLs, quoted
`password = "..."` assignments and Claude co-author trailers. Same syntax as `[censor]`,
no `[section]` lines.
