-- Independent audit: does each replica table match the ERP exactly?
-- Runs on the warehouse instance.
--
-- Independent of the sync wherever it can be. It reads the ERP through its own
-- linked server (ERP_AUDIT: no timeout, no text limit, no wrapper), takes its
-- column list from the ERP's own catalog rather than the sync's metadata copy,
-- and fingerprints each row with SQL Server's JSON rendering and SHA-256
-- instead of the sync's cast-by-type MD5. A bug in the sync's hashing or a
-- stale metadata copy cannot hide itself. The one thing it shares is the
-- manifest's key columns: the ERP declares no keys, so there is no other source.

USE warehouse;
GO

IF SCHEMA_ID('audit') IS NULL EXEC ('CREATE SCHEMA audit');
GO

IF OBJECT_ID('audit.result') IS NOT NULL AND COL_LENGTH('audit.result', 'copy_name') IS NULL
    DROP TABLE audit.result;
IF OBJECT_ID('audit.result') IS NULL
    CREATE TABLE audit.result (
        copy_name            varchar(7)   NOT NULL,  -- replica (the new process) or legacy (the old one)
        run_id               int          NOT NULL,
        table_name           sysname      NOT NULL,
        audited_at           datetime2(0) NOT NULL DEFAULT SYSDATETIME(),
        source_rows          int          NOT NULL,
        replica_active       int          NOT NULL,
        missing              int          NOT NULL,  -- in the ERP, not active in the replica
        extra                int          NOT NULL,  -- active in the replica, not in the ERP
        mismatched           int          NOT NULL,  -- same key, different values
        duplicate_keys       int          NOT NULL,  -- keys appearing more than once in the replica
        deleted_but_present  int          NOT NULL,  -- flagged deleted, but still in the ERP
        schema_mismatch      int          NOT NULL DEFAULT 0,  -- columns in one and not the other
        PRIMARY KEY (copy_name, run_id, table_name)
    );
IF COL_LENGTH('audit.result', 'schema_mismatch') IS NULL
    ALTER TABLE audit.result ADD schema_mismatch int NOT NULL DEFAULT 0;
GO
-- Every kind of discrepancy, summed: a table audit is clean when this is 0.
IF COL_LENGTH('audit.result', 'problems') IS NULL
    ALTER TABLE audit.result ADD problems AS (missing + extra + mismatched + duplicate_keys + deleted_but_present + schema_mismatch);
GO

CREATE OR ALTER PROCEDURE audit.usp_audit_table
    @table_name sysname, @run_id int, @copy varchar(7) = 'replica'
