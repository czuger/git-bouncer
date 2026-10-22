#!/bin/sh
# git-bouncer setup: install the hooks for every repository (global
# core.hooksPath) and write a global config, prefilled with committers found
# in existing repositories and with the default censor patterns. Then offer to
# remove the global user.name / user.email.
#
# Usage: see usage() below, or run "setup.sh --help".

set -u
LC_ALL=C
export LC_ALL

here=$(cd "$(dirname "$0")" && pwd -P) || exit 1
install_dir="${XDG_CONFIG_HOME:-${HOME:-}/.config}/git-bouncer"
hooks_dir="$install_dir/hooks"
config="$install_dir/config"
tab=$(printf '\t')
nl='
'

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

usage() {
    cat <<EOF
Usage: setup.sh [--scan DIR]... [--patterns FILE]
       setup.sh --uninstall

Installs the git-bouncer hooks for every repository (git config --global
core.hooksPath) and writes the global config:
  $config

  --scan DIR       look for git repositories under DIR and offer their
                   committers for [authors] (can be repeated)
  --patterns FILE  [censor] patterns to start with
                   (default: $here/defaults/censor-patterns)
  --uninstall      unset the global core.hooksPath (files are kept)
EOF
}

scan_dirs=
patterns="$here/defaults/censor-patterns"
uninstall=
while [ $# -gt 0 ]; do
    case $1 in
        --scan)
            [ $# -ge 2 ] || die "--scan needs a directory"
            scan_dirs="$scan_dirs$2$nl"
            shift 2
            ;;
        --scan=*) scan_dirs="$scan_dirs${1#--scan=}$nl"; shift ;;
        --patterns)
            [ $# -ge 2 ] || die "--patterns needs a file"
            patterns=$2
            shift 2
            ;;
        --patterns=*) patterns=${1#--patterns=}; shift ;;
        --uninstall) uninstall=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

has_tty() { (: </dev/tty) 2>/dev/null; }

# Prompt on the terminal and read one line into $answer (trimmed).
# Fails on end of input.
ask() {
    printf '%s' "$1" >/dev/tty
    IFS= read -r answer </dev/tty || return 1
    answer=$(printf '%s\n' "$answer" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
}

# Ask a yes/no question. $2 (y or n) is the answer used for an empty reply.
confirm() {
    while :; do
        ask "$1" || die "aborted"
        case ${answer:-$2} in
            [yY]|[yY][eE][sS]) return 0 ;;
            [nN]|[nN][oO]) return 1 ;;
        esac
        printf 'Please answer y or n.\n' >/dev/tty
    done
}

# --- hooks -----------------------------------------------------------------

install_hooks() {
    mkdir -p "$hooks_dir" || die "cannot create $hooks_dir"
    for f in commit-check.sh pre-commit commit-msg; do
        cp "$here/.githooks/$f" "$hooks_dir/$f" && chmod +x "$hooks_dir/$f" ||
            die "cannot install $hooks_dir/$f"
    done

    current=$(git config --global core.hooksPath 2>/dev/null)
    if [ -n "$current" ] && [ "$current" != "$hooks_dir" ]; then
        printf 'The global core.hooksPath is already set to:\n  %s\n' "$current" >/dev/tty
        confirm "Replace it with $hooks_dir? [y/N] " n ||
            die "kept the current core.hooksPath; the hooks were copied to $hooks_dir but are not enabled."
    fi
    git config --global core.hooksPath "$hooks_dir" || die "could not set core.hooksPath"
    say "hooks installed in $hooks_dir (global core.hooksPath)"
}

uninstall_hooks() {
    current=$(git config --global core.hooksPath 2>/dev/null)
    if [ "$current" = "$hooks_dir" ]; then
        git config --global --unset core.hooksPath || die "could not unset core.hooksPath"
        say "removed the global core.hooksPath; git-bouncer no longer runs by default."
    else
        say "the global core.hooksPath does not point at git-bouncer; nothing to do."
    fi
    say "the files are still in $install_dir"
}

