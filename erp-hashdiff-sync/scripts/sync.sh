#!/usr/bin/env bash
# Run one sync: start a run, then call the per-table procedure for each manifest
# table. Stands in for the SSIS package that started one node per table; all the
# work is in sync.usp_sync_table.
#
#   scripts/sync.sh [--run-at 'YYYY-MM-DD HH:MM'] [--wipe] [table ...]
source "$(dirname "$0")/lib.sh"
run_at="NULL"; wipe=0; tables=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-at) run_at="'$2'"; shift 2 ;;
        --wipe) wipe=1; shift ;;
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

failed=0
for t in "${tables[@]}"; do
    if ! wsql -Q "EXEC sync.usp_sync_table @table_name = N'$t', @run_id = $run_id" >/dev/null 2>&1; then
        failed=$((failed + 1))
    fi
done
wsql -Q "SET NOCOUNT ON; SELECT CONCAT('run ', $run_id, ': ', SUM(IIF(status = 'succeeded', 1, 0)), ' succeeded, ',
         SUM(IIF(status <> 'succeeded', 1, 0)), ' not') FROM sync.run_table_log WHERE run_id = $run_id"
exit $((failed > 0))
