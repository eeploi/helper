# Decisions

Choices made on purpose, and the risks and limits accepted with them, so an audit can tell a choice from a mistake.

## For reviewers and audits

- Read this file first.
- A finding against an entry here is not a bug. Report it as "challenges D-n", with an argument the entry doesn't already answer.
- A rejected audit finding becomes a new entry, so the next audit doesn't raise it again.
- Anything that could be a vulnerability, an entry here included, goes through the [security policy](.github/SECURITY.md), not a public issue.

## How entries work

- One entry per decision, numbered `D-1`, `D-2` and so on. A number is never reused or renumbered.
- **Kind** is `decision`, `accepted risk` or `known limit`.
- **Accepted**, when present, names what a decision costs.
- **Decided** gives the date and the issue or pull request in this repo.
- **Where** names the files the entry shapes, if any. The line it shapes carries a comment `# D-n: …`. `tests/decisions.sh`, which `tests/run.sh` runs, fails on a `D-n` comment without an entry here or in a file its **Where** doesn't name, on a file in **Where** without its comment, and on a heading or **Where** line out of place, out of order or malformed. **Where** names files in backticks, never Markdown.
- A changed decision is a new entry. The old one stays, with **Replaced by** `D-n`.
- No private details: no server names, addresses or business reasons. Only what explains the code.

## D-1: Fixed subcommands, no free arguments

- **Kind:** decision
- **Decided:** 2026-11-08, 1.0.0
- **What:** the helper has a fixed list of subcommands. Each checks every argument against a strict pattern and does one fixed thing. No subcommand takes a command, a path to run or a config file to install as root. Files a root service reads (vhosts, pools, Supervisor and cron files, Redis units and configs) are built by the helper from checked arguments. Only a certificate, a worker command, a cron line, a database password and the script for `run-as` come on stdin, each checked; the worker command and the script run as a site user, never as root.
- **Why:** every line that runs as root can be read in this repo. The caller is held to what eeploi needs, and anything else is refused.
- **Where:** `eeploi-helper`

## D-2: Only the deploy user, through one sudo rule

- **Kind:** decision
- **Decided:** 2026-11-15, PR #14
- **What:** the helper runs only through sudo, with `SUDO_USER` the deploy user (`eeploi`, or `DEPLOY_USER` in `/etc/eeploi/helper.conf`, never `root`). The sudo rule names the helper's path and nothing else. Other users, the panels' users among them, are refused for every subcommand.
- **Why:** one caller, one rule. Before 1.0.2 the panels' users could call the subcommands that take no site user; nothing eeploi does needs that.
- **Where:** `eeploi-helper`

## D-3: A fixed environment

- **Kind:** decision
- **Decided:** 2026-11-10, PR #4; 2026-11-17, PR #16
- **What:** the first line is `#!/bin/bash`. The helper sets `PATH`, `HOME` (`/root`), `TMPDIR`, `LC_ALL=C` and the umask itself, and `curl` runs with `-q`, so it reads no curlrc.
- **Why:** nothing the caller sets in its environment or home changes what root runs.
- **Where:** `eeploi-helper`

## D-4: Root reads and runs only files root alone can change

- **Kind:** decision
- **Decided:** 2026-11-17, PR #16
- **What:** a file the helper reads (its config, the site registry, `recipes.conf`, the recipes state, the new-server marker) must be a root-owned file, no link, not writable by group or others, in a folder that is the same. Otherwise the call is refused. `/etc/os-release` is a link on Ubuntu: the helper follows it, and the file it points to must pass the same check.
- **Why:** a file another user can change would let that user steer root.
- **Where:** `eeploi-helper`

## D-5: Files are parsed line by line, never sourced

- **Kind:** decision
- **Decided:** 2026-11-08, 1.0.0; PR #14, PR #19
- **What:** `helper.conf`, the registry, `recipes.conf`, `os-release` and the recipes state are read one line at a time, and nothing in them is run. Each line must match a known form, and a value that may be set once is refused when set twice. In `os-release` only the `ID` and `VERSION_ID` lines are read; the others are skipped.
- **Why:** a sourced file runs as root whatever it holds. A parsed one gives only the values it may give.
- **Where:** `eeploi-helper`

## D-6: What a vhost makes nginx read stays in /etc/nginx, root's alone

- **Kind:** decision
- **Decided:** 2026-11-17, PR #16, PR #17
- **What:** before `vhost-set-root` and `vhost-set-socket` change a vhost, every `include` in it, and in what it includes, and every file an `ssl_` or `auth_` directive names, must be in `/etc/nginx`, and that file and every folder up to there root-owned and not writable by group or others. The directives are matched by pattern, so one nginx adds later counts too. There is no exception for certbot's `/etc/letsencrypt`: eeploi uses its own certificates, in `/etc/nginx/ssl`.
- **Why:** nginx's root process reads these files. One a site user controls can make `nginx -t` fail, and with it every site's reload.
- **Accepted:** a site whose certificate is outside `/etc/nginx` is refused until its certificate moves to `/etc/nginx/ssl` (`ssl-write`, `vhost-set-cert`), so a take-over does that first. A site with basic auth outside `/etc/nginx` is refused.
- **Where:** `eeploi-helper`

