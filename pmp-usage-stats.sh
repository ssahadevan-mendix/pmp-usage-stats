#!/usr/bin/env bash
# pmp-usage-stats.sh - Usage statistics report for a Mendix Private Mendix Platform (PMP 2.8) instance.
#
# Collects, read-only:
#   * Platform summary (users, apps, environments, pipelines, clusters, groups)
#   * Platform users and last login, with recency buckets
#   * Login trend (logins/day, distinct users/day) for the last N days
#   * Apps and environments (with status, mode, license status)
#   * Platform license (type, expiry, state)
#   * PCLM: server version, runtime/operator licenses, licenses in use mapped to environments
#
# Requirements: aws CLI (RDS IAM auth), kubectl (context pointing at the PMP cluster),
#               mx-pclm-cli binary (for the PCLM section). psql runs in an ephemeral pod.
#
# Configuration (environment variables, or a file passed with --env-file):
#   PMP_NS          Kubernetes namespace of the PMP installation            (required)
#   PMP_DB_HOST     RDS endpoint of the PMP platform database               (required)
#   PMP_DB_NAME     Database name                                            (required)
#   PMP_DB_USER     Database user (IAM-auth enabled)                         (required)
#   PMP_DB_PASSWORD Optional. If set, used instead of an RDS IAM token.      (never printed)
#   AWS_REGION      Region for generate-db-auth-token                        (required unless PMP_DB_PASSWORD)
#   PCLM_CLI        Path to mx-pclm-cli                                      (default: mx-pclm-cli on PATH)
#   PCLM_SVC        PCLM service name in PMP_NS                              (default: mx-privatecloud-license-manager)
#   PCLM_SECRET     Secret holding PCLM admin creds (keys username/password)  (default: pclm-admin)
#   PCLM_PORT       Local port for port-forward                              (default: 18081)
#   PSQL_IMAGE      Image for the ephemeral psql pod                         (default: postgres:15)
#
# Usage:
#   pmp-usage-stats.sh [--env-file FILE] [--days N] [--skip-pclm] [--skip-db] [--out FILE] [--csv-dir DIR]
#
# Secrets are never written to stdout or to files. DB token is passed to the pod as an env var only.
set -euo pipefail

DAYS=90; SKIP_PCLM=0; SKIP_DB=0; OUT=""; CSV_DIR=""; ENV_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --skip-pclm) SKIP_PCLM=1; shift;;
    --skip-db) SKIP_DB=1; shift;;
    --out) OUT="$2"; shift 2;;
    --csv-dir) CSV_DIR="$2"; shift 2;;
    -h|--help) sed -n '2,32p' "$0"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
if [[ -n "$ENV_FILE" ]]; then set -a; . "$ENV_FILE"; set +a; fi

: "${PMP_NS:?PMP_NS is required}"
PCLM_CLI="${PCLM_CLI:-mx-pclm-cli}"
PCLM_SVC="${PCLM_SVC:-mx-privatecloud-license-manager}"
PCLM_SECRET="${PCLM_SECRET:-pclm-admin}"
PCLM_PORT="${PCLM_PORT:-18081}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:15}"

RUN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"; [[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null || true' EXIT
[[ -n "$CSV_DIR" ]] && mkdir -p "$CSV_DIR"

