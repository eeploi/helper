#!/usr/bin/env bash
# tests/decisions.sh [<folder>]: DECISIONS.md and the D-n comments in the code agree, in this repo or in
# the copy in <folder>. The headings are "## For reviewers and audits", "## How entries work", then
# "## D-n: title" for D-1, D-2 … in order, each once. Every file an entry's Where names has a comment
# "# D-n: …" with its D-n, and every such comment in a file of the repo (but .git and Markdown) names an
# entry. A D-n mentioned any other way isn't a comment for it. tests/run.sh runs it.
set -uo pipefail
export LC_ALL=C
cd "${1:-$(dirname "$0")/..}" || exit 1

[ -f DECISIONS.md ] || { echo "no DECISIONS.md"; exit 1; }

fail=0
bad() { echo "$1: $2"; fail=1; }
# A comment for a decision: "# D-n:" at the start of a line or after a space. $1 is the D-n, or a pattern.
marker() { printf '(^|[[:space:]])# %s:' "$1"; }

# Each heading in its place. After a number out of order, the count goes on from that number, so one
# slip is one message.
intro=('## For reviewers and audits' '## How entries work')
entry_re='^## (D-([0-9]+)): [^ ]'
i=0 n=0 ids=' '
while IFS=: read -r line text; do
  if [ $i -lt ${#intro[@]} ]; then
    [ "$text" = "${intro[i]}" ] || bad "DECISIONS.md:$line" "not ${intro[i]}, heading $((i + 1))"
    i=$((i + 1))
    continue
  fi
  if ! [[ $text =~ $entry_re ]]; then
    bad "DECISIONS.md:$line" "not a heading ## D-n: title"
    continue
  fi
  n=$((n + 1))
  [ "${BASH_REMATCH[1]}" = "D-$n" ] || { bad DECISIONS.md "${BASH_REMATCH[1]} where D-$n comes"; n=${BASH_REMATCH[2]}; }
  ids="$ids${BASH_REMATCH[1]} "
done < <(grep -nE '^##' DECISIONS.md)
[ $i -eq ${#intro[@]} ] || bad DECISIONS.md "no heading ${intro[i]}"

# Every file a Where names has its D-n in a comment.
while read -r id file; do
  [ -f "$file" ] || { bad DECISIONS.md "$id: Where names $file, which does not exist"; continue; }
  grep -qE "$(marker "$id")" "$file" || bad "$file" "has no $id comment, which DECISIONS.md names it for"
done < <(awk '/^## D-[0-9]+: / { id = substr($2, 1, length($2) - 1) }
  /^- \*\*Where:\*\* / { n = split($0, f, "`"); for (i = 2; i <= n; i += 2) print id, f[i] }' DECISIONS.md)

# Every comment for a decision names an entry. Files, not git: the copy tests/run.sh checks is no repo.
id_re=$(marker '(D-[0-9]+)')
while IFS=: read -r file line text; do
  [[ $text =~ $id_re ]] || continue
  case "$ids" in *" ${BASH_REMATCH[2]} "*) ;; *) bad "${file#./}:$line" "${BASH_REMATCH[2]} is not in DECISIONS.md" ;; esac
done < <(grep -rnIE --exclude='*.md' --exclude-dir=.git "$(marker 'D-[0-9]+')" . || true)

[ "$fail" -eq 0 ] && echo "decisions ok"
exit "$fail"
