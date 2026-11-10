# pmp-usage-stats

Read-only usage report for a Private Mendix Platform (PMP 2.8) instance: users and last login,
login trend, apps, environments, groups, platform license, and PCLM license inventory/usage
(with in-use licenses mapped back to environments and apps).

    ./pmp-usage-stats.sh --env-file adfm-sandbox.env --days 90 --out report.txt --csv-dir csv/

Options: `--days N` (login-trend window), `--skip-db`, `--skip-pclm`, `--out FILE`, `--csv-dir DIR`.
Config comes from env vars or an `--env-file` (see `example.env`). No secrets are stored or printed:
the DB uses an RDS IAM token (or `PMP_DB_PASSWORD` exported in the shell), PCLM credentials are read
from the `pclm-admin` Secret and passed only to `mx-pclm-cli`.

Requires `aws`, `kubectl` (context on the PMP cluster), and `mx-pclm-cli` for the PCLM section.
psql runs in an ephemeral `postgres:15` pod in the PMP namespace.

Schema notes (PMP 2.8): environments live in `jenkins$environment`, linked to apps via
`jenkins$sharedenv_app`; `cloudportalenvironmentoperation$environment` is empty on 2.8.
