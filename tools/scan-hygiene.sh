#!/usr/bin/env bash
# Scans a git work tree for things that must not be in a public repository, and prints only WHERE they are
# ("<rule> <path>:<line>"), never what was matched, so a leaked secret does not reach a CI log.
#
# Usage:
#   tools/scan-hygiene.sh                 scan the tracked files and the last commit
#   tools/scan-hygiene.sh --base <ref>    scan the tracked files and every non-merge commit in <ref>..HEAD
#   tools/scan-hygiene.sh --history       scan the tracked files and the messages of every non-merge commit on every ref
#                                         (file contents of old commits are not scanned: use git grep on a revision for that)
#   tools/scan-hygiene.sh --self-test     check the rules on planted examples in a temporary repository
#
# Rules that need no list (always on):
#   local-path      a personal Windows, macOS or Linux home path (placeholders like /home/me are fine)
#   key-shape       a private key block, or the shape of a Stripe, Google, AWS, GitHub or Slack key
#   team-id-shape   a team-ID-prefixed bundle ID, or a device UDID (placeholders like TEAM000000.org.example.app are fine)
#   secret-file     a tracked certificate, key, profile or Xcode archive
#   commit-text     a commit message, or the pull request title or body, with a "Generated with" line
#
# Rule that needs a list, kept out of the repository on purpose because the list itself would name what must not be named:
#   forbidden-term  a match of the extended regular expression in $HYGIENE_FORBIDDEN_TERMS, case-insensitive, in a tracked
#                   file's text or path, a commit message, or the pull request title or body. Put client and app names,
#                   bundle-ID prefixes, local folder names and tool names there. A path that matches is reported by its line
#                   number in the list printed by: git ls-files -- . ':!third_party' ':!tools/scan-hygiene.sh'
#                   Unset, the rule is skipped with a notice. That is the case for pull requests from forks, which cannot
#                   read secrets, so run the script with the variable set before merging one.
#
# Skipped: third_party/ (an exact copy of upstream) and this script. Environment: PR_TITLE, PR_BODY and PR_AUTHOR are
# checked when set (a bot author is skipped, as in the DCO check).
set -u

EXCLUDES=(':!third_party' ':!tools/scan-hygiene.sh')
found=0

report() { printf '%s\n' "$*"; found=1; }

# A path for the report: itself, unless it matches the forbidden terms, then its number in the tracked-file list.
safe_path() {
  local p=$1 n
  if [ -n "${HYGIENE_FORBIDDEN_TERMS:-}" ] && printf '%s\n' "$p" | grep -q -i -E -e "$HYGIENE_FORBIDDEN_TERMS"; then
    n=$(git ls-files -- . "${EXCLUDES[@]}" | grep -n -x -F -e "$p" | head -n 1 | cut -d: -f1)
    printf 'tracked-file-number-%s' "${n:-unknown}"
  else
    printf '%s' "$p"
  fi
}

# scan_content <rule> <extended regex> [<regex of matches that are placeholders>]
scan_content() {
  local rule=$1 re=$2 allow=${3:-} f n t
  while IFS=: read -r f n t; do
    if [ -n "$allow" ] && printf '%s\n' "$t" | grep -q -E -e "$allow"; then continue; fi
    report "$rule $(safe_path "$f"):$n"
  done < <(git grep -I -n -o -E -e "$re" -- . "${EXCLUDES[@]}" 2>/dev/null)
}

scan_files() {
  scan_content local-path '(C:\\+Users\\+|/home/|/Users/)[A-Za-z0-9._-]+' \
    '[\\/](me|user|username|name|you|example|runner|Public|Shared)$'
  scan_content key-shape \
    'BEGIN [A-Z ]*PRIVATE KEY|sk_live_[0-9A-Za-z]{10,}|rk_live_[0-9A-Za-z]{10,}|pk_live_[0-9A-Za-z]{10,}|whsec_[0-9A-Za-z]{10,}|AIza[0-9A-Za-z_-]{35}|GOCSPX-[0-9A-Za-z_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{40,}|xox[baprs]-[0-9A-Za-z-]{10,}'
  scan_content team-id-shape \
    '\b[A-Z0-9]{10}\.(com|org|net|io|app|site|dev)\.[A-Za-z0-9.-]+|\b0000[0-9A-F]{4}-[0-9A-F]{16}\b' \
    '^(TEAM0+|OTHER0+|X{10}|0{10}|ABCDE12345)\.|\.example(\.|$)|^[0-]+$'
  local f
  while IFS= read -r f; do
    report "secret-file $(safe_path "$f")"
  done < <(git ls-files -- . "${EXCLUDES[@]}" | grep -E -i '\.(p8|p12|pfx|mobileprovision|cer|pem|key|xip|keystore|jks)$|(^|/)AuthKey_|(^|/)\.env($|\.)')
}

scan_terms() {
  local terms=${HYGIENE_FORBIDDEN_TERMS:-}
  if [ -z "$terms" ]; then
    echo "note: forbidden-term rule skipped (HYGIENE_FORBIDDEN_TERMS is not set)"
    return
  fi
  local f n rest
  while IFS=: read -r f n rest; do report "forbidden-term $(safe_path "$f"):$n"; done \
    < <(git grep -I -n -i -E -e "$terms" -- . "${EXCLUDES[@]}" 2>/dev/null)
  while IFS=: read -r n rest; do report "forbidden-term tracked-file-number-$n"; done \
    < <(git ls-files -- . "${EXCLUDES[@]}" | grep -n -i -E -e "$terms")
}

