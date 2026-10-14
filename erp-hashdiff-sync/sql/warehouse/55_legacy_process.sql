-- The old process, reproduced for comparison. Runs on the warehouse instance.
--
-- Two SSIS packages, as they were:
--   * full:        empty the table and reload every row. Correct, and slow.
--   * incremental: pull rows whose create or modify date falls in the last N
--                  days, then upsert them on the package's key: update every
--                  local row that matches, insert rows that match nothing.
--                  Nothing detects deletes.
-- The incremental package fails silently in three ways. Rows whose dates are
-- missing or were not updated are never pulled. Deleted rows are never removed.
-- And for composite keys the package's key is missing a column, so one pulled
-- row overwrites every sibling that shares the partial key, key column
-- included, turning distinct rows into duplicates. None of it raises an error.
--
-- The package applied pulled rows one at a time, so when several shared a
-- partial key the last one written won. UPDATE ... FROM would pick one at
-- random, so this picks the last in key order explicitly, and the proofs come
-- out the same on every run.
--
-- It uses the same driver (sync.erp_exec_at) and so the same limits.

USE warehouse;
GO

IF OBJECT_ID('legacy.run') IS NULL
    CREATE TABLE legacy.run (
        run_id      int          IDENTITY PRIMARY KEY,
        run_at      datetime2(0) NOT NULL,
        started_at  datetime2(3) NOT NULL DEFAULT SYSDATETIME()
    );

IF OBJECT_ID('legacy.load_log') IS NULL
    CREATE TABLE legacy.load_log (
        run_id       int            NOT NULL,
        table_name   sysname        NOT NULL,
        load_mode    varchar(11)    NOT NULL,
        rows_pulled  int            NULL,
        updated      int            NULL,
        inserted     int            NULL,
        started_at   datetime2(3)   NOT NULL,
        finished_at  datetime2(3)   NULL,
        message      nvarchar(2000) NULL,
        PRIMARY KEY (run_id, table_name)
    );
GO