AS
BEGIN
    SET NOCOUNT ON;
    -- The replica soft-deletes; the legacy copy has no delete flag at all.
    DECLARE @t nvarchar(300) = CONCAT(@copy, N'.', QUOTENAME(@table_name));
    DECLARE @active nvarchar(100) = IIF(@copy = 'replica', N' WHERE _is_deleted = 0', N'');
    DECLARE @flagged nvarchar(100) = IIF(@copy = 'replica', N'a._is_deleted = 1', N'1 = 0');
    DECLARE @json nvarchar(max), @copy_json nvarchar(max), @key_defs nvarchar(max), @key_list nvarchar(max),
            @on nvarchar(max), @schema_mismatch int;

    -- The ERP's columns, from the ERP's own catalog.
    CREATE TABLE #erp_cols (column_name sysname, ordinal int, data_type sysname, char_length int,
                            num_precision int, num_scale int, dt_precision int);
    DECLARE @catalog nvarchar(max) = CONCAT(
        N'SELECT COLUMN_NAME, ORDINAL_POSITION, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE, ',
        N'DATETIME_PRECISION FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = ''dbo'' AND TABLE_NAME = N''',
        REPLACE(@table_name, N'''', N''''''), N'''');
    INSERT INTO #erp_cols EXEC (@catalog) AT ERP_AUDIT;
    -- The copy's columns, from the warehouse catalog.
    SELECT COLUMN_NAME AS column_name INTO #copy_cols FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = @copy AND TABLE_NAME = @table_name
      AND COLUMN_NAME NOT IN (N'_row_hash', N'_loaded_at', N'_is_deleted');

    SELECT @schema_mismatch = COUNT(*) FROM #erp_cols e FULL JOIN #copy_cols c ON c.column_name = e.column_name
    WHERE e.column_name IS NULL OR c.column_name IS NULL;

    -- Both sides fingerprint the ERP's column list. A column the copy lacks is
    -- rendered as NULL on the copy's side, so its rows show as mismatched.
    SELECT @json = STRING_AGG(CAST(CONCAT(N's.', QUOTENAME(e.column_name), N' AS ', QUOTENAME(e.column_name)) AS nvarchar(max)), N',')
                   WITHIN GROUP (ORDER BY e.ordinal),
           @copy_json = STRING_AGG(CAST(CONCAT(IIF(c.column_name IS NULL, N'NULL', N's.' + QUOTENAME(e.column_name)),
                                               N' AS ', QUOTENAME(e.column_name)) AS nvarchar(max)), N',')
                        WITHIN GROUP (ORDER BY e.ordinal)
    FROM #erp_cols e LEFT JOIN #copy_cols c ON c.column_name = e.column_name;

    SELECT @key_defs = STRING_AGG(CAST(CONCAT(QUOTENAME(e.column_name), N' ',
                           sync.fn_type_sql(e.data_type, e.char_length, e.num_precision, e.num_scale, e.dt_precision))
                           AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY k.ordinal),
           @key_list = STRING_AGG(CAST(QUOTENAME(e.column_name) AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY k.ordinal),
           @on = STRING_AGG(CAST(CONCAT(N'a.', QUOTENAME(e.column_name), N'=b.', QUOTENAME(e.column_name)) AS nvarchar(max)), N' AND ')
                 WITHIN GROUP (ORDER BY k.ordinal)
    FROM sync.manifest m
    CROSS APPLY STRING_SPLIT(m.key_columns, N',', 1) k
    JOIN #erp_cols e ON e.column_name = TRIM(k.value)
    WHERE m.table_name = @table_name;

    DECLARE @fp nvarchar(max) = CONCAT(
        N'CONVERT(char(64),HASHBYTES(''SHA2_256'',(SELECT ', @json, N' FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES)),2)');
    DECLARE @copy_fp nvarchar(max) = CONCAT(
        N'CONVERT(char(64),HASHBYTES(''SHA2_256'',(SELECT ', @copy_json, N' FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES)),2)');
    DECLARE @remote nvarchar(max) = CONCAT(N'SELECT ', @key_list, N',', @fp, N' FROM dbo.', QUOTENAME(@table_name), N' s');

    DECLARE @sql nvarchar(max) = CONCAT(
        N'CREATE TABLE #src (', @key_defs, N', fp char(64)); ',
        N'CREATE TABLE #rep (', @key_defs, N', fp char(64)); ',
        N'INSERT INTO #src EXEC (@remote) AT ERP_AUDIT; ',
        N'INSERT INTO #rep SELECT ', @key_list, N',', @copy_fp, N' FROM ', @t, N' s', @active, N'; ',
        N'INSERT INTO audit.result (copy_name, run_id, table_name, source_rows, replica_active, missing, extra, mismatched, duplicate_keys, deleted_but_present, schema_mismatch) ',
        N'SELECT @copy, @run_id, @table_name, ',
        N'(SELECT COUNT(*) FROM #src), (SELECT COUNT(*) FROM #rep), ',
        N'(SELECT COUNT(*) FROM #src a WHERE NOT EXISTS (SELECT 1 FROM #rep b WHERE ', @on, N')), ',
        N'(SELECT COUNT(*) FROM #rep a WHERE NOT EXISTS (SELECT 1 FROM #src b WHERE ', @on, N')), ',
        N'(SELECT COUNT(*) FROM #src a JOIN #rep b ON ', @on, N' WHERE a.fp <> b.fp), ',
        N'(SELECT COUNT(*) FROM (SELECT ', @key_list, N' FROM ', @t, N' GROUP BY ', @key_list, N' HAVING COUNT(*) > 1) x), ',
        N'(SELECT COUNT(*) FROM ', @t, N' a JOIN #src b ON ', @on, N' WHERE ', @flagged, N'), @schema_mismatch;');
    DELETE FROM audit.result WHERE copy_name = @copy AND run_id = @run_id AND table_name = @table_name;
    EXEC sp_executesql @sql, N'@remote nvarchar(max), @run_id int, @table_name sysname, @copy varchar(7), @schema_mismatch int',
         @remote, @run_id, @table_name, @copy, @schema_mismatch;
END;
GO

CREATE OR ALTER PROCEDURE audit.usp_audit_run
    @run_id int, @copy varchar(7) = 'replica'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @name sysname;
    DECLARE t CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name FROM sync.manifest WHERE is_active = 1 ORDER BY table_name;
    OPEN t;
    FETCH NEXT FROM t INTO @name;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC audit.usp_audit_table @name, @run_id, @copy;
        FETCH NEXT FROM t INTO @name;
    END;
    CLOSE t;
    DEALLOCATE t;
END;
GO
