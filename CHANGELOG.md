# Changelog

All notable changes to eeploi-helper. Versions follow [semver](https://semver.org): a removed or changed subcommand is a major release, a new subcommand a minor one.

## 1.0.1 (2026-11-13)

- `db-create` with password login on MySQL and MariaDB makes the user on `127.0.0.1` too, with the same password and grant, so Laravel's default `DB_HOST=127.0.0.1` works without a name lookup. A 1.0.0 user on `localhost` only gets its `127.0.0.1` user on the next run, with the password on stdin. Socket login and Postgres are unchanged. Refused: a user on `127.0.0.1` for socket login, and one on `127.0.0.1` without one on `localhost`.

## 1.0.0, files replaced (2026-11-10)

- New subcommand `db-create <engine> <name> <user> <socket|password>` (a minor release): creates a MySQL, MariaDB or Postgres database and its user for a new site. The user gets that one database and no global rights. Two ways in, named by the required fourth argument:
  - `socket`: socket login as the Unix user of the same name, with no password at all (Postgres peer auth, MariaDB `unix_socket`, MySQL `auth_socket`). Stdin is never read. The Unix user must exist and be a site's own user. On MySQL the `auth_socket` plugin is installed when it is not active.
  - `password`: password login, with the password on stdin. A missing or invalid password, or a terminal, is refused; it never falls back to socket login. The password is never printed, logged or on a command line.
  - Names are `a-z`, `0-9` and `_` only, so a site user like `shop_example` needs no quoting.
  - Both already there with the same way in is a no-op. A database or user someone else has, and a user with the other way in, are refused. The system log gets the engine, name, user and login, never the password.
- Fixes from the second helper audit (2026-11-10):
  - `env-install` only copies a file named `.env`, and `storage-copy` only a folder named `storage`: the source must end in `/.env` or `/storage`, also after resolving links. Anything else is refused.
  - `self-update` only installs a strictly newer version. The same version is now refused too.
  - `ssl-csr` makes the private key with mode `600` from the start.
  - The helper sets `HOME=/root` and `LC_ALL=C` itself, and `self-update` runs `curl -q`, so no curlrc is read.
- Every call except `version` goes to the system log (`logger -t eeploi-helper`): the caller, the subcommand and its arguments, never stdin. A dry run prints the line on stderr. Not yet: the timeline event id.

## 1.0.0 (2026-11-08)

First public release. The helper moves out of eeploi.com into this repo.

Subcommands:

- `version`
- `nginx-test`, `nginx-reload`
- `php-fpm-reload`, `php-pool-write` (new)
- `vhost-write`, `vhost-backup`, `vhost-restore`, `vhost-enable`, `vhost-disable`, `vhost-remove`
- `vhost-set-root`, `vhost-set-cert`, `vhost-set-socket` (new)
- `ssl-csr`, `ssl-write`, `ssl-remove`
- `supervisor-write`, `supervisor-remove`, `supervisor-remove-site`, `supervisor-pause`, `supervisor-resume`, `supervisor-update`
- `cron-write`, `cron-remove`, `crontab-remove-lines`, `crontab-restore`
- `env-install`, `storage-copy`
- `firewall-close-22`
- `acl-nginx` (new), installs the `acl` package when `setfacl` is missing
- `self-update` (new)

Changes from the helper built into eeploi.com:

- `version` prints the release version (`1.0.0`) instead of `1`.
- One file for every server. The deploy user comes from `/etc/eeploi/helper.conf`, not from a build step.
- `firewall-close-22` is always in the file, but only runs when `/etc/eeploi/new-server` exists.

Security fixes before release (server-access audit, 2026-11-09):

- `vhost-write <domain> <socket>` builds the vhost itself; it no longer takes a config on stdin. Logs go to `/var/log/nginx`.
- `vhost-backup` and `vhost-restore` replace `vhost-read`, `ssl-read` and `ssl-include-write` for take-overs. The backup stays root-only.
- `supervisor-write <program> <directory> <processes>` builds the config itself from a one-line command. Logs go to `/var/log/supervisor`.
- `env-install` and `storage-copy` only read from `/home/ploi` or `/home/forge`, and the caller writes the copy, never root.
- `crontab-remove-lines <domain>` only removes `ploi` or `forge` jobs in their home and keeps them; `crontab-restore` adds just those back. `crontab-backup` is gone.
- `ssl-write` only accepts one PEM certificate.
- `self-update` refuses an older version.
