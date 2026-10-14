# Shared helpers. Source from other scripts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
set -a; source .env; set +a
# Git Bash on Windows rewrites arguments that start with / into Windows paths, which breaks
# the container paths below (/opt/mssql-tools18/..., /sql/...). No effect on macOS and Linux.
export MSYS_NO_PATHCONV=1
# Windows Python writes cp1252 by default; proofs need UTF-8.
export PYTHONUTF8=1
# Windows often has only `python`, and its `python3` may be a Store placeholder that runs nothing.
python3 -c '' >/dev/null 2>&1 || python3() { python "$@"; }

# sql <erp|warehouse> <sqlcmd args...>
sql() {
    local svc="$1"; shift
    docker compose exec -T "$svc" /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$SA_PASSWORD" \
        -v READER_PASSWORD="$READER_PASSWORD" QUERY_TIMEOUT_S="$QUERY_TIMEOUT_S" -b "$@"
}