say() { printf '%s\n' "$@"; }
hr() { say "" "== $1 ==" ""; }
mask() { sed -E 's/((password|passwd|secret|token|licensekey|key)[=: ]+)[^ ,;"]+/\1<masked>/Ig'; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
need kubectl

# Render a '|'-separated section file as an aligned table with a header line.
table() { # table <file> <header csv>
  local f="$1" hdr="$2"
  if [[ ! -s "$f" ]]; then say "(no rows)"; return; fi
  { echo "$hdr" | tr ',' '|'; sed -e 's/||/|-|/g' -e 's/||/|-|/g' -e 's/|$/|-/' -e 's/^|/-|/' "$f"; } | column -t -s '|'
  [[ -n "$CSV_DIR" ]] && { echo "$hdr"; sed 's/|/,/g' "$f"; } > "$CSV_DIR/$(basename "$f" .txt).csv"
}

# ------------------------------------------------------------------ database
run_db() {
  need aws
  : "${PMP_DB_HOST:?PMP_DB_HOST is required}" "${PMP_DB_NAME:?PMP_DB_NAME is required}" "${PMP_DB_USER:?PMP_DB_USER is required}"
  local pw
  if [[ -n "${PMP_DB_PASSWORD:-}" ]]; then pw="$PMP_DB_PASSWORD"
  else
    : "${AWS_REGION:?AWS_REGION is required for RDS IAM auth}"
    pw=$(aws rds generate-db-auth-token --hostname "$PMP_DB_HOST" --port 5432 --region "$AWS_REGION" --username "$PMP_DB_USER")
  fi
  local pod="pmp-usage-$(date +%s)"
  kubectl -n "$PMP_NS" run "$pod" --rm -i --restart=Never --quiet --image="$PSQL_IMAGE" \
    --env="PGPASSWORD=$pw" -- \
    psql "host=$PMP_DB_HOST port=5432 dbname=$PMP_DB_NAME user=$PMP_DB_USER sslmode=require" \
    -q -t -A -F'|' -v ON_ERROR_STOP=0 -v days="$DAYS" <<'ENDSQL' 2>&1 \
  | grep -v -E "^pod .* deleted|recorded in container|command prompt" > "$WORK/db.raw"
\echo @@summary
SELECT users, deployedapps, apps, environments, pipelines, clusters, groups, to_char(createddate,'YYYY-MM-DD HH24:MI')
FROM "useradmin$realtimestatistics" ORDER BY createddate DESC LIMIT 1;
\echo @@users
SELECT u.name,
       CASE WHEN u.webserviceuser THEN 'webservice' ELSE 'interactive' END,
       CASE WHEN u.active THEN 'active' ELSE 'blocked' END,
       COALESCE(to_char(u.lastlogin,'YYYY-MM-DD HH24:MI'),'never'),
       CASE WHEN u.lastlogin IS NULL THEN 'never'
            WHEN u.lastlogin >= now() - interval '7 days'  THEN '<=7d'
            WHEN u.lastlogin >= now() - interval '30 days' THEN '<=30d'
            WHEN u.lastlogin >= now() - interval '90 days' THEN '<=90d'
            ELSE '>90d' END
FROM "system$user" u ORDER BY u.lastlogin DESC NULLS LAST;
\echo @@user_buckets
SELECT COUNT(*) FILTER (WHERE lastlogin >= now()-interval '7 days'),
       COUNT(*) FILTER (WHERE lastlogin >= now()-interval '30 days'),
       COUNT(*) FILTER (WHERE lastlogin >= now()-interval '90 days'),
       COUNT(*) FILTER (WHERE lastlogin <  now()-interval '90 days'),
       COUNT(*) FILTER (WHERE lastlogin IS NULL),
       COUNT(*)
FROM "system$user";
\echo @@login_totals
SELECT COALESCE(SUM(userlogintimecount) FILTER (WHERE daydate::date >= current_date-30),0),
       COALESCE(SUM(userlogintimecount) FILTER (WHERE daydate::date >= current_date-90),0),
       COALESCE(SUM(userlogintimecount),0),
       COUNT(*) FILTER (WHERE daydate::date >= current_date-30),
       COUNT(*) FILTER (WHERE daydate::date >= current_date-90)
FROM "useractionauditing$userlogintrend";
\echo @@login_trend
SELECT t.daydate, t.userlogintimecount, COALESCE(n.userscount,0)
FROM "useractionauditing$userlogintrend" t
LEFT JOIN "useractionauditing$usernumberlogintrend" n ON n.daydate = t.daydate
WHERE t.daydate::date >= current_date - :days
ORDER BY t.daydate DESC;
\echo @@apps
SELECT a.name, a.appid, CASE WHEN a.isactive THEN 'active' ELSE 'inactive' END,
       COALESCE(a.mxversion,''), to_char(a.createddate,'YYYY-MM-DD'),
       COALESCE(to_char(a.lastdeployeddate,'YYYY-MM-DD'),''),
       (SELECT COUNT(*) FROM "jenkins$sharedenv_app" se WHERE se."atm_main$appid"=a.id)
FROM "atm_main$app" a ORDER BY a.name;
\echo @@envs
SELECT COALESCE(a.name,'(unlinked)'), e.displayname, e.internalname,
       CASE e.dtapmode WHEN 'D' THEN 'Development' WHEN 'T' THEN 'Test' WHEN 'A' THEN 'Acceptance' WHEN 'P' THEN 'Production' ELSE COALESCE(e.dtapmode,'') END,
       e.deploymentpurpose, e.status, e.runtimestatus, e.licensestatus,
       e.readyreplicas||'/'||e.replicas,
       COALESCE(to_char(e.laststarttime,'YYYY-MM-DD HH24:MI'),''),
       to_char(e.createddate,'YYYY-MM-DD'),
       COALESCE(e.appurl,'')
FROM "jenkins$environment" e
LEFT JOIN "jenkins$sharedenv_app" se ON se."jenkins$environmentid"=e.id
LEFT JOIN "atm_main$app" a ON a.id=se."atm_main$appid"
ORDER BY 1,2;
\echo @@groups
SELECT g.name, (SELECT COUNT(*) FROM "useradmin$member_group" mg WHERE mg."atm_company$groupid"=g.id),
       to_char(g.createddate,'YYYY-MM-DD')
FROM "atm_company$group" g ORDER BY 1;
\echo @@license
SELECT COALESCE(licensetype,''), COALESCE(to_char(expirationdate,'YYYY-MM-DD'),''), COALESCE(state,''),
       COALESCE(to_char(changeddate,'YYYY-MM-DD'),'')
FROM "common$platformlicense" ORDER BY changeddate DESC LIMIT 1;
\echo @@end
ENDSQL
  # split sections
  awk -v d="$WORK" '/^@@/{f=d"/"substr($0,3)".txt"; next} /^(ERROR|FATAL|LINE [0-9]+:|HINT:|psql:)/{next} /^ *\^ *$/{next} f{print > f}' "$WORK/db.raw"
  grep -E '^(ERROR|FATAL|psql:)' "$WORK/db.raw" > "$WORK/db.err" || true
}

# ---------------------------------------------------------------------- pclm
pclm() { # run one pclm command with a 30s watchdog, creds never echoed
  ( "$PCLM_CLI" "$@" -s "http://localhost:$PCLM_PORT" -u "$PCLM_U" -p "$PCLM_P" 2>&1 & pid=$!
    ( sleep 30; kill "$pid" 2>/dev/null ) & wd=$!; wait "$pid"; kill "$wd" 2>/dev/null ) | mask
}
run_pclm() {
  if ! command -v "$PCLM_CLI" >/dev/null 2>&1 && [[ ! -x "$PCLM_CLI" ]]; then
    echo "PCLM_CLI not found ($PCLM_CLI); skipping PCLM section" > "$WORK/pclm.err"; return
  fi
  PCLM_U=$(kubectl -n "$PMP_NS" get secret "$PCLM_SECRET" -o jsonpath='{.data.username}' | base64 -d)
  PCLM_P=$(kubectl -n "$PMP_NS" get secret "$PCLM_SECRET" -o jsonpath='{.data.password}' | base64 -d)
  kubectl -n "$PMP_NS" port-forward "svc/$PCLM_SVC" "$PCLM_PORT:80" >/dev/null 2>&1 & PF_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 1; curl -s -o /dev/null "http://localhost:$PCLM_PORT/" && break; done
  pclm server-version          > "$WORK/pclm_version.txt"
  pclm license runtime list    > "$WORK/pclm_runtime.txt"
  pclm license operator list   > "$WORK/pclm_operator.txt"
  pclm license list-usage      > "$WORK/pclm_usage.txt"
  pclm user list               > "$WORK/pclm_users.txt"
  unset PCLM_U PCLM_P
}

# --------------------------------------------------------------------- report
report() {
  say "PMP USAGE REPORT" "namespace: $PMP_NS" "generated: $RUN_TS (UTC)" "trend window: last $DAYS days"
  if [[ $SKIP_DB -eq 0 ]]; then
    hr "Platform summary (useradmin\$realtimestatistics, latest snapshot)"
    table "$WORK/summary.txt" "users,deployed_apps,apps,environments,pipelines,clusters,groups,snapshot"
    hr "User login recency"
    table "$WORK/user_buckets.txt" "last_7d,last_30d,last_90d,older_than_90d,never,total_users"
    hr "Users and last login"
    table "$WORK/users.txt" "user,kind,state,last_login,bucket"
    hr "Login totals"
    table "$WORK/login_totals.txt" "logins_30d,logins_90d,logins_all_time,active_days_30d,active_days_90d"
    hr "Login trend (per day)"
    table "$WORK/login_trend.txt" "day,logins,distinct_users"
    hr "Apps"
    table "$WORK/apps.txt" "app,app_id,state,mx_version,created,last_deployed,environments"
    hr "Environments"
    table "$WORK/envs.txt" "app,environment,env_id,mode,purpose,status,runtime,license,ready/replicas,last_start,created,url"
    hr "Groups"
    table "$WORK/groups.txt" "group,members,created"
    hr "Platform license"
    table "$WORK/license.txt" "type,expires,state,updated"
    if [[ -s "$WORK/db.err" ]]; then hr "Database query errors"; cat "$WORK/db.err"; fi
  fi
  if [[ $SKIP_PCLM -eq 0 ]]; then
    if [[ -s "$WORK/pclm.err" ]]; then hr "PCLM"; cat "$WORK/pclm.err"
    else
      hr "PCLM server";            cat "$WORK/pclm_version.txt"
      hr "PCLM runtime licenses";  cat "$WORK/pclm_runtime.txt"
      hr "PCLM operator licenses"; cat "$WORK/pclm_operator.txt"
      hr "PCLM licenses in use";   cat "$WORK/pclm_usage.txt"
      if [[ -s "$WORK/envs.txt" ]]; then
        hr "PCLM licenses in use -> environment"
        # match any environment internal name appearing in the usage output
        while IFS='|' read -r app env envid _; do
          if grep -q -- "$envid" "$WORK/pclm_usage.txt"; then
            lic=$(grep -- "$envid" "$WORK/pclm_usage.txt" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
            say "$lic|$envid|$env|$app"
          fi
        done < "$WORK/envs.txt" > "$WORK/pclm_map.txt"
        table "$WORK/pclm_map.txt" "license_id,env_id,environment,app"
      fi
      hr "PCLM users"; cat "$WORK/pclm_users.txt"
    fi
  fi
}

[[ $SKIP_DB -eq 0 ]] && run_db
[[ $SKIP_PCLM -eq 0 ]] && run_pclm
if [[ -n "$OUT" ]]; then report | tee "$OUT" >/dev/null; echo "report written to $OUT"; else report; fi
