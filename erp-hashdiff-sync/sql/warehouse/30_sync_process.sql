-- The replication process. Runs on the warehouse instance.
--
-- Per table, per night (sync.usp_sync_table):
--   1. Pull every key and a hash of the whole row from the ERP in one query.
--   2. Guard: the pull may not be much smaller than the replica.
--   3. Compare against the replica: new keys, changed hashes, missing keys.
--   4. Prune to the request list: new and changed keys only.
--   5. Send the keys back to the ERP inside the query text, as a VALUES list,
--      in batches sized to the driver's text limit. Stage the rows locally.
--   6. In one transaction: flag deletes, remove changed rows, insert staged rows.
--   7. Validate every count before committing.
--   8. Log the counts, then drop staging.
--
-- Everything sent to the ERP is generated from the metadata copy and the manifest.

USE warehouse;
GO

IF SCHEMA_ID('replica') IS NULL EXEC ('CREATE SCHEMA replica');
IF SCHEMA_ID('stage') IS NULL EXEC ('CREATE SCHEMA stage');
GO

MERGE sync.config AS t
USING (VALUES
    (N'batch_row_cap', N'5000')         -- rows per fetch batch, whatever the text limit allows
) AS s (name, value)
ON t.name = s.name
WHEN MATCHED THEN UPDATE SET value = s.value
WHEN NOT MATCHED THEN INSERT (name, value) VALUES (s.name, s.value);
GO

-- Local plaintext copy of the ERP's column metadata.
IF OBJECT_ID('sync.source_columns') IS NULL
    CREATE TABLE sync.source_columns (
        table_catalog  sysname NOT NULL,
        table_schema   sysname NOT NULL,
        table_name     sysname NOT NULL,
        column_name    sysname NOT NULL,
        ordinal        int     NOT NULL,
        data_type      sysname NOT NULL,
        char_length    int     NULL,
        num_precision  int     NULL,
        num_scale      int     NULL,
        dt_precision   int     NULL,
        PRIMARY KEY (table_name, column_name)
    );
GO

IF OBJECT_ID('sync.run') IS NULL
    CREATE TABLE sync.run (
        run_id      int          IDENTITY PRIMARY KEY,
        run_at      datetime2(0) NOT NULL,  -- the load time stamped on every row this run writes
        started_at  datetime2(3) NOT NULL DEFAULT SYSDATETIME(),
        wipe        bit          NOT NULL DEFAULT 0
    );

IF OBJECT_ID('sync.run_table_log') IS NULL
    CREATE TABLE sync.run_table_log (
        log_id          int            IDENTITY PRIMARY KEY,
        run_id          int            NOT NULL,
        table_name      sysname        NOT NULL,
        status          varchar(12)    NOT NULL,  -- running, succeeded, failed, variance
        started_at      datetime2(3)   NOT NULL,
        finished_at     datetime2(3)   NULL,
        pulled_keys     int            NULL,
        active_before   int            NULL,
        new_keys        int            NULL,
        changed_keys    int            NULL,
        deleted_keys    int            NULL,
        requested       int            NULL,
        batches         int            NULL,
        max_batch_keys  int            NULL,
        fetched         int            NULL,
        batch_retries   int            NULL,
        flagged_deleted int            NULL,
        removed         int            NULL,
        inserted        int            NULL,
        active_after    int            NULL,
        driver_calls    int            NULL,
        max_sql_chars   int            NULL,
        message         nvarchar(2000) NULL
    );
GO

