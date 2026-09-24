#!/usr/bin/env bash
# Run one sync: start a run, then call the per-table procedure for every
# manifest table, several at a time. Stands in for the SSIS package, which
# started one node per table in parallel, retried a failed node, and sent a
# failure email. All the work is in sync.usp_sync_table; this only starts it.
#
#   scripts/sync.sh [--run-at 'YYYY-MM-DD HH:MM'] [--wipe] [--parallel N] [table ...]
#
# Each table gets up to three attempts. A variance-guard breach is logged and
# not retried: rerunning would pull the same short count. At the end, one alert
# email goes out if any table ended the run failed. The exit code reflects the
# sync, not the email.
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

# Refresh the metadata copy every run, so a vendor schema change is caught the
# night it lands (the per-table drift check then stops that table by name).
wsql -Q "EXEC sync.usp_probe_metadata" >/dev/null

run_id=$(wsql -Q "SET NOCOUNT ON; DECLARE @id int; EXEC sync.usp_start_run @run_at = $run_at, @wipe = $wipe, @run_id = @id OUTPUT; SELECT @id;")
if [[ ${#tables[@]} -eq 0 ]]; then
    while IFS= read -r t; do tables+=("$t"); done \
        < <(wsql -Q "SET NOCOUNT ON; SELECT table_name FROM sync.manifest WHERE is_active = 1 ORDER BY table_name")
fi
# Each table once: two syncs of one table would share its staging tables.
list=$(printf '%s\n' "${tables[@]}" | awk 'NF && !seen[$0]++')
wsql -Q "EXEC sync.usp_plan_run @run_id = $run_id, @tables = N'$(echo "$list" | paste -sd, -)'" >/dev/null

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

echo "$list" | xargs -P "$parallel" -I{} bash -c 'sync_table "$1"' _ {} || true

# Outcomes, from the same definition the alert uses.
wsql -Q "SET NOCOUNT ON; SELECT CONCAT('run ', $run_id, ': ', SUM(IIF(status = 'succeeded', 1, 0)), ' succeeded, ',
         SUM(IIF(status <> 'succeeded', 1, 0)), ' not') FROM sync.fn_run_outcome($run_id)"
failed=$(wsql -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sync.fn_run_outcome($run_id) WHERE status <> 'succeeded'")

# Like the SSIS Send Mail task on failure: one email if any table ended the run
# failed. A problem sending it is reported, but does not change the run's result.
wsql -Q "EXEC sync.usp_alert_run $run_id" >/dev/null || echo "sync.sh: alert for run $run_id could not be sent" >&2
exit $((failed > 0))