# --- authors ---------------------------------------------------------------

# Print "name<TAB>email<TAB>commits" for everyone who authored or committed
# in the git repositories under $scan_dirs, most commits first.
scan_committers() {
    new_tmp repos
    printf '%s' "$scan_dirs" | while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        [ -d "$dir" ] || { say "not a directory, skipped: $dir"; continue; }
        find "$dir" -name .git -prune -print 2>/dev/null
    done >"$repos"
    say "found $(wc -l <"$repos" | tr -d ' ') git repositories"

    while IFS= read -r dotgit; do
        git -C "$(dirname "$dotgit")" log --all --format='%an%x09%ae%x09%cn%x09%ce' 2>/dev/null
    done <"$repos" | awk -F "$tab" '
        # Group by email (case-insensitive) and keep the most used spelling
        # of the email and of the name.
        function add(name, email,    key) {
            key = tolower(email)
            if (name == "" || name ~ /[<>]/ || key !~ /.@./ || key ~ /[<>[:space:]]/) return
            if (key == "noreply@github.com") return
            commits[key]++
            if (++spelled[key, email] > addr_uses[key]) {
                addr_uses[key] = spelled[key, email]
                addr[key] = email
            }
            if (++uses[key, name] > best_uses[key]) {
                best_uses[key] = uses[key, name]
                best[key] = name
            }
        }
        {
            add($1, $2)
            if (tolower($4) != tolower($2)) add($3, $4)
        }
        END { for (k in commits) print best[k] "\t" addr[k] "\t" commits[k] }
    ' | sort -t "$tab" -k3,3nr -k1,1
}

# Turn a selection such as "1,3-5" into "1 3 4 5", for a menu of $1 entries.
# Fails if the selection is invalid.
parse_selection() {
    printf '%s\n' "$2" | awk -v max="$1" '
        {
            gsub(/[ \t]/, "")
            n = split($0, parts, ",")
            for (i = 1; i <= n; i++) {
                p = parts[i]
                if (p == "") continue
                if (p ~ /^[0-9]+$/) lo = hi = p + 0
                else if (p ~ /^[0-9]+-[0-9]+$/) {
                    split(p, r, "-")
                    lo = r[1] + 0
                    hi = r[2] + 0
                } else exit 1
                if (lo < 1 || hi > max || lo > hi) exit 1
                for (j = lo; j <= hi; j++)
                    if (!(j in seen)) { seen[j]; out = out " " j }
            }
        }
        END { if (out == "") exit 1; print substr(out, 2) }
    '
}

# Offer the scanned committers and the global git identity; set $authors to
# the chosen "Name <email>" lines.
choose_authors() {
    authors=
    new_tmp candidates
    [ -n "$scan_dirs" ] && scan_committers >"$candidates"

    gname=$(git config --global user.name 2>/dev/null)
    gemail=$(git config --global user.email 2>/dev/null)
    if [ -n "$gname" ] && [ -n "$gemail" ] &&
        ! cut -f2 "$candidates" | grep -qixF -- "$gemail"; then
        printf '%s\t%s\tglobal git identity\n' "$gname" "$gemail" >>"$candidates"
    fi

    count=$(wc -l <"$candidates" | tr -d ' ')
    if [ "$count" -eq 0 ]; then
        say "no committers to offer; [authors] is left empty."
        return 0
    fi

    printf '\nAuthors offered when a repository has no local user.name / user.email:\n' >/dev/tty
    awk -F "$tab" '{
        note = ($3 ~ /^[0-9]+$/) ? $3 " commit" ($3 == 1 ? "" : "s") : $3
        printf "  %d) %s <%s>  (%s)\n", NR, $1, $2, note
    }' "$candidates" >/dev/tty
    while :; do
        ask "Authors to add [e.g. 1,3-5 | a = all | empty = none]: " || die "aborted"
        case $answer in
            '') return 0 ;;
            a|A|all|ALL) selection=$(seq 1 "$count" | tr '\n' ' ') && break ;;
        esac
        selection=$(parse_selection "$count" "$answer") && break
        printf 'Please enter numbers between 1 and %d, such as 1,3-5.\n' "$count" >/dev/tty
    done

    authors=$(awk -F "$tab" -v sel="$selection" '
        BEGIN { n = split(sel, s, " "); for (i = 1; i <= n; i++) want[s[i]] }
        NR in want { print $1 " <" $2 ">" }
    ' "$candidates")
}

