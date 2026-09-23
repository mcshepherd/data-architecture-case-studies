-- What the warehouse can see of the ERP, through the wrapper. Runs on the warehouse.
USE warehouse;
SET NOCOUNT ON;
CREATE TABLE #n (n int);
DECLARE @v nvarchar(100);

INSERT INTO #n EXEC sync.erp_exec_at N'SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS', N'proof';
SELECT @v = FORMAT(n, 'N0') FROM #n;
PRINT CONCAT('- Columns visible in `INFORMATION_SCHEMA.COLUMNS`: **', @v, '**. Enough to build every target table.');
DELETE FROM #n;

INSERT INTO #n EXEC sync.erp_exec_at N'SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS', N'proof';
SELECT @v = n FROM #n;
PRINT CONCAT('- Rows in `INFORMATION_SCHEMA.TABLE_CONSTRAINTS`: **', @v, '**. The keys have to come from the manifest.');
DELETE FROM #n;

BEGIN TRY
    INSERT INTO #n EXEC sync.erp_exec_at N'SELECT COUNT(*) FROM erp_sim.dbo.design_table', N'proof';
    PRINT '- The generator database `erp_sim`: **readable** (unexpected).';
END TRY
BEGIN CATCH
    PRINT CONCAT('- The generator database `erp_sim`: **not reachable** (', ERROR_MESSAGE(), ')');
END CATCH;

SELECT @v = COUNT(*) FROM sync.manifest;
PRINT CONCAT('- Tables in the manifest: **', @v, '**, with key columns for each. For example:');
PRINT '';
PRINT '| Table | Key columns |';
PRINT '|---|---|';
DECLARE @line nvarchar(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT TOP 5 CONCAT('| ', table_name, ' | ', key_columns, ' |') FROM sync.manifest
    ORDER BY LEN(key_columns) - LEN(REPLACE(key_columns, ',', '')) DESC, table_name;
OPEN c; FETCH NEXT FROM c INTO @line;
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END;
CLOSE c; DEALLOCATE c;
