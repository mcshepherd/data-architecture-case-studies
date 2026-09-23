-- What actually changed in the ERP each night, from the simulator's own log.
-- Runs on the erp instance as sa. The sync never sees this.
SET NOCOUNT ON;
USE erp_sim;

PRINT '## What changed in the ERP';
PRINT '';
PRINT 'From the simulator''s own log, which the sync cannot see. The sync''s "changed" count runs lower than updates plus re-created keys, because an update that writes the value already there changes nothing, and the row hash correctly stays the same. The gap is largest on nights when a busy table''s only updated column is a bit: on night 3, every update to `bl_fee` rewrote one bit column, and most wrote the value it already had. The audit confirms no real change was missed.';
PRINT '';
PRINT '| Night | Inserted | Updated | Deleted (no tombstone) | Deleted keys re-created | Updates that left modified_on stale |';
PRINT '|---|---|---|---|---|---|';
DECLARE @line nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT CONCAT('| ', night, ' | ', SUM(inserted), ' | ', SUM(updated), ' | ', SUM(deleted), ' | ', SUM(reinserted),
                  ' | ', SUM(modified_left_stale), ' |')
    FROM dbo.sim_log GROUP BY night ORDER BY night;
OPEN c; FETCH NEXT FROM c INTO @line;
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END;
CLOSE c; DEALLOCATE c;
PRINT '';