## D-7: nginx's log folder stays root's alone

- **Kind:** decision
- **Decided:** 2026-11-17, PR #17
- **What:** every `access_log` and `error_log` in a vhost must be in `/var/log/nginx`, no link, and that folder root-owned and not writable by group or others. A folder owned by nginx's user is refused, also when nobody else can write to it.
- **Why:** the folder's owner can swap a log for a link, and nginx's root process writes where it points on the next reload (CVE-2016-1247). Debian and Ubuntu give the folder to root since that fix.
- **Where:** `eeploi-helper`

## D-8: No temp or cache paths, or script modules, in a vhost

- **Kind:** decision
- **Decided:** 2026-11-17, PR #17
- **What:** a vhost, or a file it includes, with any `*_temp_path` or `*_cache_path`, or with an njs, Perl, XSLT, GeoIP or Lua directive, is refused.
- **Why:** nginx's root process makes the temp and cache folders and gives them to nginx's user, also a folder that is already there, so the root-owned rule can't hold for them. It loads the modules' code and data as root. eeploi needs none of them.
- **Accepted:** a site with a FastCGI cache path in its vhost can't be taken over until that line goes.
- **Where:** `eeploi-helper`

## D-9: A vhost line the check could read otherwise than nginx is refused

- **Kind:** known limit
- **Decided:** 2026-11-17, PR #16, PR #17
- **What:** the vhost check doesn't parse quotes. A line with a quote and a `#`, an open quote, or a `#` inside a word is refused, and so, when `vhost-set-root` places `disable_symlinks`, is a line with a quote and a `{` or `}`. A path in one pair of quotes, with no other quote, is read without them.
- **Why:** a full nginx parser in bash is more code that runs as root. Refusing what it can't read keeps the check from passing a line nginx reads another way. Vhosts eeploi writes or takes over don't need such lines.
- **Where:** `eeploi-helper`

## D-10: releases-own walks once and leaves hard links alone

- **Kind:** decision
- **Decided:** 2026-11-17, PR #17
- **What:** `releases-own` runs one `find -depth … -execdir chown -h` from inside the site's folder, and only with `fs.protected_hardlinks` on. It hands back only folders and single-link files that root or the deploy user owns. A link is changed itself, never followed.
- **Why:** root never follows a path the site user could swap while the walk runs.
- **Accepted:** a few seconds per deploy, with one `chown` per folder that has files to hand back. A hard-linked file in a release stays with root or the deploy user.
- **Where:** `eeploi-helper`

## D-11: Every call goes to the system log, never stdin

- **Kind:** decision
- **Decided:** 2026-11-10, PR #1
- **What:** each call but `version` logs the caller, the subcommand and its arguments. What comes on stdin (a certificate, a command, a password, a script) is never logged.
- **Why:** a record of what root did, without secrets in it. The arguments are checked and hold none.
- **Where:** `eeploi-helper`

## D-12: The dry run is switched on from the environment

- **Kind:** accepted risk
- **Decided:** 2026-11-08, 1.0.0
- **What:** `EEPLOI_HELPER_DRY_RUN` and the test overrides (`EEPLOI_HELPER_ETC` and the others) are read from the environment. The overrides count only in a dry run.
- **Why:** the tests run the real file, not a copy made for them. sudo's default `env_reset` drops these variables, and the sudo rule for the helper keeps that default.
- **Where:** `eeploi-helper`

## D-13: Prehashed signatures only

