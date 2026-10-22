#!/bin/sh
# git-bouncer: commit author check and pattern censoring, driven by the
# global config ~/.config/git-bouncer/config (written by setup.sh).
#
# Usage (from the hook wrappers):
#   commit-check.sh pre-commit
#   commit-check.sh commit-msg <message-file>

set -u
LC_ALL=C
export LC_ALL

hook=${1:-}
[ $# -gt 0 ] && shift

config="${XDG_CONFIG_HOME:-${HOME:-}/.config}/git-bouncer/config"
tab=$(printf '\t')

say() { printf 'git-bouncer: %s\n' "$*" >&2; }
die() { say "$@"; exit 1; }

tmpfiles=
cleanup() { [ -n "$tmpfiles" ] && rm -f $tmpfiles; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Create a temporary file, removed on exit, and store its path in variable $1.
# (Not called through $(...), which would lose the tmpfiles update.)
new_tmp() {
    f=$(mktemp "${TMPDIR:-/tmp}/git-bouncer.XXXXXX") || die "cannot create a temporary file"
    tmpfiles="$tmpfiles $f"
    eval "$1=\$f"
}

# Print the entries of [section] from the config, one per line.
# Missing file or section prints nothing.
read_section() {
    [ -f "$config" ] || return 0
    awk -v want="$1" '
        { sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
        $0 == "" || /^#/ { next }
        /^\[.*\]$/ { cur = tolower(substr($0, 2, length($0) - 2)); next }
        cur == want { print }
    ' "$config"
}

# Shared awk code: turn a [censor] entry into a lowercase ERE and load the
# entries of the file named by the awk variable "pfile" into pat[]/rx[].
# Entries written as /.../ are raw regexes, anything else is a glob.
# Matching is case-insensitive: callers lowercase the text before match().
AWK_PATTERNS='
function to_re(p,    n, i, c, re) {
    n = length(p)
    if (n > 2 && substr(p, 1, 1) == "/" && substr(p, n, 1) == "/")
        return tolower(substr(p, 2, n - 2))
    re = ""
    for (i = 1; i <= n; i++) {
        c = substr(p, i, 1)
        if (c == "*") re = re ".*"
        else if (c == "?") re = re "."
        else if (c == "\\" || c == "^") re = re "\\" c
        else if (index(".[]()$+{}|", c)) re = re "[" c "]"
        else re = re c
    }
    return tolower(re)
}
function load_patterns(    line, re) {
    np = 0
    while ((getline line < pfile) > 0) {
        re = to_re(line)
        if (match("", re)) {
            print "git-bouncer: ignoring pattern that matches empty text: " line | "cat 1>&2"
            continue
        }
        pat[++np] = line
        rx[np] = re
    }
    close(pfile)
}
'

# --- pre-commit: author -----------------------------------------------------

# Print "name<TAB>email" for each valid [authors] entry.
list_authors() {
    read_section authors | awk '
        {
            if (match($0, /<[^<>]*@[^<>]*>$/) && RSTART > 1) {
                name = substr($0, 1, RSTART - 1)
                sub(/[ \t]+$/, "", name)
                if (name != "") {
                    print name "\t" substr($0, RSTART + 1, RLENGTH - 2)
                    next
                }
            }
            print "git-bouncer: ignoring malformed author: " $0 | "cat 1>&2"
        }
    '
}

has_tty() { (: </dev/tty) 2>/dev/null; }

# Prompt on the terminal and read one line into $answer (trimmed).
# Fails on end of input.
ask() {
    printf '%s' "$1" >/dev/tty
    IFS= read -r answer </dev/tty || return 1
    answer=$(printf '%s\n' "$answer" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
}

ask_manual_identity() {
    while :; do
        ask "Name: " || die "aborted"
        [ -n "$answer" ] && break
        printf 'The name cannot be empty.\n' >/dev/tty
    done
    new_name=$answer
    while :; do
        ask "Email: " || die "aborted"
        case $answer in
            *[[:space:]]*) ;;
            ?*@?*) break ;;
        esac
        printf 'Please enter a valid email address (it must contain an @).\n' >/dev/tty
    done
    new_email=$answer
}

check_author() {
    name=$(git config --local user.name 2>/dev/null)
    email=$(git config --local user.email 2>/dev/null)
    [ -n "$name" ] && [ -n "$email" ] && return 0

    authors=$(list_authors)

    if ! has_tty; then
        say "no commit author is configured for this repository."
        {
            printf 'Run one of the following, then commit again:\n\n'
            if [ -n "$authors" ]; then
                printf '%s\n' "$authors" | while IFS=$tab read -r n e; do
                    printf '  git config --local user.name "%s"\n' "$n"
                    printf '  git config --local user.email "%s"\n\n' "$e"
                done
            fi
            printf '  git config --local user.name "Your Name"\n'
            printf '  git config --local user.email "you@example.com"\n'
        } >&2
        exit 1
    fi

    printf '\ngit-bouncer: no commit author is configured for this repository.\n' >/dev/tty
    if [ -z "$authors" ]; then
        ask_manual_identity
    else
        count=$(printf '%s\n' "$authors" | wc -l | tr -d ' ')
        other=$((count + 1))
        printf 'Who is committing?\n' >/dev/tty
        printf '%s\n' "$authors" | awk -F "$tab" '{ printf "  %d) %s <%s>\n", NR, $1, $2 }' >/dev/tty
        printf '  %d) Enter another identity\n' "$other" >/dev/tty
        while :; do
            ask "Choice [1-$other]: " || die "aborted"
            case $answer in
                ''|*[!0-9]*) ;;
                *) [ "$answer" -ge 1 ] && [ "$answer" -le "$other" ] && break ;;
            esac
            printf 'Please enter a number between 1 and %d.\n' "$other" >/dev/tty
        done
        if [ "$answer" -eq "$other" ]; then
            ask_manual_identity
        else
            line=$(printf '%s\n' "$authors" | sed -n "${answer}p")
            new_name=${line%%"$tab"*}
            new_email=${line#*"$tab"}
        fi
    fi

    git config --local user.name "$new_name" &&
        git config --local user.email "$new_email" ||
        die "could not save the identity"
    say "saved author for this repository: $new_name <$new_email>"
    die "the commit was stopped so the new author applies; run your commit again."
}

# --- pre-commit: staged content -------------------------------------------

scan_staged() {
    new_tmp pfile
    read_section censor >"$pfile"
    [ -s "$pfile" ] || return 0

    report=$(
        git diff --cached --no-color --no-ext-diff -U0 --diff-filter=ACMR \
            --src-prefix=a/ --dst-prefix=b/ |
        awk -v pfile="$pfile" "$AWK_PATTERNS"'
            BEGIN { load_patterns() }
            /^diff --git / { header = 1; next }
            header && /^\+\+\+ / {
                file = substr($0, 5)
                sub(/\t$/, "", file)
                if (file ~ /^".*"$/) file = substr(file, 2, length(file) - 2)
                sub(/^b\//, "", file)
                next
            }
            /^@@/ {
                header = 0
                s = $0
                sub(/^@@ -[0-9,]+ \+/, "", s)
                sub(/[^0-9].*$/, "", s)
                ln = s + 0
                next
            }
            header { next }
            /^\+/ {
                text = tolower(substr($0, 2))
                for (i = 1; i <= np; i++)
                    if (match(text, rx[i])) {
                        printf "  %s:%d: matches %s\n", file, ln, pat[i]
                        hits++
                    }
                ln++
            }
            END { exit hits > 0 }
        '
    )
    case $? in
        0) return 0 ;;
        1) ;;
        *) die "could not scan the staged changes (check the [censor] patterns in $config)" ;;
    esac

    say "commit blocked, staged changes match censored patterns:"
    printf '%s\n' "$report" >&2
    printf '\nRemove them from the staged files, or bypass this check with "git commit --no-verify".\n' >&2
    exit 1
}