-- Refresh the metadata copy. Run on demand, when the vendor adds fields.
CREATE OR ALTER PROCEDURE sync.usp_probe_metadata
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #c (
        table_catalog sysname, table_schema sysname, table_name sysname, column_name sysname, ordinal int,
        data_type sysname, char_length int, num_precision int, num_scale int, dt_precision int);
    INSERT INTO #c EXEC sync.erp_exec_at
        N'SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, DATA_TYPE,
                 CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE, DATETIME_PRECISION
          FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = ''dbo''', N'probe';
    BEGIN TRAN;
    DELETE FROM sync.source_columns;
    INSERT INTO sync.source_columns SELECT * FROM #c;
    COMMIT;
END;
GO

-- Column type as DDL.
CREATE OR ALTER FUNCTION sync.fn_type_sql (
    @data_type sysname, @char_length int, @num_precision int, @num_scale int, @dt_precision int)
RETURNS nvarchar(100)
AS
BEGIN
    RETURN CASE
        WHEN @data_type IN (N'varchar', N'nvarchar', N'char', N'nchar', N'varbinary', N'binary')
            THEN CONCAT(@data_type, N'(', IIF(@char_length = -1, N'max', CAST(@char_length AS nvarchar(10))), N')')
        WHEN @data_type IN (N'decimal', N'numeric') THEN CONCAT(@data_type, N'(', @num_precision, N', ', @num_scale, N')')
        WHEN @data_type IN (N'datetime2', N'time', N'datetimeoffset') THEN CONCAT(@data_type, N'(', @dt_precision, N')')
        ELSE @data_type END;
END;
GO

-- One column's contribution to the row hash, as two CONCAT arguments: the
-- delimiter, then the value as text, cast by type, with NULL replaced by a
-- marker no text value contains. @d and @n are declared at the top of the
-- statement sent to the ERP.
-- Each type needs its own cast: the default conversions round money to two
-- places, drop float precision, and cut datetime to the minute. A type not
-- listed returns NULL, and the sync refuses the table rather than guess.
CREATE OR ALTER FUNCTION sync.fn_hash_piece (@column_name sysname, @data_type sysname)
RETURNS nvarchar(400)
AS
BEGIN
    DECLARE @c nvarchar(300) = QUOTENAME(@column_name);
    DECLARE @text nvarchar(400) = CASE
        WHEN @data_type IN (N'varchar', N'char', N'nvarchar', N'nchar') THEN @c
        WHEN @data_type IN (N'int', N'bigint', N'smallint', N'tinyint', N'bit') THEN CONCAT(N'CONVERT(varchar(20),', @c, N')')
        WHEN @data_type IN (N'decimal', N'numeric') THEN CONCAT(N'CONVERT(varchar(40),', @c, N')')
        WHEN @data_type IN (N'money', N'smallmoney') THEN CONCAT(N'CONVERT(varchar(30),', @c, N',2)')
        WHEN @data_type IN (N'float', N'real') THEN CONCAT(N'CONVERT(varchar(30),', @c, N',3)')
        WHEN @data_type = N'date' THEN CONCAT(N'CONVERT(char(10),', @c, N',23)')
        WHEN @data_type IN (N'datetime', N'smalldatetime', N'datetime2') THEN CONCAT(N'CONVERT(varchar(27),', @c, N',121)')
        WHEN @data_type = N'uniqueidentifier' THEN CONCAT(N'CONVERT(char(36),', @c, N')')
        WHEN @data_type = N'time' THEN CONCAT(N'CONVERT(varchar(16),', @c, N')')
        WHEN @data_type = N'datetimeoffset' THEN CONCAT(N'CONVERT(varchar(34),', @c, N',127)')
        WHEN @data_type IN (N'binary', N'varbinary') THEN CONCAT(N'CONVERT(varchar(max),', @c, N',1)')
    END;
    -- NULL for a type with no cast here; the sync refuses such a table by name.
    RETURN IIF(@text IS NULL, NULL, CONCAT(N'@d,ISNULL(', @text, N',@n)'));
END;
GO

-- A key value as a SQL literal for the VALUES list, from stage alias h.
-- Quotes inside codes are doubled; without this, one quoted code breaks the batch.
-- NULL for a type with no literal form here; the sync refuses such a key.
CREATE OR ALTER FUNCTION sync.fn_literal_sql (@column_name sysname, @data_type sysname)
RETURNS nvarchar(400)
AS
BEGIN
    DECLARE @c nvarchar(300) = CONCAT(N'h.', QUOTENAME(@column_name));
    RETURN CASE
        WHEN @data_type IN (N'int', N'bigint', N'smallint', N'tinyint', N'bit', N'decimal', N'numeric')
            THEN CONCAT(N'CONVERT(varchar(40),', @c, N')')
        WHEN @data_type IN (N'varchar', N'char')
            THEN CONCAT(N'CONCAT(CHAR(39),REPLACE(', @c, N',CHAR(39),CHAR(39)+CHAR(39)),CHAR(39))')
        WHEN @data_type IN (N'nvarchar', N'nchar')
            THEN CONCAT(N'CONCAT(N''N'',NCHAR(39),REPLACE(', @c, N',NCHAR(39),NCHAR(39)+NCHAR(39)),NCHAR(39))')
        WHEN @data_type IN (N'money', N'smallmoney') THEN CONCAT(N'CONVERT(varchar(40),', @c, N',2)')
        WHEN @data_type IN (N'float', N'real') THEN CONCAT(N'CONVERT(varchar(30),', @c, N',3)')
        WHEN @data_type = N'date' THEN CONCAT(N'CONCAT(CHAR(39),CONVERT(char(10),', @c, N',23),CHAR(39))')
        WHEN @data_type IN (N'datetime', N'smalldatetime', N'datetime2')
            THEN CONCAT(N'CONCAT(CHAR(39),CONVERT(varchar(27),', @c, N',121),CHAR(39))')
        WHEN @data_type = N'time' THEN CONCAT(N'CONCAT(CHAR(39),CONVERT(varchar(16),', @c, N'),CHAR(39))')
        WHEN @data_type = N'datetimeoffset' THEN CONCAT(N'CONCAT(CHAR(39),CONVERT(varchar(34),', @c, N',127),CHAR(39))')
        WHEN @data_type = N'uniqueidentifier' THEN CONCAT(N'CONCAT(CHAR(39),CONVERT(char(36),', @c, N'),CHAR(39))')
    END;
END;
GO

-- The tables a run set out to sync, so a table that never started still counts.
IF OBJECT_ID('sync.run_plan') IS NULL
    CREATE TABLE sync.run_plan (
        run_id      int     NOT NULL,
        table_name  sysname NOT NULL,
        PRIMARY KEY (run_id, table_name)
    );
GO

CREATE OR ALTER PROCEDURE sync.usp_plan_run
    @run_id int, @tables nvarchar(max)  -- comma-separated
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO sync.run_plan (run_id, table_name)
    SELECT DISTINCT @run_id, TRIM(value) FROM STRING_SPLIT(@tables, N',') WHERE TRIM(value) <> N'';
END;
GO

-- Each table's outcome in a run: its last attempt. The one definition the
-- runner's summary, its exit code, and the alert all use.
--   succeeded / failed / variance  as logged
--   interrupted                    the last attempt never finished (its session ended)
--   not started                    planned, but no attempt was ever logged
CREATE OR ALTER FUNCTION sync.fn_run_outcome (@run_id int)
RETURNS TABLE
AS
RETURN
    WITH t AS (
        SELECT table_name FROM sync.run_plan WHERE run_id = @run_id
        UNION
        SELECT table_name FROM sync.run_table_log WHERE run_id = @run_id),
    l AS (
        SELECT table_name, status, message,
               ROW_NUMBER() OVER (PARTITION BY table_name ORDER BY log_id DESC) AS rn,
               COUNT(*) OVER (PARTITION BY table_name) AS attempts
        FROM sync.run_table_log WHERE run_id = @run_id)
    SELECT t.table_name,
           CASE WHEN l.status IS NULL THEN 'not started' WHEN l.status = 'running' THEN 'interrupted' ELSE l.status END AS status,
           ISNULL(l.attempts, 0) AS attempts,
           l.message
    FROM t LEFT JOIN l ON l.table_name = t.table_name AND l.rn = 1;
GO

CREATE OR ALTER PROCEDURE sync.usp_start_run
    @run_at datetime2(0) = NULL, @wipe bit = 0, @run_id int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO sync.run (run_at, wipe) VALUES (ISNULL(@run_at, SYSDATETIME()), @wipe);
    SET @run_id = SCOPE_IDENTITY();
END;
GO

CREATE OR ALTER PROCEDURE sync.usp_sync_table
    @table_name sysname,
    @run_id     int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @run_at datetime2(0), @wipe bit;
    SELECT @run_at = run_at, @wipe = wipe FROM sync.run WHERE run_id = @run_id;
    DECLARE @caller nvarchar(200) = CONCAT(@run_id, N':', @table_name);
    DECLARE @limit int = (SELECT CAST(value AS int) FROM sync.config WHERE name = N'text_limit');
    DECLARE @row_cap int = (SELECT CAST(value AS int) FROM sync.config WHERE name = N'batch_row_cap');
    DECLARE @key_columns nvarchar(400), @allowance decimal(5, 4);
    SELECT @key_columns = key_columns, @allowance = shrink_allowance FROM sync.manifest WHERE table_name = @table_name;

    DECLARE @log_id int;
    INSERT INTO sync.run_table_log (run_id, table_name, status, started_at)
    VALUES (@run_id, @table_name, 'running', SYSDATETIME());
    SET @log_id = SCOPE_IDENTITY();

    DECLARE @sql nvarchar(max), @remote nvarchar(max), @msg nvarchar(2000),
            @pulled int, @active_before int, @new int, @changed int, @deleted int, @requested int,
            @batches int = 0, @max_batch_keys int = 0, @fetched int = 0, @retries int = 0,
            @flagged int = 0, @removed int = 0, @inserted int = 0, @active_after int, @committed bit = 0;

    DECLARE @lock nvarchar(255) = CONCAT(N'sync:', @table_name), @lock_rc int;

    BEGIN TRY
        -- One sync of a table at a time: staging tables are per table.
        EXEC @lock_rc = sp_getapplock @Resource = @lock, @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 0;
        IF @lock_rc < 0
            THROW 50024, 'Another sync of this table is already running.', 1;

        IF @key_columns IS NULL
            THROW 50020, 'Table is not in the manifest.', 1;
        IF NOT EXISTS (SELECT 1 FROM sync.source_columns WHERE table_name = @table_name)
            THROW 50021, 'No metadata for this table. Run sync.usp_probe_metadata.', 1;

        -- Key columns from the manifest, typed from the metadata copy.
        DECLARE @keys TABLE (ord int, column_name sysname, data_type sysname, type_sql nvarchar(100));
        INSERT INTO @keys
        SELECT k.ordinal, c.column_name, c.data_type,
               sync.fn_type_sql(c.data_type, c.char_length, c.num_precision, c.num_scale, c.dt_precision)
        FROM STRING_SPLIT(@key_columns, N',', 1) k
        LEFT JOIN sync.source_columns c ON c.table_name = @table_name AND c.column_name = TRIM(k.value);
        IF EXISTS (SELECT 1 FROM @keys WHERE data_type IS NULL)
            THROW 50022, 'A manifest key column does not exist in the metadata.', 1;

        -- Refuse types this sync has no cast for, by name, rather than send malformed SQL.
        DECLARE @unsupported nvarchar(2000) = (
            SELECT STRING_AGG(CONCAT(column_name, N' (', data_type, N')'), N', ') FROM (
                SELECT column_name, data_type FROM sync.source_columns
                WHERE table_name = @table_name AND sync.fn_hash_piece(column_name, data_type) IS NULL
                UNION
                SELECT column_name, data_type FROM @keys WHERE sync.fn_literal_sql(column_name, data_type) IS NULL) x);
        IF @unsupported IS NOT NULL
        BEGIN
            SET @msg = CONCAT(N'Unsupported column types: ', @unsupported, N'.');
            THROW 50025, @msg, 1;
        END;

        -- Generated fragments.
        DECLARE @t nvarchar(300) = QUOTENAME(@table_name);
        DECLARE @hk nvarchar(300) = QUOTENAME(@table_name + N'__hashkey');
        DECLARE @del nvarchar(300) = QUOTENAME(@table_name + N'__deleted');
        DECLARE @rows nvarchar(300) = QUOTENAME(@table_name + N'__rows');
        DECLARE @col_defs nvarchar(max), @col_list nvarchar(max), @s_col_list nvarchar(max), @r_col_list nvarchar(max),
                @hash nvarchar(max), @key_defs nvarchar(max), @key_list nvarchar(max), @literal nvarchar(max),
                @on_ht nvarchar(max), @on_hr nvarchar(max), @on_td nvarchar(max), @on_sv nvarchar(max),
                @order nvarchar(max), @first_key nvarchar(300);

        SELECT @col_defs = STRING_AGG(CAST(CONCAT(QUOTENAME(column_name), N' ',
                               sync.fn_type_sql(data_type, char_length, num_precision, num_scale, dt_precision), N' NULL')
                               AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY ordinal),
               @col_list = STRING_AGG(CAST(QUOTENAME(column_name) AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY ordinal),
               @s_col_list = STRING_AGG(CAST(N's.' + QUOTENAME(column_name) AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY ordinal),
               @r_col_list = STRING_AGG(CAST(N'r.' + QUOTENAME(column_name) AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY ordinal),
               @hash = NULL
        FROM sync.source_columns WHERE table_name = @table_name;

        -- The row hash: MD5 over every column, keys included. Nested CONCATs,
        -- 126 columns each, because CONCAT takes at most 254 arguments. Each
        -- CONCAT starts with @m, a varchar(max), because without a large-object
        -- argument CONCAT silently truncates at 8,000 characters and a change
        -- past that point would go unseen. (Chaining + instead is about 30 times
        -- slower on wide tables.)
        WITH p AS (SELECT ordinal, sync.fn_hash_piece(column_name, data_type) AS piece,
                          (ROW_NUMBER() OVER (ORDER BY ordinal) - 1) / 126 AS grp
                   FROM sync.source_columns WHERE table_name = @table_name),
             g AS (SELECT grp, CONCAT(N'CONCAT(@m,', STRING_AGG(CAST(piece AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY ordinal),
                                      N')') AS c
                   FROM p GROUP BY grp)
        SELECT @hash = CONCAT(N'CONVERT(char(32),HASHBYTES(''MD5'',CONCAT(@m,',
                              STRING_AGG(CAST(c AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY grp), N')),2)')
        FROM g;

        SELECT @key_defs = STRING_AGG(CAST(CONCAT(QUOTENAME(column_name), N' ', type_sql, N' NOT NULL') AS nvarchar(max)), N', ')
                           WITHIN GROUP (ORDER BY ord),
               @key_list = STRING_AGG(CAST(QUOTENAME(column_name) AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY ord),
               @literal = CONCAT(N'CONCAT(''('',', STRING_AGG(CAST(sync.fn_literal_sql(column_name, data_type) AS nvarchar(max)), N','','',')
                                     WITHIN GROUP (ORDER BY ord), N','')'')'),
               @on_ht = STRING_AGG(CAST(CONCAT(N'h.', QUOTENAME(column_name), N'=t.', QUOTENAME(column_name)) AS nvarchar(max)), N' AND ')
                        WITHIN GROUP (ORDER BY ord),
               @on_hr = STRING_AGG(CAST(CONCAT(N'h.', QUOTENAME(column_name), N'=r.', QUOTENAME(column_name)) AS nvarchar(max)), N' AND ')
                        WITHIN GROUP (ORDER BY ord),
               @on_td = STRING_AGG(CAST(CONCAT(N't.', QUOTENAME(column_name), N'=d.', QUOTENAME(column_name)) AS nvarchar(max)), N' AND ')
                        WITHIN GROUP (ORDER BY ord),
               @on_sv = STRING_AGG(CAST(CONCAT(N's.', QUOTENAME(column_name), N'=v.', QUOTENAME(column_name)) AS nvarchar(max)), N' AND ')
                        WITHIN GROUP (ORDER BY ord),
               @order = STRING_AGG(CAST(N'h.' + QUOTENAME(column_name) AS nvarchar(max)), N',') WITHIN GROUP (ORDER BY ord),
               @first_key = MIN(IIF(ord = 1, QUOTENAME(column_name), NULL))
        FROM @keys;

        -- First run: create the replica table from the metadata copy.
        IF OBJECT_ID(N'replica.' + @t) IS NULL
        BEGIN
            SET @sql = CONCAT(N'CREATE TABLE replica.', @t, N' (', @col_defs,
                              N', _row_hash char(32) NOT NULL, _loaded_at datetime2(0) NOT NULL, _is_deleted bit NOT NULL); ',
                              N'CREATE CLUSTERED INDEX cx ON replica.', @t, N' (', @key_list, N');');
            EXEC (@sql);
        END;
        ELSE
        BEGIN
            -- Schema drift: the replica must match the ERP's columns exactly. A
            -- vendor update that adds, drops, or retypes a column stops the table
            -- here, by name. The fix is to rebuild: drop the replica table, and the
            -- next run reloads it from scratch.
            DECLARE @drift nvarchar(2000);
            WITH src AS (
                SELECT column_name, sync.fn_type_sql(data_type, char_length, num_precision, num_scale, dt_precision) AS type_sql
                FROM sync.source_columns WHERE table_name = @table_name),
            rep AS (
                SELECT COLUMN_NAME AS column_name,
                       sync.fn_type_sql(DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE, DATETIME_PRECISION) AS type_sql
                FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_SCHEMA = N'replica' AND TABLE_NAME = @table_name
                  AND COLUMN_NAME NOT IN (N'_row_hash', N'_loaded_at', N'_is_deleted'))
            SELECT @drift = STRING_AGG(CAST(CONCAT(COALESCE(src.column_name, rep.column_name), N' ', CASE
                    WHEN rep.column_name IS NULL THEN N'added in the ERP'
                    WHEN src.column_name IS NULL THEN N'dropped from the ERP'
                    ELSE CONCAT(N'changed from ', rep.type_sql, N' to ', src.type_sql) END) AS nvarchar(max)), N'; ')
            FROM src FULL JOIN rep ON rep.column_name = src.column_name
            WHERE src.column_name IS NULL OR rep.column_name IS NULL OR src.type_sql <> rep.type_sql;
            IF @drift IS NOT NULL
            BEGIN
                SET @msg = LEFT(CONCAT(N'Schema drift: ', @drift, N'. Rebuild: drop replica.', @t,
                                       N' and the next run reloads it.'), 2000);
                THROW 50023, @msg, 1;
            END;
        END;

        -- Fresh staging tables.
        SET @sql = CONCAT(
            N'DROP TABLE IF EXISTS stage.', @hk, N'; DROP TABLE IF EXISTS stage.', @del, N'; DROP TABLE IF EXISTS stage.', @rows, N'; ',
            N'CREATE TABLE stage.', @hk, N' (', @key_defs, N', _row_hash char(32) NOT NULL, _action char(1) NULL, ',
            N'_key_literal nvarchar(max) NULL, _batch int NULL); ',
            N'CREATE CLUSTERED INDEX cx ON stage.', @hk, N' (', @key_list, N'); ',
            N'CREATE TABLE stage.', @del, N' (', @key_defs, N'); ',
            N'CREATE TABLE stage.', @rows, N' (', @col_defs, N'); ');
        EXEC (@sql);

        -- 1. Every key and its row hash, in one query.
        SET @remote = CONCAT(N'DECLARE @d varchar(3)=''$|$'',@n char(1)=CHAR(0),@m varchar(max)='''';SELECT ', @key_list, N',', @hash, N' FROM dbo.', @t);
        SET @sql = CONCAT(N'INSERT INTO stage.', @hk, N' (', @key_list, N',_row_hash) EXEC sync.erp_exec_at @remote, @caller; ',
                          N'SET @rc = @@ROWCOUNT;');
        EXEC sp_executesql @sql, N'@remote nvarchar(max), @caller nvarchar(200), @rc int OUTPUT', @remote, @caller, @pulled OUTPUT;

        -- 2. Guard against a short pull. The replica may shrink by deletes, but only so far.
        SET @sql = CONCAT(N'SELECT @rc = COUNT(*) FROM replica.', @t, N' WHERE _is_deleted = 0');
        EXEC sp_executesql @sql, N'@rc int OUTPUT', @active_before OUTPUT;
        IF @wipe = 0 AND @active_before > 0 AND @pulled < @active_before * (1 - @allowance)
        BEGIN
            SET @msg = CONCAT(N'Variance guard: pulled ', @pulled, N' keys, replica has ', @active_before,
                              N' active rows, allowance ', CAST(@allowance * 100 AS decimal(5, 1)), N' percent.');
            -- (THROW reserves the percent sign, so it is spelled out.)
            THROW 50010, @msg, 1;
        END;

        -- 3. Compare. New: not in the replica. Changed: hash differs, or the key was
        --    deleted before and has come back. Deleted: active in the replica, not pulled.
        --    A wipe treats every pulled key as new; the old rows go in step 6.
        IF @wipe = 1
            SET @sql = CONCAT(
                N'UPDATE stage.', @hk, N' SET _action = ''N''; ',
                N'SELECT @new = COUNT(*), @changed = 0 FROM stage.', @hk, N'; SET @deleted = 0;');
        ELSE
        SET @sql = CONCAT(
            N'UPDATE h SET _action = CASE WHEN t.', @first_key, N' IS NULL THEN ''N'' ',
            N'WHEN t._is_deleted = 1 OR t._row_hash <> h._row_hash THEN ''C'' END ',
            N'FROM stage.', @hk, N' h LEFT JOIN replica.', @t, N' t ON ', @on_ht, N'; ',
            N'INSERT INTO stage.', @del, N' (', @key_list, N') SELECT ', REPLACE(@order, N'h.', N't.'),
            N' FROM replica.', @t, N' t WHERE t._is_deleted = 0 AND NOT EXISTS (SELECT 1 FROM stage.', @hk, N' h WHERE ', @on_ht, N'); ',
            N'SELECT @new = SUM(IIF(_action = ''N'', 1, 0)), @changed = SUM(IIF(_action = ''C'', 1, 0)) FROM stage.', @hk, N'; ',
            N'SELECT @deleted = COUNT(*) FROM stage.', @del, N';');
        EXEC sp_executesql @sql, N'@new int OUTPUT, @changed int OUTPUT, @deleted int OUTPUT',
             @new OUTPUT, @changed OUTPUT, @deleted OUTPUT;
        SELECT @new = ISNULL(@new, 0), @changed = ISNULL(@changed, 0);

        -- 4. Prune to the request list.
        SET @sql = CONCAT(N'DELETE FROM stage.', @hk, N' WHERE _action IS NULL;');
        EXEC (@sql);
        SET @requested = @new + @changed;

        -- 5. Batch the request list and fetch. Each key becomes a literal tuple in a
        --    VALUES list inside the statement. The statement's fixed text (mostly the
        --    select list) plus the literals must fit the text limit, so wide tables
        --    get fewer keys per batch. Batches are also capped in rows.
        DECLARE @template nvarchar(max) = CONCAT(
            N'SELECT ', @s_col_list, N' FROM dbo.', @t, N' s JOIN (VALUES {v}) v(', @key_list, N') ON ', @on_sv);
        DECLARE @fixed int = LEN(@template) - 3, @max_literal int, @room int;

        IF @requested > 0
        BEGIN
            SET @sql = CONCAT(N'UPDATE h SET _key_literal = ', @literal, N' FROM stage.', @hk, N' h; ',
                              N'SELECT @m = MAX(LEN(_key_literal)) FROM stage.', @hk, N';');
            EXEC sp_executesql @sql, N'@m int OUTPUT', @max_literal OUTPUT;
            SET @room = @limit - @fixed;
            IF @room <= @max_literal
            BEGIN
                SET @msg = CONCAT(N'The fixed statement text is ', @fixed, N' characters; no room for keys under ', @limit, N'.');
                THROW 50011, @msg, 1;
            END;

            -- Running length of literals (each plus a comma). A batch closes before
            -- the running length passes the room left, and at the row cap.
            SET @sql = CONCAT(
                N'WITH a AS (SELECT _batch, SUM(LEN(_key_literal) + 1) OVER (ORDER BY ', @order, N' ROWS UNBOUNDED PRECEDING) AS running_len ',
                N'           FROM stage.', @hk, N' h), ',
                N'b AS (SELECT _batch, running_len, (running_len - 1) / (@room - @m) AS char_batch FROM a), ',
                N'c AS (SELECT _batch, char_batch, ROW_NUMBER() OVER (PARTITION BY char_batch ORDER BY running_len) AS rn FROM b), ',
                N'd AS (SELECT _batch, DENSE_RANK() OVER (ORDER BY char_batch, (rn - 1) / @cap) AS nb FROM c) ',
                N'UPDATE d SET _batch = nb; ',
                N'SELECT @batches = MAX(_batch) FROM stage.', @hk, N';',
                N'SELECT @maxk = MAX(n) FROM (SELECT COUNT(*) AS n FROM stage.', @hk, N' GROUP BY _batch) x;');
            EXEC sp_executesql @sql, N'@room int, @m int, @cap int, @batches int OUTPUT, @maxk int OUTPUT',
                 @room, @max_literal, @row_cap, @batches OUTPUT, @max_batch_keys OUTPUT;

            DECLARE @b int = 1, @try int, @values nvarchar(max);
            WHILE @b <= @batches
            BEGIN
                SET @sql = CONCAT(N'SELECT @v = STRING_AGG(CAST(_key_literal AS nvarchar(max)), N'','') ',
                                  N'WITHIN GROUP (ORDER BY ', REPLACE(@order, N'h.', N''), N') FROM stage.', @hk, N' WHERE _batch = @b;');
                EXEC sp_executesql @sql, N'@b int, @v nvarchar(max) OUTPUT', @b, @values OUTPUT;
                SET @remote = REPLACE(@template, N'{v}', @values);
                SET @sql = CONCAT(N'INSERT INTO stage.', @rows, N' (', @col_list, N') EXEC sync.erp_exec_at @remote, @caller;');

                -- Up to three attempts per batch. A failed INSERT ... EXEC inserts nothing.
                SET @try = 1;
                WHILE 1 = 1
                BEGIN
                    BEGIN TRY
                        EXEC sp_executesql @sql, N'@remote nvarchar(max), @caller nvarchar(200)', @remote, @caller;
                        BREAK;
                    END TRY
                    BEGIN CATCH
                        IF @try >= 3 THROW;
                        SET @try += 1;
                        SET @retries += 1;
                    END CATCH;
                END;
                SET @b += 1;
            END;

            SET @sql = CONCAT(N'SELECT @rc = COUNT(*) FROM stage.', @rows);
            EXEC sp_executesql @sql, N'@rc int OUTPUT', @fetched OUTPUT;
            IF @fetched <> @requested
            BEGIN
                SET @msg = CONCAT(N'Requested ', @requested, N' rows, fetched ', @fetched, N'.');
                THROW 50012, @msg, 1;
            END;
        END;

        -- 6. Apply everything in one transaction. The stored hash is the ERP's own,
        --    from the pull, so the next night compares like with like. A wipe
        --    empties the replica here, inside the transaction, so a wipe that fails
        --    anywhere earlier leaves the old rows in place.
        SET @sql = CONCAT(
            IIF(@wipe = 1,
                CONCAT(N'SET @f = 0; DELETE FROM replica.', @t, N'; SET @r = @@ROWCOUNT; '),
                CONCAT(N'UPDATE t SET _is_deleted = 1 FROM replica.', @t, N' t JOIN stage.', @del, N' d ON ', @on_td, N'; SET @f = @@ROWCOUNT; ',
                       N'DELETE t FROM replica.', @t, N' t JOIN stage.', @hk, N' h ON ', @on_ht, N' WHERE h._action = ''C''; SET @r = @@ROWCOUNT; ')),
            N'INSERT INTO replica.', @t, N' (', @col_list, N', _row_hash, _loaded_at, _is_deleted) ',
            N'SELECT ', @r_col_list, N', h._row_hash, @run_at, 0 FROM stage.', @rows, N' r JOIN stage.', @hk, N' h ON ', @on_hr, N'; ',
            N'SET @i = @@ROWCOUNT; ',
            N'SELECT @a = COUNT(*) FROM replica.', @t, N' WHERE _is_deleted = 0;');

        BEGIN TRAN;
        EXEC sp_executesql @sql, N'@run_at datetime2(0), @f int OUTPUT, @r int OUTPUT, @i int OUTPUT, @a int OUTPUT',
             @run_at, @flagged OUTPUT, @removed OUTPUT, @inserted OUTPUT, @active_after OUTPUT;
        -- 7. Validate before committing: every count must reconcile, and the
        --    replica must now hold exactly the keys that were pulled.
        IF @flagged <> @deleted OR (@wipe = 0 AND @removed <> @changed) OR @inserted <> @requested OR @active_after <> @pulled
        BEGIN
            SET @msg = CONCAT(N'Counts do not reconcile: deleted ', @deleted, N'/', @flagged, N', changed ', @changed, N'/', @removed,
                              N', requested ', @requested, N'/', @inserted, N', pulled ', @pulled, N'/active ', @active_after, N'.');
            THROW 50013, @msg, 1;
        END;
        COMMIT;
        SET @committed = 1;

        -- 8. Log every count, then drop staging. The changes are committed by now, so an
        --    error from here on is a logging or cleanup error, not a failed sync.
        UPDATE sync.run_table_log
        SET status = 'succeeded', finished_at = SYSDATETIME(), pulled_keys = @pulled, active_before = @active_before,
            new_keys = @new, changed_keys = @changed, deleted_keys = @deleted, requested = @requested,
            batches = @batches, max_batch_keys = @max_batch_keys, fetched = @fetched, batch_retries = @retries,
            flagged_deleted = @flagged, removed = @removed, inserted = @inserted, active_after = @active_after,
            driver_calls = (SELECT COUNT(*) FROM sync.driver_log WHERE caller = @caller),
            max_sql_chars = (SELECT MAX(sql_chars) FROM sync.driver_log WHERE caller = @caller)
        WHERE log_id = @log_id;
        -- Drop staging only once the log records success.
        IF @@ROWCOUNT <> 1
            THROW 50014, 'The log row for this run is missing, so staging was kept.', 1;
        SET @sql = CONCAT(N'DROP TABLE stage.', @hk, N'; DROP TABLE stage.', @del, N'; DROP TABLE stage.', @rows, N';');
        EXEC (@sql);
        EXEC sp_releaseapplock @Resource = @lock, @LockOwner = 'Session';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF APPLOCK_MODE(N'public', @lock, N'Session') <> N'NoLock'
            EXEC sp_releaseapplock @Resource = @lock, @LockOwner = 'Session';
        IF @committed = 1
        BEGIN
            -- The replica is already right. Keep the success, record the error, and
            -- leave staging for the next run to replace. Raise only if nothing can be logged.
            UPDATE sync.run_table_log
            SET status = 'succeeded', finished_at = ISNULL(finished_at, SYSDATETIME()),
                message = CONCAT(N'Applied, then error ', ERROR_NUMBER(), N': ', ERROR_MESSAGE())
            WHERE log_id = @log_id;
            IF @@ROWCOUNT = 1 RETURN;
            THROW;
        END;
        UPDATE sync.run_table_log
        SET status = IIF(ERROR_NUMBER() = 50010, 'variance', 'failed'), finished_at = SYSDATETIME(),
            pulled_keys = @pulled, active_before = @active_before, new_keys = @new, changed_keys = @changed,
            deleted_keys = @deleted, requested = @requested, batches = @batches, max_batch_keys = @max_batch_keys,
            fetched = @fetched, batch_retries = @retries,
            driver_calls = (SELECT COUNT(*) FROM sync.driver_log WHERE caller = @caller),
            max_sql_chars = (SELECT MAX(sql_chars) FROM sync.driver_log WHERE caller = @caller),
            message = CONCAT(N'Error ', ERROR_NUMBER(), N': ', ERROR_MESSAGE())
        WHERE log_id = @log_id;
        THROW;
    END CATCH;
END;
GO

-- Remove every replica, staging table, and log entry. For regenerating proofs.
CREATE OR ALTER PROCEDURE sync.usp_reset
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql nvarchar(max) = (
        SELECT STRING_AGG(CAST(CONCAT(N'DROP TABLE ', QUOTENAME(s.name), N'.', QUOTENAME(t.name), N';') AS nvarchar(max)), N' ')
        FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id WHERE s.name IN (N'replica', N'stage'));
    IF @sql IS NOT NULL EXEC (@sql);
    TRUNCATE TABLE sync.run;
    TRUNCATE TABLE sync.run_plan;
    TRUNCATE TABLE sync.run_table_log;
    TRUNCATE TABLE sync.driver_log;
    TRUNCATE TABLE sync.fault;  -- also restarts fault_id, which the proofs print
    IF OBJECT_ID(N'sync.alert') IS NOT NULL TRUNCATE TABLE sync.alert;
END;
GO
