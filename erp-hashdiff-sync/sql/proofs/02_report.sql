-- Night-by-night sync and audit results, as markdown. Runs on the warehouse.
SET NOCOUNT ON;
USE warehouse;

DECLARE @runs int = (SELECT COUNT(*) FROM sync.run);
DECLARE @tables int = (SELECT COUNT(*) FROM sync.manifest WHERE is_active = 1);
DECLARE @failures int = (SELECT COUNT(*) FROM sync.run_table_log WHERE status <> 'succeeded');
DECLARE @dirty int = (SELECT COUNT(*) FROM audit.result
                      WHERE copy_name = 'replica' AND missing + extra + mismatched + duplicate_keys + deleted_but_present > 0);
DECLARE @audited int = (SELECT COUNT(*) FROM audit.result WHERE copy_name = 'replica');

PRINT CONCAT('**Result: ', IIF(@failures = 0 AND @dirty = 0 AND @audited = @runs * @tables, 'PASS', 'FAIL'), '.** ',
             @runs, ' runs (the first load and ', @runs - 1, ' nightly runs) across ', @tables, ' tables. ',
             'After every run, an independent audit compared every row of every table with the ERP: ',
             @audited - @dirty, ' of ', @audited, ' table audits clean, ', @failures, ' table runs failed.');
PRINT '';
PRINT '## Night by night';
PRINT '';
PRINT '| Run | Keys pulled | New | Changed | Deleted | Rows fetched | Batches | Statements sent | Longest statement | Minutes | Audit: clean tables | Missing | Extra | Mismatched | Duplicate keys | Deleted but present |';
PRINT '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|';
DECLARE @line nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT CONCAT('| ', IIF(r.run_id = 1, 'First load', CONCAT('Night ', r.run_id - 1)),
                  ' | ', FORMAT(l.pulled, 'N0'), ' | ', FORMAT(l.new, 'N0'), ' | ', FORMAT(l.changed, 'N0'),
                  ' | ', FORMAT(l.deleted, 'N0'), ' | ', FORMAT(l.fetched, 'N0'), ' | ', FORMAT(l.batches, 'N0'),
                  ' | ', FORMAT(l.calls, 'N0'), ' | ', FORMAT(l.max_chars, 'N0'),
                  ' | ', FORMAT(l.seconds / 60.0, 'N1'),
                  ' | ', a.clean, '/', a.n, ' | ', a.missing, ' | ', a.extra, ' | ', a.mismatched,
                  ' | ', a.dups, ' | ', a.del_present, ' |')
    FROM sync.run r
    CROSS APPLY (SELECT SUM(pulled_keys) pulled, SUM(new_keys) new, SUM(changed_keys) changed, SUM(deleted_keys) deleted,
                        SUM(fetched) fetched, SUM(batches) batches, SUM(driver_calls) calls, MAX(max_sql_chars) max_chars,
                        DATEDIFF(second, MIN(started_at), MAX(finished_at)) seconds
                 FROM sync.run_table_log WHERE run_id = r.run_id) l
    CROSS APPLY (SELECT COUNT(*) n, SUM(IIF(missing + extra + mismatched + duplicate_keys + deleted_but_present = 0, 1, 0)) clean,
                        SUM(missing) missing, SUM(extra) extra, SUM(mismatched) mismatched,
                        SUM(duplicate_keys) dups, SUM(deleted_but_present) del_present
                 FROM audit.result WHERE copy_name = 'replica' AND run_id = r.run_id) a
    ORDER BY r.run_id;
OPEN c; FETCH NEXT FROM c INTO @line;
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END;
CLOSE c; DEALLOCATE c;
PRINT '';
PRINT 'Keys pulled is every key in the ERP, with a hash of its whole row, in one statement per table. Rows fetched is only what was new or changed. Deleted is keys that disappeared from the ERP, flagged in the replica.';
PRINT '';

-- How the text limit shapes batches: fixed statement text versus room for keys.
DECLARE @limit int = (SELECT CAST(value AS int) FROM sync.config WHERE name = N'text_limit');
PRINT '## Batching on the first load';
PRINT '';
PRINT CONCAT('Each fetch statement carries its keys as literals in a VALUES list and must fit the ', FORMAT(@limit, 'N0'),
             '-character text limit, with at most 5,000 rows per batch. The select list is fixed text, so wide tables have less room for keys.');
PRINT '';
PRINT '| Table | Columns | Key | Rows | Batches | Most keys in a batch | Longest statement |';
PRINT '|---|---|---|---|---|---|---|';
DECLARE c2 CURSOR LOCAL FAST_FORWARD FOR
    SELECT CONCAT('| ', l.table_name, ' | ', c.n, ' | ', m.key_columns, ' | ', FORMAT(l.fetched, 'N0'), ' | ', l.batches,
                  ' | ', FORMAT(l.max_batch_keys, 'N0'), ' | ', FORMAT(l.max_sql_chars, 'N0'), ' |')
    FROM sync.run_table_log l
    JOIN sync.manifest m ON m.table_name = l.table_name
    CROSS APPLY (SELECT COUNT(*) n FROM sync.source_columns s WHERE s.table_name = l.table_name) c
    WHERE l.run_id = 1 AND l.table_name IN (
        SELECT TOP 3 table_name FROM sync.source_columns GROUP BY table_name ORDER BY COUNT(*) DESC
        UNION ALL
        SELECT TOP 3 table_name FROM sync.run_table_log WHERE run_id = 1 ORDER BY fetched DESC)
    ORDER BY c.n DESC;
OPEN c2; FETCH NEXT FROM c2 INTO @line;
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c2 INTO @line; END;
CLOSE c2; DEALLOCATE c2;
PRINT '';
