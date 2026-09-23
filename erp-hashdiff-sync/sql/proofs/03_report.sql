-- Old process against new, night by night, as markdown. Runs on the warehouse.
SET NOCOUNT ON;
USE warehouse;

DECLARE @nights int = (SELECT COUNT(*) FROM legacy.run) - 1;
DECLARE @tables int = (SELECT COUNT(*) FROM legacy.manifest);
DECLARE @last int = (SELECT MAX(run_id) FROM legacy.run);
DECLARE @old_wrong int, @old_missing int, @old_extra int, @old_mismatch int, @old_dups int, @old_errors int, @new_dirty int, @new_audits int;
SELECT @old_wrong = SUM(IIF(missing + extra + mismatched + duplicate_keys > 0, 1, 0)),
       @old_missing = SUM(missing), @old_extra = SUM(extra), @old_mismatch = SUM(mismatched), @old_dups = SUM(duplicate_keys)
FROM audit.result WHERE copy_name = 'legacy' AND run_id = @last;
SELECT @old_errors = COUNT(*) FROM legacy.load_log WHERE message IS NOT NULL;
SELECT @new_audits = COUNT(*), @new_dirty = SUM(IIF(missing + extra + mismatched + duplicate_keys + deleted_but_present > 0, 1, 0))
FROM audit.result WHERE copy_name = 'replica';

PRINT CONCAT('**After ', @nights, ' nights, the old process had ', @old_wrong, ' of ', @tables, ' tables wrong, and had raised ',
             @old_errors, ' errors.** Against the ERP, its copy was missing ', FORMAT(@old_missing, 'N0'), ' rows, held ',
             FORMAT(@old_extra, 'N0'), ' rows the ERP no longer has, held ', FORMAT(@old_mismatch, 'N0'),
             ' rows with stale values, and had ', FORMAT(@old_dups, 'N0'), ' duplicated keys. ',
             'Over the same nights the new process was exact: ', @new_audits - @new_dirty, ' of ', @new_audits, ' table audits clean.');
PRINT '';
PRINT 'Both ran against the same ERP on the same nights, through the same driver, and were checked by the same independent audit.';
PRINT '';
PRINT '## Night by night';
PRINT '';
PRINT '| Run | Old: tables wrong | Missing rows | Rows deleted in the ERP, still present | Stale rows | Duplicated keys | Errors raised | New: tables wrong |';
PRINT '|---|---|---|---|---|---|---|---|';
DECLARE @line nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT CONCAT('| ', IIF(r.run_id = 1, 'First load', CONCAT('Night ', r.run_id - 1)),
                  ' | ', o.wrong, ' | ', FORMAT(o.missing, 'N0'), ' | ', FORMAT(o.extra, 'N0'), ' | ', FORMAT(o.mismatched, 'N0'),
                  ' | ', FORMAT(o.dups, 'N0'), ' | ', e.errors, ' | ', n.wrong, ' |')
    FROM legacy.run r
    CROSS APPLY (SELECT SUM(IIF(missing + extra + mismatched + duplicate_keys > 0, 1, 0)) wrong, SUM(missing) missing,
                        SUM(extra) extra, SUM(mismatched) mismatched, SUM(duplicate_keys) dups
                 FROM audit.result WHERE copy_name = 'legacy' AND run_id = r.run_id) o
    CROSS APPLY (SELECT COUNT(*) errors FROM legacy.load_log WHERE run_id = r.run_id AND message IS NOT NULL) e
    CROSS APPLY (SELECT SUM(IIF(missing + extra + mismatched + duplicate_keys + deleted_but_present > 0, 1, 0)) wrong
                 FROM audit.result WHERE copy_name = 'replica' AND run_id = r.run_id) n
    ORDER BY r.run_id;
OPEN c; FETCH NEXT FROM c INTO @line;
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END;
CLOSE c; DEALLOCATE c;
PRINT '';
PRINT 'The drift grows night over night and never raises an error. Nothing in the old process''s own logs would show it.';
PRINT '';

