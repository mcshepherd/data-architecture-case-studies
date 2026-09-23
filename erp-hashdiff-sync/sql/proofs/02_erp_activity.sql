-- What actually changed in the ERP each night, from the simulator's own log.
-- Runs on the erp instance as sa. The sync never sees this.
SET NOCOUNT ON;
USE erp_sim;

PRINT '## What changed in the ERP';
PRINT '';
PRINT 'These are the UPDATE statements the ERP''s own business activity ran, from the simulator''s log, which the sync cannot see. Some of them write the value a column already holds, such as setting a bit to 1 when it is already 1. The row does not change, so its hash does not change, and the sync correctly does nothing: no fetch, no write. That is why the sync''s "changed" count runs below updates plus re-created keys here. The gap is largest when a busy table''s only updated column is a bit: on night 3, every update to `bl_fee` rewrote one bit column, and most wrote the value it already had. The audit confirms no real change was missed.';
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
