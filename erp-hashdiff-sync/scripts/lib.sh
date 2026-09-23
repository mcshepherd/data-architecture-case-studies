# Shared helpers. Source from other scripts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
set -a; source .env; set +a

# sql <erp|warehouse> <sqlcmd args...>
sql() {
    local svc="$1"; shift
    docker compose exec -T "$svc" /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$SA_PASSWORD" \
        -v READER_PASSWORD="$READER_PASSWORD" QUERY_TIMEOUT_S="$QUERY_TIMEOUT_S" -b "$@"
}
