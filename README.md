# pmp-usage-stats

Read-only usage report for a Private Mendix Platform (PMP 2.8) instance: users and last login,
login trend, apps, users per app (with role), environments, groups, platform license, and PCLM
license inventory/usage (with in-use licenses mapped back to environments and apps).

    ./pmp-usage-stats.sh --env-file my-instance.env --days 90 --out report.txt --csv-dir csv/

Options: `--days N` (login-trend window), `--skip-db`, `--skip-pclm`, `--out FILE`, `--csv-dir DIR`.
Config comes from env vars or an `--env-file` (see `example.env`). No secrets are stored or printed:
the DB uses an RDS IAM token (or `PMP_DB_PASSWORD` exported in the shell), PCLM credentials are read
from the `pclm-admin` Secret and passed only to `mx-pclm-cli`.

Requires `aws`, `kubectl` (context on the PMP cluster), and `mx-pclm-cli` for the PCLM section.
psql runs in an ephemeral `postgres:15` pod in the PMP namespace.

## Do not commit

Instance env files (`*.env` other than `example.env`), generated reports and CSV directories contain
customer hostnames, usernames and app URLs. Keep them out of version control:

    *.env
    !example.env
    *-usage-*.txt
    csv-*/

## Sample output

Values below are illustrative. `--csv-dir` writes one CSV per section with the same columns.

```
PMP USAGE REPORT
namespace: pmp-example
generated: 2026-11-10T21:45:07Z (UTC)
trend window: last 90 days

== Platform summary (useradmin$realtimestatistics, latest snapshot) ==

users  deployed_apps  apps  environments  pipelines  clusters  groups  snapshot
7      5              7     5             21         1         5       2026-11-09 17:24

== User login recency ==

last_7d  last_30d  last_90d  older_than_90d  never  total_users
1        6         7         3               0      10

== Users and last login ==

user        kind         state   last_login        bucket
Admin       interactive  active  2026-11-09 17:24  <=7d
jdoe        interactive  active  2026-11-03 19:03  <=30d
modeler     webservice   active  2026-10-30 15:40  <=30d
demouser    interactive  active  2026-06-19 13:07  >90d

== Login totals ==

logins_30d  logins_90d  logins_all_time  active_days_30d  active_days_90d
36          87          124              5                10

== Login trend (per day) ==

day         logins  distinct_users
2026-11-03  8       1
2026-10-30  22      2

== Apps ==

app         app_id                                state   mx_version  created     last_deployed  environments
ExampleApp  93220ee5-f871-448a-b44b-bb018845c1fa  active  -           2026-06-11  2026-06-11     1
HeadersPOC  d999fceb-2873-4ffc-a9bb-2435f0facb37  active  -           2026-04-23  -              0

== Users per app (atm_main$membership) ==

app         users  accepted  pending  direct  active_last_90d
ExampleApp  2      2         0        1       0
MaiaTest    6      6         0        1       3

== App members (user, role) ==

app         user      role           access     status    last_login
ExampleApp  demouser  Administrator  direct     accepted  2026-06-19
ExampleApp  jdoe      Administrator  inherited  accepted  2026-11-03
MaiaTest    jdoe      Administrator  inherited  accepted  2026-11-03

== Environments ==

app         environment  env_id    mode         purpose    status  runtime  license  ready/replicas  last_start        created     url
ExampleApp  dev          qwwehjzg  Development  -          Ready   Running  Valid    1/1             2026-11-03 18:40  2026-06-11  https://exampleapp-dev.pmp.example.com
MaiaTest    test         j9wf61g4  Development  -          Ready   Running  Valid    1/1             2026-10-30 15:02  2026-07-08  https://maiatest-test.pmp.example.com

== Groups ==

group            members  created
App Portfolio 1  5        2026-04-01
Platform Admin   1        2026-04-01

== Platform license ==

type        expires     state   updated
Enterprise  2028-09-29  Normal  2026-03-20

== PCLM server ==

{ "build_tag": "0.10.7", ... }

== PCLM runtime licenses ==

┃ LICENSE-ID                           ┃ TYPE       ┃ EXPIRATION-DATE      ┃ CREATED-AT           ┃ PRODUCTS ┃
┃ 423bfc94-635f-4b7f-8240-0a6a7790498c ┃ mx-runtime ┃ 2028-09-30T00:00:00Z ┃ 2025-12-16T13:54:39Z ┃ standard ┃
┃ 757f740b-81bc-4c30-8ed2-2435bb33ff38 ┃ mx-runtime ┃ 2026-04-18T00:00:00Z ┃ 2026-03-20T14:01:41Z ┃ Platform ┃
[Total Rows=11 | Total Pages=1]

== PCLM operator licenses ==
(same table format, TYPE mx-operator)

== PCLM licenses in use ==
(mx-pclm-cli license list-usage table: LICENSE-ID, APP-ID, ...)

== PCLM licenses in use -> environment ==

license_id                            env_id    environment  app
6428cd07-5b98-4da4-97eb-0bb8b5c88200  qwwehjzg  dev          ExampleApp
423bfc94-635f-4b7f-8240-0a6a7790498c  j9wf61g4  test         MaiaTest
22e25d9b-d58d-43f7-a72b-c07cd672fabd  -         -            (mxplatform itself)

== PCLM users ==
(mx-pclm-cli user list table: username, role)
```

## Schema notes (PMP 2.8)

- Environments live in `jenkins$environment`, linked to apps via `jenkins$sharedenv_app`;
  `cloudportalenvironmentoperation$environment` is empty on 2.8.
- Users per app come from `atm_main$membership` joined through `atm_main$membership_app`,
  `atm_main$membership_platform_user` and `atm_main$membership_role` (role name in `dynamicrole$role`).
  `direct` means the user was added to the app itself; `inherited` means access came via a group.
  `atm_main$app_shareduser` and `atm_company$app_sharegroup` were empty on the sandbox.
- Group membership is `useradmin$member_group`. Login history is `useractionauditing$userlogintrend`
  (`daydate` is varchar, cast to date).
