#!/usr/bin/env bash
#
# preflight.sh - run the upstream-relevant CI checks locally before you push.
#
# Mirrors the checks from .github/workflows/verify.yml and lint.yml that are
# actually your code's responsibility (rspec, msftidy, encoding, rubocop,
# zeitwerk, schema), scoped to your branch's diff so it is fast. It does NOT
# run the native acceptance jobs (windows_meterpreter, mettle, ldap/postgres
# acceptance) - those run only in the cloud and are the flaky ones a fork
# cannot reproduce.
#
# Usage:
#   tools/dev/preflight.sh               # diff-scoped checks vs upstream/master
#   tools/dev/preflight.sh --full        # run the ENTIRE rspec suite (like CI)
#   tools/dev/preflight.sh --base BRANCH # compare against a different base ref
#   tools/dev/preflight.sh --no-rspec    # skip rspec (lint/rubocop/tidy only)
#   tools/dev/preflight.sh --install-hook # symlink this script into .git/hooks
#
# Activation follows the same convention as tools/dev/pre-commit-hook.rb: this
# script is a tracked repo file, and you symlink it into .git/hooks so it runs
# against whatever is checked out in your working tree. --install-hook does the
# symlinks for you, or do it by hand (like the msftidy hook):
#
#   ln -sf ../../tools/dev/preflight.sh .git/hooks/pre-push
#   ln -sf ../../tools/dev/preflight.sh .git/hooks/pre-commit
#   ln -sf ../../tools/dev/preflight.sh .git/hooks/post-merge
#
# When invoked as a git hook the script keys off its name ($0): pre-commit and
# post-merge run the fast checks (no rspec, matching the lightweight msftidy
# hook), while pre-push runs the full diff-scoped suite. Bypass a push with
# 'git push --no-verify'.
#
# Exit code is non-zero if any check fails, so it is safe to gate a push on it.
# Written to run on stock macOS bash 3.2 as well as modern bash.

set -o pipefail

cd "$(git rev-parse --show-toplevel)" || { echo "not in a git repo"; exit 2; }

FULL=0
RUN_RSPEC=1
INSTALL_HOOK=0
BASE=""
expect_base=0
for arg in "$@"; do
  if [ "$expect_base" = "1" ]; then BASE="$arg"; expect_base=0; continue; fi
  case "$arg" in
    --full) FULL=1 ;;
    --no-rspec) RUN_RSPEC=0 ;;
    --base) expect_base=1 ;;
    --install-hook) INSTALL_HOOK=1 ;;
  esac
done

# When run as a git hook (symlinked into .git/hooks), key off the hook name the
# same way tools/dev/pre-commit-hook.rb does. Keep commit/merge-time checks fast.
HOOK_NAME="$(basename "$0" 2>/dev/null)"
case "$HOOK_NAME" in
  pre-commit|post-merge) RUN_RSPEC=0 ;;
esac

# ---- hook installer (rapid7-style symlinks) ---------------------------------
if [ "$INSTALL_HOOK" = "1" ]; then
  mkdir -p .git/hooks
  for h in pre-push pre-commit post-merge; do
    ln -sf ../../tools/dev/preflight.sh ".git/hooks/$h"
  done
  chmod +x tools/dev/preflight.sh 2>/dev/null
  echo "Symlinked tools/dev/preflight.sh into .git/hooks (pre-push, pre-commit, post-merge)."
  echo "Like the msftidy hook, this runs against your working tree, so it only"
  echo "fires on branches where tools/dev/preflight.sh is checked out."
  echo "Bypass a single push/commit with --no-verify."
  exit 0
fi

# ---- figure out the base ref -------------------------------------------------
if [ -z "$BASE" ]; then
  for cand in upstream/master origin/master master; do
    if git rev-parse --verify --quiet "$cand" >/dev/null; then BASE="$cand"; break; fi
  done
fi
MERGE_BASE="$(git merge-base "$BASE" HEAD 2>/dev/null || echo "$BASE")"

# ---- collect changed files (committed-since-base + staged + unstaged) --------
CHANGED=()
while IFS= read -r line; do
  [ -n "$line" ] && CHANGED+=("$line")
done < <(
  {
    git diff --name-only "$MERGE_BASE"...HEAD 2>/dev/null
    git diff --name-only HEAD 2>/dev/null
    git diff --name-only --cached 2>/dev/null
  } | sort -u
)

