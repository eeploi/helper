#!/usr/bin/env bash
# tests/decisions.sh [<folder>]: DECISIONS.md and the D-n comments in the code agree, in this repo or in
# the copy in <folder>. The headings are "## For reviewers and audits", "## How entries work", then
# "## D-n: title" for D-1, D-2 … in order, each once. A Where line names files only, never Markdown.
# Every file an entry's Where names has a comment "# D-n: …" for it, and every such comment, in a file
# git tracks (every file but .git in a copy that is no repo), names an entry whose Where names that
# file. A D-n mentioned any other way isn't a comment for it. tests/run.sh runs it.
set -uo pipefail
export LC_ALL=C
cd "${1:-$(dirname "$0")/..}" || exit 1

[ -f DECISIONS.md ] || { echo "no DECISIONS.md"; exit 1; }

fail=0
bad() { echo "$1: $2"; fail=1; }
# A comment for a decision: "# D-n:" at the start of a line or after a space. $1 is the D-n, or a pattern.
marker() { printf '(^|[[:space:]])# %s:' "$1"; }

# DECISIONS.md, line by line: each heading in its place, and each entry's Where, as " D-n:file" words.
# After a number out of order, the count goes on from that number, so one slip is one message.
intro=('## For reviewers and audits' '## How entries work')
entry_re='^## (D-([1-9][0-9]*)): [^ ]'
# shellcheck disable=SC2016 # the backticks are Markdown
where_re='^- \*\*Where:\*\* `[^`]+`(, `[^`]+`)*$'
i=0 n=0 no=0 id='' ids=' ' where=' '
set -f # the paths in a Where line are words, never globs
# shellcheck disable=SC2094 # bad() only prints
while IFS= read -r text || [ -n "$text" ]; do
  no=$((no + 1))
  case "$text" in
    '##'*)
      id=''
      if [ $i -lt ${#intro[@]} ]; then
        [ "$text" = "${intro[i]}" ] || bad "DECISIONS.md:$no" "not ${intro[i]}, heading $((i + 1))"
        i=$((i + 1))
      elif ! [[ $text =~ $entry_re ]]; then
        bad "DECISIONS.md:$no" "not a heading ## D-n: title"
      else
        id=${BASH_REMATCH[1]}
        n=$((n + 1))
        [ "$id" = "D-$n" ] || { bad DECISIONS.md "$id where D-$n comes"; n=${BASH_REMATCH[2]}; }
        ids="$ids$id "
      fi ;;
    '- **Where:**'*)
      if [ -z "$id" ]; then
        bad "DECISIONS.md:$no" "a Where outside an entry"
      elif ! [[ $text =~ $where_re ]]; then
        bad "DECISIONS.md:$no" "not a Where line: \`file\`, \`file\` …"
      else
        for file in ${text#- \*\*Where:\*\* }; do
          file=${file//[\`,]/}
          case "$file" in *.md) bad DECISIONS.md "$id: Where names $file, but Markdown isn't read for comments"; continue ;; esac
          where="$where$id:$file "
        done
      fi ;;
  esac
done < DECISIONS.md
set +f
[ $i -eq ${#intro[@]} ] || bad DECISIONS.md "no heading ${intro[i]}"

# Every file a Where names has its D-n in a comment.
for pair in $where; do
  id=${pair%%:*} file=${pair#*:}
  [ -f "$file" ] || { bad DECISIONS.md "$id: Where names $file, which does not exist"; continue; }
  grep -qE "$(marker "$id")" "$file" || bad "$file" "has no $id comment, which DECISIONS.md names it for"
done

# Every comment for a decision, each on a line, names an entry, and that entry's Where names the file.
if [ -e .git ]; then
  files=$(git ls-files) || { echo "cannot list the files git tracks"; exit 1; }
else
  files=$(find . -type f ! -path './.git/*' | sed 's|^\./||')
fi
id_re=$(marker '(D-[0-9]+)')
while IFS=: read -r file line text; do
  while [[ $text =~ $id_re ]]; do
    id=${BASH_REMATCH[2]}
    text=${text#*"${BASH_REMATCH[0]}"}
    case "$ids" in *" $id "*) ;; *) bad "$file:$line" "$id is not in DECISIONS.md"; continue ;; esac
    case "$where" in *" $id:$file "*) ;; *) bad "$file:$line" "$id's Where doesn't name $file" ;; esac
  done
done < <(grep -v '\.md$' <<< "$files" | tr '\n' '\0' | xargs -0 grep -HnIE "$(marker 'D-[0-9]+')" /dev/null || true)

[ "$fail" -eq 0 ] && echo "decisions ok"
exit "$fail"
