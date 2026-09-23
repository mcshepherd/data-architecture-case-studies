-- Summary of the stand-in ERP, as markdown. Runs on the erp instance as sa.
SET NOCOUNT ON;
USE erp_sim;

DECLARE @tables int, @rows bigint, @cols int, @seed int = (SELECT seed FROM dbo.sim_state);
SELECT @tables = COUNT(*), @rows = SUM(row_count) FROM dbo.design_table;
SELECT @cols = COUNT(*) FROM dbo.design_column;

PRINT '## The stand-in ERP';
PRINT '';
PRINT CONCAT('**', @tables, ' tables, ', FORMAT(@rows, 'N0'), ' rows, ', FORMAT(@cols, 'N0'), ' columns**, generated from seed ',
             @seed, '.');
PRINT '';

PRINT '### Keys';
PRINT '';
PRINT 'Every key starts with an int; most add a code, and some a date or a second code. The catalog declares none of them.';
PRINT '';
PRINT '| Key shape | Key columns | Tables | Rows |';
PRINT '|---|---|---|---|';
DECLARE @line nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT CONCAT('| ', key_shape, ' | ',
                  CASE key_shape WHEN 'I' THEN 'int' WHEN 'IC' THEN 'int, code' WHEN 'ICD' THEN 'int, code, date'
                                 ELSE 'int, code, line code' END, ' | ',
                  COUNT(*), ' | ', FORMAT(SUM(row_count), 'N0'), ' |')
    FROM dbo.design_table GROUP BY key_shape ORDER BY LEN(key_shape), key_shape;
OPEN c; FETCH NEXT FROM c INTO @line;
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END;
CLOSE c; DEALLOCATE c;
PRINT '';

DECLARE @declared int = (SELECT COUNT(*) FROM erp.sys.key_constraints);
DECLARE @unique_idx int = (SELECT COUNT(*) FROM erp.sys.indexes i JOIN erp.sys.tables t ON t.object_id = i.object_id WHERE i.is_unique = 1);
PRINT CONCAT('- Declared primary keys or unique constraints: **', @declared, '**. Unique indexes: **', @unique_idx, '**. Each table has a non-unique clustered index on its key columns.');

-- Check the designed keys really are unique in the data.
DECLARE @sql nvarchar(max) = (
    SELECT STRING_AGG(CAST(CONCAT(
        'SELECT COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT ', k.keys, ' FROM erp.dbo.', QUOTENAME(d.table_name),
        ') x) AS dup FROM erp.dbo.', QUOTENAME(d.table_name)) AS nvarchar(max)), ' UNION ALL ')
    FROM dbo.design_table d
    CROSS APPLY (SELECT STRING_AGG(QUOTENAME(column_name), ',') AS keys FROM dbo.design_column c
                 WHERE c.table_name = d.table_name AND c.role = 'key') k);
DECLARE @dups bigint;
SET @sql = CONCAT('SELECT @dups = SUM(dup) FROM (', @sql, ') z');
EXEC sp_executesql @sql, N'@dups bigint OUTPUT', @dups OUTPUT;
PRINT CONCAT('- Duplicate composite keys across all tables, checked against the data: **', @dups, '**.');

-- Codes with quotes, which break naive dynamic SQL.
SET @sql = (
    SELECT STRING_AGG(CAST(CONCAT('SELECT COUNT(*) AS n FROM erp.dbo.', QUOTENAME(c.table_name), ' WHERE ',
                                  QUOTENAME(c.column_name), ' LIKE ''%''''%''') AS nvarchar(max)), ' UNION ALL ')
    FROM dbo.design_column c WHERE c.role = 'key' AND c.data_type = 'varchar');
DECLARE @quoted bigint;
SET @sql = CONCAT('SELECT @quoted = SUM(n) FROM (', @sql, ') z');
EXEC sp_executesql @sql, N'@quoted bigint OUTPUT', @quoted OUTPUT;
PRINT CONCAT('- Rows whose key contains a quote character: **', FORMAT(@quoted, 'N0'), '**.');
PRINT '';

PRINT '### Create and modify dates';
PRINT '';
DECLARE @dated int = (SELECT COUNT(*) FROM dbo.design_table WHERE has_dates = 1);
SET @sql = (
    SELECT STRING_AGG(CAST(CONCAT(
        'SELECT COUNT(*) AS n, SUM(IIF(created_on IS NULL, 1, 0)) AS no_created, SUM(IIF(modified_on IS NULL, 1, 0)) AS no_modified, ',
        'SUM(IIF(modified_on < created_on, 1, 0)) AS backwards FROM erp.dbo.', QUOTENAME(table_name)) AS nvarchar(max)), ' UNION ALL ')
    FROM dbo.design_table WHERE has_dates = 1);
DECLARE @n bigint, @no_c bigint, @no_m bigint, @back bigint;
SET @sql = CONCAT('SELECT @n = SUM(n), @no_c = SUM(no_created), @no_m = SUM(no_modified), @back = SUM(backwards) FROM (', @sql, ') z');
EXEC sp_executesql @sql, N'@n bigint OUTPUT, @no_c bigint OUTPUT, @no_m bigint OUTPUT, @back bigint OUTPUT',
     @n OUTPUT, @no_c OUTPUT, @no_m OUTPUT, @back OUTPUT;
PRINT CONCAT(@dated, ' of ', @tables, ' tables carry `created_on` and `modified_on`. They cannot be trusted:');
PRINT '';
PRINT CONCAT('- `created_on` is NULL on ', FORMAT(@no_c * 100.0 / @n, 'N1'), '% of rows.');
PRINT CONCAT('- `modified_on` is NULL on ', FORMAT(@no_m * 100.0 / @n, 'N1'), '% of rows.');
PRINT CONCAT('- `modified_on` is earlier than `created_on` on ', FORMAT(@back * 100.0 / @n, 'N1'), '% of rows.');
PRINT '- Nightly updates will sometimes leave `modified_on` unchanged (milestone 2).';
PRINT '';

PRINT '### Columns';
PRINT '';
PRINT 'Hashing a row means casting every column to text, and each type needs its own cast.';
PRINT '';
PRINT '| Type | Columns |';
PRINT '|---|---|';
DECLARE c2 CURSOR LOCAL FAST_FORWARD FOR
    SELECT CONCAT('| ', data_type, ' | ', FORMAT(COUNT(*), 'N0'), ' |') FROM dbo.design_column
    GROUP BY data_type ORDER BY COUNT(*) DESC;
OPEN c2; FETCH NEXT FROM c2 INTO @line;
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c2 INTO @line; END;
CLOSE c2; DEALLOCATE c2;
PRINT '';

DECLARE @wide int = (SELECT COUNT(*) FROM dbo.design_table WHERE is_wide = 1);
DECLARE @widest int = (SELECT MAX(n) FROM (SELECT COUNT(*) AS n FROM dbo.design_column GROUP BY table_name) x);
PRINT CONCAT('Wide tables: ', @wide, ', the widest with ', @widest, ' columns. Their long select lists leave less room for keys in each batch.');
PRINT '';
PRINT 'Text columns include empty strings, quotes, pipes, and non-ASCII characters, so NULL, empty string, and delimiters all have to be handled in the hash.';
