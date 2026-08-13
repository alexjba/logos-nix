#!/usr/bin/env bash
# Lint the shell that actually runs in CI.
#
# WHY THIS EXISTS: "actionlint clean" covers less than it sounds like.
#
#   * actionlint's default scope is `.github/workflows` ONLY. Measured with
#     actionlint 1.7.12 in this repo: bare `actionlint` exits 0 having linted
#     three workflow files; pointed at any of the three composite actions it
#     rejects them outright -- `"jobs" section is missing in workflow
#     [syntax-check]`, exit 1. So the three `action.yml` files, which is where
#     most of the shell in this design lives (8 of the 20 `run:` blocks, and
#     every gate), had NEVER been linted at all.
#
#   * actionlint substitutes a placeholder for `${{ }}` before handing a script
#     to shellcheck, so it is STRUCTURALLY incapable of catching
#     interpolation-into-shell -- the class that put `[ -z "${{ inputs.smoke }}" ]`
#     into an earlier revision of this design, lint-clean, where the first
#     caller whose smoke script contained a double quote turned a good build
#     red. A clean actionlint run is not evidence about that class. Rule (2)
#     below is, because it forbids the construct instead of trying to parse it.
#
# What this adds, over every workflow AND every composite action:
#   1. shellcheck on each `run:` block, actions included.
#   2. NO `${{ }}` inside any `run:` block. Caller data reaches a shell through
#      `env:` or not at all.
#   3. NO producer piped into an early-exiting consumer (`grep -q`, `grep -m`,
#      `head`, `read`). Under `set -euo pipefail` the producer is killed by
#      SIGPIPE and `pipefail` promotes 141 to the pipeline's status -- which is
#      a false red in a plain command and a SILENT PASS in an `if` condition.
#      Both shipped here, on adjacent lines of the .lgx gate; see the header of
#      .github/actions/windows-gates/action.yml for the measurements.
#
# Usage: .github/lint-actions.sh [--self-test]
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0

fail() { echo "::error file=$1,line=$2::$3"; rc=1; }

# Every `run:` in the repo, wherever it lives. Workflows keep theirs under
# .jobs[].steps[]; composite actions under .runs.steps[].
files() {
  find "$ROOT/.github" -type f \( -name '*.yml' -o -name '*.yaml' \) \
    | LC_ALL=C sort
}

