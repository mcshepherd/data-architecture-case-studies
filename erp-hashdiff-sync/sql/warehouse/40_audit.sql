-- Independent audit: does each replica table match the ERP exactly?
-- Runs on the warehouse instance.
--
-- Shares nothing with the sync's comparison. It reads the ERP through its own
-- linked server (ERP_AUDIT: no timeout, no text limit, no wrapper), and it
-- fingerprints each row with SQL Server's JSON rendering and SHA-256 instead of
-- the sync's cast-by-type MD5. A bug in the sync's hashing cannot hide itself.

USE warehouse;
GO

IF SCHEMA_ID('audit') IS NULL EXEC ('CREATE SCHEMA audit');
GO

IF OBJECT_ID('audit.result') IS NULL
    CREATE TABLE audit.result (
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
        PRIMARY KEY (run_id, table_name)
    );
GO

CREATE OR ALTER PROCEDURE audit.usp_audit_table
    @table_name sysname, @run_id int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t nvarchar(300) = QUOTENAME(@table_name);
    DECLARE @cols nvarchar(max), @json nvarchar(max), @key_defs nvarchar(max), @key_list nvarchar(max), @on nvarchar(max);

    SELECT @cols = STRING_AGG(CAST(QUOTENAME(column_name) AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY ordinal),
           @json = STRING_AGG(CAST(CONCAT(N's.', QUOTENAME(column_name), N' AS ', QUOTENAME(column_name)) AS nvarchar(max)), N',')
                   WITHIN GROUP (ORDER BY ordinal)
    FROM sync.source_columns WHERE table_name = @table_name;

    SELECT @key_defs = STRING_AGG(CAST(CONCAT(QUOTENAME(c.column_name), N' ',
                           sync.fn_type_sql(c.data_type, c.char_length, c.num_precision, c.num_scale, c.dt_precision))
                           AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY k.ordinal),
           @key_list = STRING_AGG(CAST(QUOTENAME(c.column_name) AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY k.ordinal),
           @on = STRING_AGG(CAST(CONCAT(N'a.', QUOTENAME(c.column_name), N'=b.', QUOTENAME(c.column_name)) AS nvarchar(max)), N' AND ')
                 WITHIN GROUP (ORDER BY k.ordinal)
    FROM sync.manifest m
    CROSS APPLY STRING_SPLIT(m.key_columns, N',', 1) k
    JOIN sync.source_columns c ON c.table_name = m.table_name AND c.column_name = TRIM(k.value)
    WHERE m.table_name = @table_name;

    DECLARE @fp nvarchar(max) = CONCAT(
        N'CONVERT(char(64),HASHBYTES(''SHA2_256'',(SELECT ', @json, N' FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES)),2)');
    DECLARE @remote nvarchar(max) = CONCAT(N'SELECT ', @key_list, N',', @fp, N' FROM dbo.', @t, N' s');

    DECLARE @sql nvarchar(max) = CONCAT(
        N'CREATE TABLE #src (', @key_defs, N', fp char(64)); ',
        N'CREATE TABLE #rep (', @key_defs, N', fp char(64)); ',
        N'INSERT INTO #src EXEC (@remote) AT ERP_AUDIT; ',
        N'INSERT INTO #rep SELECT ', @key_list, N',', @fp, N' FROM replica.', @t, N' s WHERE _is_deleted = 0; ',
        N'INSERT INTO audit.result (run_id, table_name, source_rows, replica_active, missing, extra, mismatched, duplicate_keys, deleted_but_present) ',
        N'SELECT @run_id, @table_name, ',
        N'(SELECT COUNT(*) FROM #src), (SELECT COUNT(*) FROM #rep), ',
        N'(SELECT COUNT(*) FROM #src a WHERE NOT EXISTS (SELECT 1 FROM #rep b WHERE ', @on, N')), ',
        N'(SELECT COUNT(*) FROM #rep a WHERE NOT EXISTS (SELECT 1 FROM #src b WHERE ', @on, N')), ',
        N'(SELECT COUNT(*) FROM #src a JOIN #rep b ON ', @on, N' WHERE a.fp <> b.fp), ',
        N'(SELECT COUNT(*) FROM (SELECT ', @key_list, N' FROM replica.', @t, N' GROUP BY ', @key_list, N' HAVING COUNT(*) > 1) x), ',
        N'(SELECT COUNT(*) FROM replica.', @t, N' a JOIN #src b ON ', @on, N' WHERE a._is_deleted = 1);');
    DELETE FROM audit.result WHERE run_id = @run_id AND table_name = @table_name;
    EXEC sp_executesql @sql, N'@remote nvarchar(max), @run_id int, @table_name sysname', @remote, @run_id, @table_name;
END;
GO

CREATE OR ALTER PROCEDURE audit.usp_audit_run
    @run_id int
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
        EXEC audit.usp_audit_table @name, @run_id;
        FETCH NEXT FROM t INTO @name;
    END;
    CLOSE t;
    DEALLOCATE t;
END;
GO