# --- config ----------------------------------------------------------------

write_config() {
    tmp="$config.tmp.$$"
    tmpfiles="$tmpfiles $tmp"
    {
        printf '# git-bouncer configuration, written by setup.sh on %s.\n' "$(date +%Y-%m-%d)"
        printf '# Used by every repository.\n'
        printf '# One entry per line. Blank lines and lines starting with # are ignored.\n\n'
        printf '[authors]\n'
        printf '# Offered as a menu when no local user.name / user.email is set.\n'
        [ -n "$authors" ] && printf '%s\n' "$authors"
        printf '\n[censor]\n'
        cat "$patterns"
    } >"$tmp" && mv "$tmp" "$config" || die "could not write $config"
    say "config written to $config (edit it at any time)"
}

# --- global identity -------------------------------------------------------

# The author check asks for an identity in each repository, so a global
# user.name / user.email is not needed. Where the hooks do not run (--no-verify,
# a repository with its own core.hooksPath), git would use it without asking.
# Offer to remove it.
check_global_identity() {
    gname=$(git config --global user.name 2>/dev/null)
    gemail=$(git config --global user.email 2>/dev/null)
    [ -n "$gname$gemail" ] || return 0

    printf '\nA global git identity is set:\n' >/dev/tty
    [ -n "$gname" ] && printf '  user.name  = %s\n' "$gname" >/dev/tty
    [ -n "$gemail" ] && printf '  user.email = %s\n' "$gemail" >/dev/tty
    printf 'git-bouncer asks for an identity in each repository instead. Where the\n' >/dev/tty
    printf 'hooks do not run (--no-verify, own core.hooksPath), git commits with it silently.\n' >/dev/tty
    confirm "Remove the global user.name / user.email? [y/N] " n || {
        say "kept the global git identity."
        return 0
    }

    for key in user.name user.email; do
        [ -n "$(git config --global "$key" 2>/dev/null)" ] || continue
        git config --global --unset-all "$key" || say "could not unset the global $key"
        left=$(git config --global --show-origin "$key" 2>/dev/null) &&
            say "the global $key is still set: $left"
    done
    say "removed the global git identity. To restore it:"
    [ -n "$gname" ] && printf '  git config --global user.name "%s"\n' "$gname" >&2
    [ -n "$gemail" ] && printf '  git config --global user.email "%s"\n' "$gemail" >&2
    return 0
}

# --- main ------------------------------------------------------------------

if [ -n "$uninstall" ]; then
    uninstall_hooks
    exit 0
fi

has_tty || die "setup.sh asks questions and must be run from a terminal."
[ -f "$here/.githooks/commit-check.sh" ] || die "cannot find $here/.githooks"
[ -f "$patterns" ] || die "patterns file not found: $patterns"
! grep -q '^[[:space:]]*\[.*\][[:space:]]*$' "$patterns" ||
    die "$patterns must only contain patterns, not [section] lines"

install_hooks

if [ -f "$config" ] && ! confirm "Overwrite the existing config $config? [y/N] " n; then
    say "kept the existing config."
else
    if [ -z "$scan_dirs" ]; then
        ask "Directory to scan for committers (empty to skip): " || die "aborted"
        case $answer in
            '~'|'~/'*) answer=${HOME:-}${answer#'~'} ;;
        esac
        [ -n "$answer" ] && scan_dirs="$answer$nl"
    fi

    choose_authors
    write_config
fi

check_global_identity