lint_file() {
  local f rel n i line body shell
  f=$1; rel=${f#"$ROOT"/}
  # `..|select(has("run"))` finds run blocks under either layout without this
  # script having to know which kind of file it is looking at.
  #
  # A file yq CANNOT PARSE is an error, never "0 run blocks". The first draft
  # of this script had `2>/dev/null || echo 0` here, and it reported "clean"
  # on a tree containing a workflow with a YAML syntax error -- a linter
  # skipping the file it cannot read, which is the exact defect class this
  # whole design refuses. actionlint caught it; this line is why it had to.
  if ! n=$(yq '[.. | select(type == "!!map" and has("run"))] | length' "$f" 2>"$TMP/yqerr"); then
    fail "$rel" 1 "this file could not be parsed as YAML, so NOTHING in it was linted:"
    sed 's/^/::error::    /' "$TMP/yqerr"
    return 0
  fi
  [ "$n" -gt 0 ] || return 0
  for ((i = 0; i < n; i++)); do
    shell=$(yq "[.. | select(type == \"!!map\" and has(\"run\"))] | .[$i].shell // \"bash\"" "$f")
    line=$(yq "[.. | select(type == \"!!map\" and has(\"run\"))] | .[$i].run | line" "$f")
    body=$TMP/blk.sh
    yq "[.. | select(type == \"!!map\" and has(\"run\"))] | .[$i].run" "$f" > "$body"
    # Rules (2) and (3) are about CODE. A whole-line comment is blanked (not
    # deleted, so line numbers still line up) -- otherwise this linter fires on
    # the comments that explain the very patterns it forbids, which is how a
    # rule gets switched off for being noisy.
    sed 's/^[[:space:]]*#.*$//' "$body" > "$TMP/code.sh"
    # yq reports the line of the `run:` key; block content starts on the next.
    off=$((line))

    # (2) interpolation-into-shell. Checked BEFORE shellcheck, because this is
    # precisely the class shellcheck cannot be shown.
    if grep -nE '\$\{\{' "$TMP/code.sh" > "$TMP/hits"; then
      fail "$rel" "$line" "\`\${{ }}\` inside a run: block. GitHub substitutes it into the
script TEXT before bash sees it, so a value containing a quote breaks the
surrounding command and a value containing \$(...) executes on the runner.
Pass it through env: and reference it as a shell variable."
      while IFS=: read -r ln rest; do
        echo "::error::    $rel:$((off + ln)): $rest"
      done < "$TMP/hits"
    fi

    # (3) the SIGPIPE class.
    if grep -nE '\|[[:space:]]*(grep([[:space:]]+[^|]*)?[[:space:]]+-[a-zA-Z]*q|grep[^|]*-m[[:space:]]*[0-9]|head([[:space:]]|$)|read([[:space:]]|$))' \
         "$TMP/code.sh" > "$TMP/hits"; then
      fail "$rel" "$line" "a producer is piped into a consumer that exits early.
Under \`set -euo pipefail\` the producer is killed by SIGPIPE (141) and pipefail
promotes that to the pipeline's status: a false red in a plain command, and a
SILENT PASS when the pipeline is an \`if\` condition. Capture, then test --
  names=\$(tar tzf \"\$f\"); grep -q PATTERN <<<\"\$names\"
For a truncated diagnostic use \`sed -n '1,Np'\`, which reads to EOF."
      while IFS=: read -r ln rest; do
        echo "::error::    $rel:$((off + ln)): $rest"
      done < "$TMP/hits"
    fi

    # (1) shellcheck, for anything that is a POSIX-family shell.
    case "$shell" in
      bash|sh|bash*|'bash -e'*)
        { echo '#!/usr/bin/env bash'; cat "$body"; } > "$TMP/sc.sh"
        if ! out=$(shellcheck -s bash --color=never "$TMP/sc.sh" 2>&1); then
          fail "$rel" "$line" "shellcheck findings in this run: block"
          printf '%s\n' "$out" | sed 's/^/::error::    /'
        fi ;;
      *) ;;                       # pwsh/python etc: not our business
    esac
  done
}

# --self-test proves the rules FIRE. A lint nobody has watched fail is a lint
# nobody knows is wired up -- which is how the three action.yml files went
# unlinted while "actionlint is clean" was true.
if [ "${1:-}" = --self-test ]; then
  mkdir -p "$TMP/.github/actions/bad"
  cat > "$TMP/.github/actions/bad/action.yml" <<'YAML'
name: deliberately bad
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        set -euo pipefail
        tar tzf "$F" | grep -q '^variants/windows-x86_64/'
    - shell: bash
      run: |
        set -euo pipefail
        if [ -z "${{ inputs.smoke }}" ]; then echo no; fi
    - shell: bash
      run: |
        set -euo pipefail
        if [ $UNQUOTED == x ]; then echo hi; fi
YAML
  ROOT=$TMP
  echo "--- self-test: three deliberately broken run: blocks ---"
  lint_file "$TMP/.github/actions/bad/action.yml"
  if [ "$rc" -ne 0 ]; then echo "--- self-test PASSED: all three rules fired ---"; exit 0; fi
  echo "::error::self-test FAILED: the linter accepted a file that breaks every rule."
  exit 1
fi

while read -r f; do lint_file "$f"; done < <(files)
[ "$rc" -eq 0 ] && echo "lint-actions: clean ($(files | wc -l | tr -d ' ') files)"
exit "$rc"