CREATE OR ALTER PROCEDURE legacy.usp_load_table
    @table_name sysname, @run_id int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_at datetime2(0) = (SELECT run_at FROM legacy.run WHERE run_id = @run_id);
    DECLARE @mode varchar(11), @upsert_key nvarchar(400), @window int;
    SELECT @mode = load_mode, @upsert_key = upsert_key, @window = window_days FROM legacy.manifest WHERE table_name = @table_name;
    DECLARE @t nvarchar(300) = QUOTENAME(@table_name);
    DECLARE @caller nvarchar(200) = CONCAT(N'legacy:', @run_id, N':', @table_name);
    DECLARE @col_defs nvarchar(max), @col_list nvarchar(max), @sets nvarchar(max), @on nvarchar(max),
            @part nvarchar(max), @last nvarchar(max),
            @remote nvarchar(max), @sql nvarchar(max), @pulled int, @updated int = 0, @inserted int = 0;

    SELECT @col_defs = STRING_AGG(CAST(CONCAT(QUOTENAME(column_name), N' ',
                           sync.fn_type_sql(data_type, char_length, num_precision, num_scale, dt_precision), N' NULL')
                           AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY ordinal),
           @col_list = STRING_AGG(CAST(QUOTENAME(column_name) AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY ordinal),
           @sets = STRING_AGG(CAST(CONCAT(QUOTENAME(column_name), N'=s.', QUOTENAME(column_name)) AS nvarchar(max)), N',')
                   WITHIN GROUP (ORDER BY ordinal)
    FROM sync.source_columns WHERE table_name = @table_name;
    SELECT @on = STRING_AGG(CAST(CONCAT(N't.', QUOTENAME(TRIM(value)), N'=s.', QUOTENAME(TRIM(value))) AS nvarchar(max)), N' AND '),
           @part = STRING_AGG(CAST(QUOTENAME(TRIM(value)) AS nvarchar(max)), N',')
    FROM STRING_SPLIT(@upsert_key, N',');
    -- The ERP's real key orders the siblings; the last one wins.
    SELECT @last = STRING_AGG(CAST(CONCAT(QUOTENAME(TRIM(k.value)), N' DESC') AS nvarchar(max)), N',')
    FROM sync.manifest m CROSS APPLY STRING_SPLIT(m.key_columns, N',') k WHERE m.table_name = @table_name;

    INSERT INTO legacy.load_log (run_id, table_name, load_mode, started_at) VALUES (@run_id, @table_name, @mode, SYSDATETIME());

    BEGIN TRY
        IF OBJECT_ID(N'legacy.' + @t) IS NULL
        BEGIN
            SET @sql = CONCAT(N'CREATE TABLE legacy.', @t, N' (', @col_defs, N');');
            EXEC (@sql);
        END;

        DECLARE @empty bit;
        SET @sql = CONCAT(N'SELECT @e = IIF(EXISTS (SELECT 1 FROM legacy.', @t, N'), 0, 1);');
        EXEC sp_executesql @sql, N'@e bit OUTPUT', @empty OUTPUT;

        IF @mode = 'full' OR @empty = 1
        BEGIN
            -- Full reload: every row, every night.
            SET @remote = CONCAT(N'SELECT ', @col_list, N' FROM dbo.', @t);
            SET @sql = CONCAT(N'TRUNCATE TABLE legacy.', @t, N'; ',
                              N'INSERT INTO legacy.', @t, N' (', @col_list, N') EXEC sync.erp_exec_at @remote, @caller; ',
                              N'SET @p = @@ROWCOUNT;');
            EXEC sp_executesql @sql, N'@remote nvarchar(max), @caller nvarchar(200), @p int OUTPUT', @remote, @caller, @pulled OUTPUT;
            SET @inserted = @pulled;
        END
        ELSE
        BEGIN
            -- Incremental: trust the dates, upsert on the package's key.
            DECLARE @since nchar(19) = CONVERT(nchar(19), DATEADD(day, -@window, @run_at), 120);
            SET @remote = CONCAT(N'SELECT ', @col_list, N' FROM dbo.', @t,
                                 N' WHERE created_on >= ''', @since, N''' OR modified_on >= ''', @since, N'''');
            SET @sql = CONCAT(
                N'CREATE TABLE #s (', @col_defs, N'); ',
                N'INSERT INTO #s (', @col_list, N') EXEC sync.erp_exec_at @remote, @caller; SET @p = @@ROWCOUNT; ',
                N'UPDATE t SET ', @sets, N' FROM legacy.', @t, N' t JOIN (SELECT *, ROW_NUMBER() OVER (PARTITION BY ', @part,
                N' ORDER BY ', @last, N') AS rn__ FROM #s) s ON ', @on, N' AND s.rn__ = 1; SET @u = @@ROWCOUNT; ',
                N'INSERT INTO legacy.', @t, N' (', @col_list, N') SELECT ', @col_list, N' FROM #s s ',
                N'WHERE NOT EXISTS (SELECT 1 FROM legacy.', @t, N' t WHERE ', @on, N'); SET @i = @@ROWCOUNT;');
            EXEC sp_executesql @sql, N'@remote nvarchar(max), @caller nvarchar(200), @p int OUTPUT, @u int OUTPUT, @i int OUTPUT',
                 @remote, @caller, @pulled OUTPUT, @updated OUTPUT, @inserted OUTPUT;
        END;

        UPDATE legacy.load_log SET rows_pulled = @pulled, updated = @updated, inserted = @inserted, finished_at = SYSDATETIME()
        WHERE run_id = @run_id AND table_name = @table_name;
    END TRY
    BEGIN CATCH
        UPDATE legacy.load_log SET finished_at = SYSDATETIME(), message = CONCAT(N'Error ', ERROR_NUMBER(), N': ', ERROR_MESSAGE())
        WHERE run_id = @run_id AND table_name = @table_name;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE legacy.usp_run
    @run_at datetime2(0), @run_id int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO legacy.run (run_at) VALUES (@run_at);
    SET @run_id = SCOPE_IDENTITY();
    DECLARE @name sysname;
    DECLARE t CURSOR LOCAL FAST_FORWARD FOR SELECT table_name FROM legacy.manifest ORDER BY table_name;
    OPEN t;
    FETCH NEXT FROM t INTO @name;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC legacy.usp_load_table @name, @run_id;
        END TRY
        BEGIN CATCH
            -- logged in legacy.load_log; the package carries on with the next table
        END CATCH;
        FETCH NEXT FROM t INTO @name;
    END;
    CLOSE t;
    DEALLOCATE t;
END;
GO

CREATE OR ALTER PROCEDURE legacy.usp_reset
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql nvarchar(max) = (
        SELECT STRING_AGG(CAST(CONCAT(N'DROP TABLE legacy.', QUOTENAME(t.name), N';') AS nvarchar(max)), N' ')
        FROM sys.tables t WHERE t.schema_id = SCHEMA_ID(N'legacy') AND t.name NOT IN (N'manifest', N'run', N'load_log'));
    IF @sql IS NOT NULL EXEC (@sql);
    TRUNCATE TABLE legacy.run;
    TRUNCATE TABLE legacy.load_log;
END;
GO
