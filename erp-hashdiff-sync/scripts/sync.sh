#!/usr/bin/env bash
# Run one sync: start a run, then call the per-table procedure for every
# manifest table, several at a time. Stands in for the SSIS package, which
# started one node per table in parallel and retried a failed node. All the
# work is in sync.usp_sync_table; this only starts it.
#
#   scripts/sync.sh [--run-at 'YYYY-MM-DD HH:MM'] [--wipe] [--parallel N] [table ...]
#
# Each table gets up to three attempts. A variance-guard breach is logged and
# not retried: rerunning would pull the same short count. At the end, one alert
# email goes out if any table ended the run failed.
source "$(dirname "$0")/lib.sh"
run_at="NULL"; wipe=0; parallel=6; tables=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-at) run_at="'$2'"; shift 2 ;;
        --wipe) wipe=1; shift ;;
        --parallel) parallel="$2"; shift 2 ;;
        *) tables+=("$1"); shift ;;
    esac
done
wsql() { sql warehouse -d warehouse -h -1 -W "$@"; }

if [[ $(wsql -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sync.source_columns") == 0 ]]; then
    wsql -Q "EXEC sync.usp_probe_metadata" >/dev/null
fi
run_id=$(wsql -Q "SET NOCOUNT ON; DECLARE @id int; EXEC sync.usp_start_run @run_at = $run_at, @wipe = $wipe, @run_id = @id OUTPUT; SELECT @id;")
if [[ ${#tables[@]} -eq 0 ]]; then
    while IFS= read -r t; do tables+=("$t"); done \
        < <(wsql -Q "SET NOCOUNT ON; SELECT table_name FROM sync.manifest WHERE is_active = 1 ORDER BY table_name")
fi

# One table, up to three attempts.
sync_table() {
    local t="$1" attempt status
    for attempt in 1 2 3; do
        if wsql -Q "EXEC sync.usp_sync_table @table_name = N'$t', @run_id = $run_id" >/dev/null 2>&1; then
            return 0
        fi
        status=$(wsql -Q "SET NOCOUNT ON; SELECT TOP 1 status FROM sync.run_table_log
                          WHERE run_id = $run_id AND table_name = N'$t' ORDER BY log_id DESC")
        [[ "$status" == "variance" ]] && return 1
    done
    return 1
}
export -f sync_table wsql sql
export run_id SA_PASSWORD READER_PASSWORD QUERY_TIMEOUT_S

printf '%s\n' "${tables[@]}" | xargs -P "$parallel" -I{} bash -c 'sync_table "$1"' _ {} || true

# A table's outcome is its last attempt.
last="WITH last AS (SELECT status, ROW_NUMBER() OVER (PARTITION BY table_name ORDER BY log_id DESC) AS rn
                   FROM sync.run_table_log WHERE run_id = $run_id)"
wsql -Q "SET NOCOUNT ON; $last
    SELECT CONCAT('run ', $run_id, ': ', SUM(IIF(status = 'succeeded', 1, 0)), ' succeeded, ',
                  SUM(IIF(status <> 'succeeded', 1, 0)), ' not') FROM last WHERE rn = 1"
failed=$(wsql -Q "SET NOCOUNT ON; $last SELECT COUNT(*) FROM last WHERE rn = 1 AND status <> 'succeeded'")
# Like the SSIS Send Mail task on failure: one email if any table ended the run failed.
wsql -Q "EXEC sync.usp_alert_run $run_id" >/dev/null
exit $((failed > 0))