# --- commit-msg ------------------------------------------------------------

censor_message() {
    msg=${1:-}
    [ -n "$msg" ] && [ -f "$msg" ] || die "commit-msg: missing message file"

    new_tmp pfile
    read_section censor >"$pfile"
    [ -s "$pfile" ] || return 0

    new_tmp out
    awk -v pfile="$pfile" "$AWK_PATTERNS"'
        BEGIN { load_patterns() }
        # Everything below the scissors line is the diff from "commit -v",
        # which git discards.
        done || /^. -+ >8 -+$/ { done = 1; print; next }
        {
            line = $0
            for (i = 1; i <= np; i++) {
                out = ""
                rest = line
                n = 0
                while (rest != "" && match(tolower(rest), rx[i])) {
                    out = out substr(rest, 1, RSTART - 1) "***"
                    rest = substr(rest, RSTART + RLENGTH)
                    n++
                }
                if (n) {
                    line = out rest
                    printf "git-bouncer: censored %d occurrence(s) of %s on line %d\n", n, pat[i], NR | "cat 1>&2"
                }
            }
            print line
        }
    ' "$msg" >"$out" || die "could not censor the commit message (check the [censor] patterns in $config)"

    cmp -s "$out" "$msg" || cat "$out" >"$msg"
}

# --- repository hooks ------------------------------------------------------

# With a global core.hooksPath, git no longer runs the hooks in .git/hooks.
# Run the repository's own hook of the same name, if any, once ours passed.
run_repo_hook() {
    repo_hooks=$(cd "$(git rev-parse --git-common-dir)/hooks" 2>/dev/null && pwd -P) || return 0
    self_dir=$(cd "$(dirname "$0")" && pwd -P) || return 0
    [ "$repo_hooks" != "$self_dir" ] || return 0
    [ -f "$repo_hooks/$hook" ] && [ -x "$repo_hooks/$hook" ] || return 0
    "$repo_hooks/$hook" "$@"
    exit
}

case $hook in
    pre-commit)
        check_author
        scan_staged
        run_repo_hook
        ;;
    commit-msg)
        censor_message "$@"
        run_repo_hook "$@"
        ;;
    *)
        die "usage: commit-check.sh pre-commit | commit-msg <message-file>"
        ;;
esac