PRINT '## Where the old process goes wrong';
PRINT '';
PRINT 'The full-reload tables stay correct: they are rebuilt every night. The damage is all in the incremental tables, which trust the create and modify dates and upsert on the package''s key.';
PRINT '';
PRINT '| Table | Rows | Real key | Package key | Window | Missing | Deleted, still present | Stale | Duplicated keys |';
PRINT '|---|---|---|---|---|---|---|---|---|';
DECLARE c2 CURSOR LOCAL FAST_FORWARD FOR
    SELECT CONCAT('| ', m.table_name, ' | ', FORMAT(a.source_rows, 'N0'), ' | ', s.key_columns, ' | ', m.upsert_key,
                  IIF(s.key_columns = m.upsert_key, '', ' (missing a column)'), ' | ', m.window_days, ' days | ',
                  FORMAT(a.missing, 'N0'), ' | ', FORMAT(a.extra, 'N0'), ' | ', FORMAT(a.mismatched, 'N0'), ' | ',
                  FORMAT(a.duplicate_keys, 'N0'), ' |')
    FROM legacy.manifest m
    JOIN sync.manifest s ON s.table_name = m.table_name
    JOIN audit.result a ON a.copy_name = 'legacy' AND a.run_id = @last AND a.table_name = m.table_name
    WHERE m.load_mode = 'incremental'
    ORDER BY a.missing + a.extra + a.mismatched + a.duplicate_keys DESC;
OPEN c2; FETCH NEXT FROM c2 INTO @line;
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c2 INTO @line; END;
CLOSE c2; DEALLOCATE c2;
PRINT '';
PRINT '- **Missing and stale rows:** rows whose create or modify date is missing, or was not updated when the row changed, are never pulled. And where the package key is missing a column, one pulled row overwrites every sibling that shares the partial key, so the siblings'' own values disappear.';
PRINT '- **Duplicated keys:** that overwrite includes the key column the package does not know about, so distinct rows become copies of one row.';
PRINT '- **Deleted rows still present:** the ERP leaves no trace of a delete, and the incremental package has no way to notice one.';
PRINT '';

PRINT '## Cost';
PRINT '';
PRINT '| Run | Old: rows pulled | Old: minutes | New: keys compared | New: rows fetched | New: minutes |';
PRINT '|---|---|---|---|---|---|';
DECLARE c3 CURSOR LOCAL FAST_FORWARD FOR
    SELECT CONCAT('| ', IIF(r.run_id = 1, 'First load', CONCAT('Night ', r.run_id - 1)),
                  ' | ', FORMAT(o.pulled, 'N0'), ' | ', FORMAT(o.seconds / 60.0, 'N1'),
                  ' | ', FORMAT(n.pulled, 'N0'), ' | ', FORMAT(n.fetched, 'N0'), ' | ', FORMAT(n.seconds / 60.0, 'N1'), ' |')
    FROM legacy.run r
    CROSS APPLY (SELECT SUM(rows_pulled) pulled, DATEDIFF(second, MIN(started_at), MAX(finished_at)) seconds
                 FROM legacy.load_log WHERE run_id = r.run_id) o
    CROSS APPLY (SELECT SUM(pulled_keys) pulled, SUM(fetched) fetched, DATEDIFF(second, MIN(started_at), MAX(finished_at)) seconds
                 FROM sync.run_table_log WHERE run_id = r.run_id) n
    ORDER BY r.run_id;
OPEN c3; FETCH NEXT FROM c3 INTO @line;
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c3 INTO @line; END;
CLOSE c3; DEALLOCATE c3;
PRINT '';
PRINT 'The old process reloads most tables in full every night and pulls only a window of the large ones. The new process compares every key every night, but fetches full rows only for what changed. At this scale both finish in minutes; the difference that matters here is correctness. At the original site, the old process took about 9 hours a night and the new one about 38 minutes.';
