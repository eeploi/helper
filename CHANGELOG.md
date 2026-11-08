# Changelog

All notable changes to eeploi-helper. Versions follow [semver](https://semver.org): a removed or changed subcommand is a major release, a new subcommand a minor one.

## 1.0.0 (2026-11-08)

First public release. The helper moves out of eeploi.com into this repo.

Subcommands:

- `version`
- `nginx-test`, `nginx-reload`
- `php-fpm-reload`, `php-pool-write` (new)
- `vhost-write`, `vhost-read`, `vhost-enable`, `vhost-disable`, `vhost-remove`
- `vhost-set-root`, `vhost-set-cert`, `vhost-set-socket` (new)
- `ssl-csr`, `ssl-write`, `ssl-remove`, `ssl-read`, `ssl-include-write`
- `supervisor-write`, `supervisor-remove`, `supervisor-remove-site`, `supervisor-pause`, `supervisor-resume`, `supervisor-update`
- `cron-write`, `cron-remove`, `crontab-backup`, `crontab-restore`, `crontab-remove-lines`
- `env-install`, `storage-copy`
- `firewall-close-22`
- `acl-nginx` (new), installs the `acl` package when `setfacl` is missing
- `self-update` (new)

Changes from the helper built into eeploi.com:

- `version` prints the release version (`1.0.0`) instead of `1`.
- One file for every server. The deploy user comes from `/etc/eeploi/helper.conf`, not from a build step.
- `firewall-close-22` is always in the file, but only runs when `/etc/eeploi/new-server` exists.