- **Kind:** decision
- **Decided:** 2026-11-21, PR #22
- **What:** `self-update`, `recipe-run` and `bin/release` check signatures with `minisign -V -H`, so only a prehashed signature (`ED`, minisign's default) is accepted. A legacy one (`Ed`) is refused.
- **Why:** one signature format on every server and in every check. The recipes repo applies the same rule.
- **Where:** `eeploi-helper`, `bin/release`

## D-14: Releases are signed in the maintainer's own terminal

- **Kind:** decision
- **Decided:** 2026-11-10, PR #5; 2026-11-20, PR #18
- **What:** `bin/release` signs only in an interactive terminal, where the maintainer types the key's password. CI and scripts never sign. The secret key stays offline, never on GitHub or a server.
- **Why:** a hacked server or GitHub account still can't ship a helper a server accepts. Each release needs a person.
- **Where:** `bin/release`

## D-15: A version tag can move while eeploi is in development

- **Kind:** decision
- **Decided:** 2026-11-10, PR #5
- **What:** when the same version is released again, `bin/release` says so and moves the `v<version>` tag to the checked commit, then replaces the release files.
- **Why:** while eeploi is in development, a release can be signed again with a fix and keep its version. The signature and the SHA-256 that callers pin follow the file, not the tag.
- **Accepted:** a version number alone doesn't name one file; the signature or SHA-256 does.
- **Where:** `bin/release`

## D-16: self-update installs only a newer version

- **Kind:** decision
- **Decided:** 2026-11-10, PR #4
- **What:** `self-update` refuses the installed version and any older one, compared by number (`1.0.10` is newer than `1.0.9`).
- **Why:** an older release may have a bug a newer one fixed, and going back would bring it again.
- **Accepted:** the same version again is installed by hand, as in the README's Install by hand.
- **Where:** `eeploi-helper`

## D-17: The recipes key is its own

- **Kind:** decision
- **Decided:** 2026-11-20, PR #19
- **What:** recipes releases are checked with `RECIPES_PUBKEY`, built into the helper and apart from the helper's own release key (`PUBKEY`). Neither key verifies the other's releases.
- **Why:** a key that signs one thing can't be used for the other. The recipes can change on their own schedule without touching the helper's key.
- **Where:** `eeploi-helper`

## D-18: recipe-run checks the signature first and caps every size

- **Kind:** decision
- **Decided:** 2026-11-20, PR #19; 2026-11-21, #20 (PR #21)
- **What:** `recipe-run` downloads the manifest and its `.minisig` first, and nothing else is downloaded or read before the signature checks out. The package is never unpacked as it is: each file the manifest lists is read out of it on its own and must match its SHA-256. Sizes are capped: the manifest 64 KB, the signature 4 KB, the package 4 MB, 8 MB unzipped, 200 files, each file 1 MB while it is read.
- **Why:** nothing unsigned is parsed as root, a release can't fill the disk, and only the files the signed manifest lists are read.
- **Where:** `eeploi-helper`

## D-19: recipe-run refuses an older release

- **Kind:** decision
- **Decided:** 2026-11-20, PR #19
- **What:** a recipes release older than the last one that ran well on the server is refused. The same release may run again.
- **Why:** an older signed release may undo a fix. Running the same one again puts a server back that drifted.
- **Where:** `eeploi-helper`

## D-20: recipe-run takes its values from the server

- **Kind:** decision
- **Decided:** 2026-11-20, PR #19
- **What:** the values the steps use come from the root-owned `/etc/eeploi/recipes.conf` (`DEPLOY_USER`, `SSH_PORT`, `PHP`) and `os-release`, never from the caller, which names only the release and the provider. The files that run may hold no placeholder but `{user}`, `{port}`, `{php}`, `{version}` and `{name}`, and those never in bash's own braces.
- **Why:** a caller can't make a signed step run with another user, port or PHP than the server's own.
- **Where:** `eeploi-helper`

## D-21: Paths and provider names follow the recipes repo's rule

- **Kind:** decision
- **Decided:** 2026-11-20, PR #19
- **What:** a path in a recipes release is relative, each part `[A-Za-z0-9_][A-Za-z0-9._-]*`, so no empty part and no part that starts with `.` or `-`. A provider is `a-z`, `0-9` and inner `-`, at most 32. The recipes repo builds its releases by these same rules, and its CI fails when its provider rule differs from the helper's.
- **Why:** a release the recipes repo builds is never one the helper refuses, and a path can't leave the work folder.
- **Where:** `eeploi-helper`

## D-22: recipe-run refuses a server without recipes.conf

- **Kind:** known limit
- **Decided:** 2026-11-20, PR #19
- **What:** a server built before the recipes wrote `/etc/eeploi/recipes.conf`, or one eeploi took over, has no such file, and `recipe-run` refuses it.
- **Why:** without the server's own values no step can run safely, and the helper doesn't guess them.
- **Where:** `eeploi-helper`

## D-23: firewall-close-22 only on a server eeploi created

- **Kind:** decision
- **Decided:** 2026-11-08, 1.0.0
- **What:** `firewall-close-22` runs only when `/etc/eeploi/new-server` is there and root-owned. eeploi writes that marker when it creates the server.
- **Why:** on a server someone brings themselves, eeploi never touches the SSH port or the firewall.
- **Where:** `eeploi-helper`

## D-24: One Linux user per site, named with an _, in no other group

- **Kind:** decision
- **Decided:** 2026-11-15, PR #14
- **What:** a site user has a name with an `_` after its first letter, is listed in a root-owned registry, has uid 1000 or higher and home `/srv/eeploi/<user>`, and is in no group but its own. The system's users, the panels', the deploy user, the nginx user and the standard groups that grant root or close to it are refused as names, whether or not that group exists yet.
- **Why:** no standard user or group of the system or a package has such a name, and a package installed later keeps a group that is already there. A site user later added to another group is refused, so a site never gains rights through the helper.
- **Where:** `eeploi-helper`

## D-25: Database logins are never switched

- **Kind:** decision
- **Decided:** 2026-11-10, #3 (PR #2); 2026-11-13, #7 (PR #8); 2026-11-15, PR #14
- **What:** `db-create … socket` is only for a site user. A user that exists keeps its way in: socket login is never switched to a password or back. A user that exists keeps its password and never gets a `127.0.0.1` user; only a new password user gets one.
- **Why:** socket login trusts every process of that Linux user, so only a user that runs one site gets it. The password on stdin could be anyone's, so it never opens a way in to a user that is already there.
- **Accepted:** a password user from 1.0.0 stays on `localhost` only.
- **Where:** `eeploi-helper`