# check_text <label> <text>: the rules that apply to a commit message or to pull request text.
check_text() {
  local label=$1 text=$2
  if printf '%s\n' "$text" | grep -q -i -E 'generated with'; then report "commit-text $label"; fi
  if [ -n "${HYGIENE_FORBIDDEN_TERMS:-}" ] && printf '%s\n' "$text" | grep -q -i -E -e "$HYGIENE_FORBIDDEN_TERMS"; then
    report "forbidden-term $label"
  fi
}

scan_commits() {
  local range=$1 sha author
  for sha in $(git rev-list --no-merges $range); do
    author=$(git log -1 --format=%an "$sha")
    case "$author" in *"[bot]") continue ;; esac
    check_text "commit:$(git rev-parse --short "$sha")" "$(git log -1 --format=%B "$sha")"
  done
  case "${PR_AUTHOR:-}" in *"[bot]") return 0 ;; esac
  if [ -n "${PR_TITLE:-}" ]; then check_text "pull-request-title" "$PR_TITLE"; fi
  if [ -n "${PR_BODY:-}" ]; then check_text "pull-request-body" "$PR_BODY"; fi
  return 0
}

self_test() {
  local here tmp failures=0 planted
  here=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  tmp=$(mktemp -d)
  # Planted values are built from pieces, so that this file never holds one whole.
  local key="sk_""live_""abcdefghij0123456789" pem="-----BEGIN ""RSA PRIVATE KEY-----"
  local win='C:\Users\'"alice" nix="/home/""bob/work"
  local team="ABCDE""FGHIJ"".com.acme.app" udid="0000""8110-001A2B3C4D5E6F70" term="acmecorp"
  planted="alice|bob|ABCDEFGHIJ|8110-001A|abcdefghij0123456789|acmecorp"
  # run_case <name> <expected rule, or none> <setup command, run inside the new repository> [<terms>]
  run_case() {
    local name=$1 expect=$2 setup=$3 terms=${4:-} out
    rm -rf "$tmp/r" && mkdir "$tmp/r" && (
      cd "$tmp/r" && git init -q && git config user.name tester && git config user.email t@example.org && git config core.autocrlf false &&
      echo clean > ok.txt && eval "$setup" && git add -A && git commit -q -m "test: $name"
    ) || { echo "FAIL $name: could not set up"; failures=$((failures + 1)); return; }
    out=$(cd "$tmp/r" && HYGIENE_FORBIDDEN_TERMS=$terms bash "$here" 2>&1)
    if [ "$expect" = none ]; then
      if printf '%s\n' "$out" | grep -q -E '^(local-path|key-shape|team-id-shape|secret-file|commit-text|forbidden-term) '; then
        echo "FAIL $name: expected a clean result, got: $out"; failures=$((failures + 1)); return
      fi
    elif ! printf '%s\n' "$out" | grep -q "^$expect "; then
      echo "FAIL $name: expected rule $expect, got: $out"; failures=$((failures + 1)); return
    fi
    if printf '%s\n' "$out" | grep -q -E "$planted"; then
      echo "FAIL $name: the output repeats the matched text: $out"; failures=$((failures + 1)); return
    fi
    echo "ok   $name"
  }
  run_case "a clean tree passes" none 'true'
  run_case "placeholders pass" none 'printf "%s\n" "/home/me/x" "C:\\Users\\me\\x" "TEAM000000.org.example.app" "00000000-0000000000000000" > p.txt'
  run_case "a Windows home path" local-path "printf '%s\n' '$win' > a.txt"
  run_case "a Linux home path" local-path "printf '%s\n' '$nix' > a.txt"
  run_case "a Stripe-shaped key" key-shape "printf '%s\n' '$key' > a.txt"
  run_case "a private key block" key-shape "printf '%s\n' '$pem' > a.txt"
  run_case "a team-ID bundle ID" team-id-shape "printf '%s\n' '$team' > a.txt"
  run_case "a device UDID" team-id-shape "printf '%s\n' '$udid' > a.txt"
  run_case "a key file" secret-file "touch AuthKey_ABCDE12345.p8"
  run_case "a commit text: Generated with a tool" commit-text 'true'
  run_case "a forbidden term in a file" forbidden-term "printf '%s\n' 'see $term for details' > a.txt" "$term"
  run_case "a forbidden term in a path" forbidden-term "touch notes-$term.md" "$term"
  run_case "a forbidden term in a commit" forbidden-term 'true' "test"
  rm -rf "$tmp"
  if [ "$failures" -eq 0 ]; then echo "self-test passed"; else echo "self-test: $failures failure(s)"; return 1; fi
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  --base) range="${2:?--base needs a ref}..HEAD" ;;
  --history) range="--all" ;;
  "") range="-n 1 HEAD" ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

scan_files
scan_terms
scan_commits "$range"
if [ "$found" -ne 0 ]; then
  echo "hygiene scan failed: see the places above (the matched text is not printed)"
  exit 1
fi
echo "hygiene scan passed"