CHANGED_RB=()
CHANGED_MODULES=()
SPECS=()
for f in "${CHANGED[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.rb) CHANGED_RB+=("$f") ;;
  esac
  case "$f" in
    modules/*.rb) CHANGED_MODULES+=("$f") ;;
  esac
  # map file -> its spec, and pick up changed spec files directly
  case "$f" in
    spec/*_spec.rb) SPECS+=("$f") ;;
    lib/*.rb)  s="spec/${f#lib/}"; s="${s%.rb}_spec.rb"; [ -f "$s" ] && SPECS+=("$s") ;;
    modules/*.rb) s="spec/${f%.rb}_spec.rb"; [ -f "$s" ] && SPECS+=("$s") ;;
  esac
done
# always include the zeitwerk compliance guard
[ -f spec/zeitwerk_compliance_spec.rb ] && SPECS+=("spec/zeitwerk_compliance_spec.rb")
# de-dupe SPECS
if [ "${#SPECS[@]}" -gt 0 ]; then
  UNIQ=()
  while IFS= read -r line; do [ -n "$line" ] && UNIQ+=("$line"); done < <(printf '%s\n' "${SPECS[@]}" | sort -u)
  SPECS=("${UNIQ[@]}")
fi

echo "preflight: base=$BASE  changed=${#CHANGED[@]}  (.rb=${#CHANGED_RB[@]}, modules=${#CHANGED_MODULES[@]}, specs=${#SPECS[@]})"
echo

# ---- check runner ------------------------------------------------------------
NAMES=()
STATES=()
FAIL=0
run_check() {
  name="$1"; shift
  printf '  … %s\n' "$name"
  if "$@" >/tmp/preflight_last.log 2>&1; then
    NAMES+=("$name"); STATES+=("PASS")
  else
    NAMES+=("$name"); STATES+=("FAIL"); FAIL=1
    echo "    ---- output (tail) ----"
    tail -n 25 /tmp/preflight_last.log | sed 's/^/    /'
    echo "    -----------------------"
  fi
}
skip_check() { NAMES+=("$1"); STATES+=("SKIP"); printf '  - %s (skipped: %s)\n' "$1" "$2"; }
# INFO check: run it and surface output, but never fail the board on it.
info_check() {
  name="$1"; shift
  printf '  … %s\n' "$name"
  "$@" >/tmp/preflight_last.log 2>&1
  NAMES+=("$name"); STATES+=("INFO")
  tail -n 4 /tmp/preflight_last.log | sed 's/^/      /'
}

# ---- 1. rubocop (changed .rb) - INFORMATIONAL -------------------------------
# Upstream gates module style via msftidy, not a repo-wide lib rubocop, and
# legacy lib files carry many pre-existing offenses. So this is advisory: it
# shows offenses in files you touched (useful for NEW code) without failing.
if [ "${#CHANGED_RB[@]}" -gt 0 ]; then
  info_check "rubocop (advisory, changed .rb)" bundle exec rubocop --force-exclusion --format simple "${CHANGED_RB[@]}"
else
  skip_check "rubocop" "no changed .rb files"
fi

# ---- 2. msftidy (changed modules) -------------------------------------------
if [ "${#CHANGED_MODULES[@]}" -gt 0 ]; then
  run_check "msftidy (changed modules)" ruby tools/dev/msftidy.rb "${CHANGED_MODULES[@]}"
else
  skip_check "msftidy" "no changed modules"
fi

# ---- 3. encoding verify ------------------------------------------------------
run_check "verify_encoding" bundle exec ruby tools/dev/verify_encoding.rb

# ---- 4. db/schema.rb committed ----------------------------------------------
run_check "db/schema.rb up to date" git diff --exit-code db/schema.rb

# ---- 5. rspec ----------------------------------------------------------------
if [ "$RUN_RSPEC" = "1" ]; then
  if [ "$FULL" = "1" ]; then
    run_check "rspec (full suite)" bundle exec rake rspec-rerun:spec
  elif [ "${#SPECS[@]}" -gt 0 ]; then
    run_check "rspec (diff-related, ${#SPECS[@]} files)" bundle exec rspec "${SPECS[@]}"
  else
    skip_check "rspec" "no specs map to the diff (use --full to run everything)"
  fi
else
  skip_check "rspec" "--no-rspec"
fi

# ---- board -------------------------------------------------------------------
echo
echo "================ preflight results ================"
i=0
while [ "$i" -lt "${#NAMES[@]}" ]; do
  case "${STATES[$i]}" in
    PASS) mark="✓ PASS" ;;
    FAIL) mark="✗ FAIL" ;;
    SKIP) mark="- SKIP" ;;
    INFO) mark="i INFO" ;;
  esac
  printf '  %-8s %s\n' "$mark" "${NAMES[$i]}"
  i=$((i + 1))
done
echo "==================================================="
if [ "$FAIL" = "1" ]; then
  echo "PREFLIGHT FAILED - fix the above before pushing (these checks are yours, not the flaky native jobs)."
  exit 1
fi
echo "PREFLIGHT PASSED - the upstream checks that are yours to fix are green."
echo "Note: native acceptance jobs (windows_meterpreter/mettle/ldap/postgres) run only in cloud CI, not here."
exit 0
