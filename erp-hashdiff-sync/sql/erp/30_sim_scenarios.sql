-- Scenarios for the failure and edge-case proofs. Runs on the erp instance.
-- Test scaffolding: nothing here runs during the nightly simulation.

USE erp_sim;
GO

-- A partial restore on the vendor's side: a share of a table's rows vanishes
-- for a while, then comes back. This is what the variance guard exists for.
CREATE OR ALTER PROCEDURE dbo.usp_hold_rows
    @table_name sysname, @pct int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @hold nvarchar(300) = QUOTENAME(N'hold__' + @table_name), @t nvarchar(300) = QUOTENAME(@table_name);
    DECLARE @keys nvarchar(max) = (SELECT STRING_AGG(QUOTENAME(column_name), N', ') WITHIN GROUP (ORDER BY key_ordinal)
                                   FROM dbo.design_column WHERE table_name = @table_name AND role = 'key');
    DECLARE @sql nvarchar(max) = CONCAT(
        N'DROP TABLE IF EXISTS dbo.', @hold, N'; ',
        N'SELECT * INTO dbo.', @hold, N' FROM erp.dbo.', @t,
        N' WHERE CAST(CAST(HASHBYTES(''MD5'', CONCAT(', REPLACE(@keys, N', ', N', '':'', '), N')) AS binary(4)) AS bigint) % 100 < @pct; ',
        N'DELETE t FROM erp.dbo.', @t, N' t WHERE EXISTS (SELECT 1 FROM dbo.', @hold, N' h WHERE ',
        (SELECT STRING_AGG(CAST(CONCAT(N'h.', QUOTENAME(column_name), N' = t.', QUOTENAME(column_name)) AS nvarchar(max)), N' AND ')
         FROM dbo.design_column WHERE table_name = @table_name AND role = 'key'), N');');
    EXEC sp_executesql @sql, N'@pct int', @pct;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_restore_rows
    @table_name sysname
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @hold nvarchar(300) = QUOTENAME(N'hold__' + @table_name), @t nvarchar(300) = QUOTENAME(@table_name);
    DECLARE @sql nvarchar(max) = CONCAT(N'INSERT INTO erp.dbo.', @t, N' SELECT * FROM dbo.', @hold, N'; DROP TABLE dbo.', @hold, N';');
    EXEC (@sql);
END;
GO

-- The obvious first-draft row hash, for contrast: text columns as they are,
-- everything else by default conversion, NULL as empty string, a single-pipe
-- delimiter, and no varchar(max). Each of those hides a real change; the
-- sync's hash avoids all of them. (With any nvarchar column in the row, this
-- concatenation becomes nvarchar(4000) and silently stops at 4,000 characters;
-- without one, varchar(8000) stops at 8,000.)
CREATE OR ALTER FUNCTION dbo.naive_hash_sql (@table_name sysname)
RETURNS nvarchar(max)
AS
BEGIN
    RETURN (
        SELECT CONCAT(N'HASHBYTES(''MD5'', ',
                      STRING_AGG(CAST(IIF(data_type IN ('varchar', 'nvarchar', 'char'),
                                          CONCAT(N'ISNULL(', QUOTENAME(column_name), N', '''')'),
                                          CONCAT(N'ISNULL(CONVERT(varchar(8000), ', QUOTENAME(column_name), N'), '''')'))
                                      AS nvarchar(max)),
                                 N' + ''|'' + ') WITHIN GROUP (ORDER BY ordinal),
                      N')')
        FROM dbo.design_column WHERE table_name = @table_name);
END;
GO

IF OBJECT_ID('dbo.edge_log') IS NULL
    CREATE TABLE dbo.edge_log (
        case_no      int            NOT NULL PRIMARY KEY,
        title        nvarchar(200)  NOT NULL,
        table_name   sysname        NOT NULL,
        column_name  sysname        NULL,
        before_value nvarchar(400)  NULL,
        after_value  nvarchar(400)  NULL,
        naive_same   bit            NULL  -- 1: the naive hash did not change, so a naive sync would miss this
    );
GO

-- Case 5's target: the first adjacent pair of text columns in a small table
-- that nightly activity never touches. Used by usp_edge_case and the proof script.
CREATE OR ALTER FUNCTION dbo.case5_pair ()
RETURNS TABLE
AS
RETURN
    SELECT TOP 1 a.table_name, a.column_name, b.column_name AS next_column
    FROM dbo.design_column a
    JOIN dbo.design_column b ON b.table_name = a.table_name AND b.ordinal = a.ordinal + 1
    JOIN dbo.design_table d ON d.table_name = a.table_name
    WHERE a.role = 'data' AND b.role = 'data' AND a.data_type = 'varchar' AND b.data_type = 'varchar'
          AND a.max_length >= 10 AND b.max_length >= 10 AND d.churn = 'static' AND d.is_wide = 0
    ORDER BY d.row_count, a.table_name, a.ordinal;
GO

-- One targeted change to one row, recording whether the naive hash would see it.
-- @step 1 sets up a starting state where a case needs one; @step 2 makes the change.
CREATE OR ALTER PROCEDURE dbo.usp_edge_case
    @case_no int, @step int = 2
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t sysname, @col sysname, @col2 sysname, @title nvarchar(200), @sql nvarchar(max), @where nvarchar(max),
            @before nvarchar(400), @after nvarchar(400), @h1 varbinary(16), @h2 varbinary(16), @keys nvarchar(max);

    SET @t = IIF(@case_no = 6, N'pj_milestone', N'tm_expense_3');
    SELECT @keys = STRING_AGG(QUOTENAME(column_name), N', ') WITHIN GROUP (ORDER BY key_ordinal)
    FROM dbo.design_column WHERE table_name = @t AND role = 'key';

    -- The target column for each case.
    SELECT TOP 1 @col = column_name FROM dbo.design_column
    WHERE table_name = @t AND role = 'data' AND (
          (@case_no = 1 AND data_type = 'varchar' AND is_nullable = 1)
       OR (@case_no = 2 AND data_type = 'money')
       OR (@case_no = 3 AND data_type = 'float')
       OR (@case_no = 4 AND data_type = 'datetime')
       OR (@case_no = 6 AND data_type IN ('varchar', 'nvarchar')))
    ORDER BY IIF(@case_no = 6, -ordinal, ordinal);
    -- A pipe can only move unseen between neighboring columns.
    IF @case_no = 5
    BEGIN
        SELECT @t = table_name, @col = column_name, @col2 = next_column FROM dbo.case5_pair();
        SELECT @keys = STRING_AGG(QUOTENAME(column_name), N', ') WITHIN GROUP (ORDER BY key_ordinal)
        FROM dbo.design_column WHERE table_name = @t AND role = 'key';
    END;

    -- The target row: the first by key (for case 1, the first whose value is NULL).
    SET @sql = CONCAT(N'SELECT TOP 1 @w = CONCAT(', (
        SELECT STRING_AGG(CAST(CONCAT(N'''', QUOTENAME(column_name), N' = '''''', REPLACE(CONVERT(varchar(40), ', QUOTENAME(column_name),
                                      IIF(data_type = 'date', N', 23', N''), N'), '''''''', ''''''''''''), ''''''''') AS nvarchar(max)),
                          N', '' AND '', ') WITHIN GROUP (ORDER BY key_ordinal)
        FROM dbo.design_column WHERE table_name = @t AND role = 'key'),
        N') FROM erp.dbo.', QUOTENAME(@t), IIF(@case_no = 1, CONCAT(N' WHERE ', QUOTENAME(@col), N' IS NULL'), N''),
        N' ORDER BY ', @keys, N';');
    EXEC sp_executesql @sql, N'@w nvarchar(max) OUTPUT', @where OUTPUT;

    DECLARE @naive nvarchar(max) = CONCAT(N'SELECT @h = ', dbo.naive_hash_sql(@t), N' FROM erp.dbo.', QUOTENAME(@t), N' WHERE ', @where);
    DECLARE @show nvarchar(max) = CONCAT(N'SELECT @v = LEFT(', CASE
        WHEN @case_no = 1 THEN CONCAT(N'ISNULL(QUOTENAME(', QUOTENAME(@col), N', ''''''''), ''NULL'')')
        WHEN @case_no = 2 THEN CONCAT(N'CONVERT(varchar(40), ', QUOTENAME(@col), N', 2)')
        WHEN @case_no = 3 THEN CONCAT(N'CONVERT(varchar(40), ', QUOTENAME(@col), N', 3)')
        WHEN @case_no = 4 THEN CONCAT(N'CONVERT(varchar(40), ', QUOTENAME(@col), N', 121)')
        WHEN @case_no = 5 THEN CONCAT(N'CONCAT(''', @col, N' = '', QUOTENAME(', QUOTENAME(@col), N', ''''''''), '', ', @col2, N' = '', QUOTENAME(', QUOTENAME(@col2), N', ''''''''))')
        WHEN @case_no = 6 THEN CONCAT(N'CONCAT(''row text length '', LEN(', REPLACE(dbo.naive_hash_sql(@t), N'HASHBYTES(''MD5'', ', N'CAST('''' AS varchar(max)) + '), N', '', last text column ends '', RIGHT(', QUOTENAME(@col), N', 3))')
        END, N', 400) FROM erp.dbo.', QUOTENAME(@t), N' WHERE ', @where);

    IF @step = 1
    BEGIN
        -- Starting states: two adjacent values with a pipe; a row full of text.
        IF @case_no = 5
            SET @sql = CONCAT(N'UPDATE erp.dbo.', QUOTENAME(@t), N' SET ', QUOTENAME(@col), N' = ''ab'', ', QUOTENAME(@col2), N' = ''|cd'' WHERE ', @where);
        IF @case_no = 6
            SET @sql = CONCAT(N'UPDATE erp.dbo.', QUOTENAME(@t), N' SET ', (
                SELECT STRING_AGG(CAST(CONCAT(QUOTENAME(column_name), N' = REPLICATE(''x'', ', max_length, N')') AS nvarchar(max)), N', ')
                FROM dbo.design_column WHERE table_name = @t AND role = 'data' AND data_type IN ('varchar', 'nvarchar')),
                N' WHERE ', @where);
        IF @sql IS NOT NULL AND @case_no IN (5, 6) EXEC (@sql);
        RETURN;
    END;

    EXEC sp_executesql @naive, N'@h varbinary(16) OUTPUT', @h1 OUTPUT;
    EXEC sp_executesql @show, N'@v nvarchar(400) OUTPUT', @before OUTPUT;

    SET @sql = CONCAT(N'UPDATE erp.dbo.', QUOTENAME(@t), N' SET ', CASE
        WHEN @case_no = 1 THEN CONCAT(QUOTENAME(@col), N' = ''''')
        WHEN @case_no = 2 THEN CONCAT(QUOTENAME(@col), N' = ', QUOTENAME(@col), N' + 0.0001')
        WHEN @case_no = 3 THEN CONCAT(QUOTENAME(@col), N' = ', QUOTENAME(@col), N' * (1 + 1e-12)')
        WHEN @case_no = 4 THEN CONCAT(QUOTENAME(@col), N' = DATEADD(millisecond, 10, ', QUOTENAME(@col), N')')
        WHEN @case_no = 5 THEN CONCAT(QUOTENAME(@col), N' = ''ab|'', ', QUOTENAME(@col2), N' = ''cd''')
        WHEN @case_no = 6 THEN CONCAT(QUOTENAME(@col), N' = STUFF(', QUOTENAME(@col), N', LEN(', QUOTENAME(@col), N'), 1, ''y'')')
        END, N' WHERE ', @where);
    EXEC (@sql);

    EXEC sp_executesql @naive, N'@h varbinary(16) OUTPUT', @h2 OUTPUT;
    EXEC sp_executesql @show, N'@v nvarchar(400) OUTPUT', @after OUTPUT;

    SET @title = CASE @case_no
        WHEN 1 THEN N'NULL becomes an empty string'
        WHEN 2 THEN N'money changes in the fourth decimal place'
        WHEN 3 THEN N'float changes in the 13th significant digit'
        WHEN 4 THEN N'datetime changes by 10 milliseconds'
        WHEN 5 THEN N'a pipe moves from one column to the next'
        WHEN 6 THEN N'a change past the 4,000th character of the row'
        END;
    DELETE FROM dbo.edge_log WHERE case_no = @case_no;
    INSERT INTO dbo.edge_log VALUES (@case_no, @title, @t, IIF(@case_no = 5, CONCAT(@col, N', ', @col2), @col),
                                     @before, @after, IIF(@h1 = @h2, 1, 0));
END;
GO

-- Key cases, on a small static table with an int-and-code key.
CREATE OR ALTER FUNCTION dbo.key_case_table ()
RETURNS sysname
AS
BEGIN
    RETURN (SELECT TOP 1 table_name FROM dbo.design_table
            WHERE churn = 'static' AND key_shape = 'IC' AND is_wide = 0 ORDER BY row_count, table_name);
END;
GO

-- Case 7: a new row whose key code contains quotes. Case 8: delete a row
-- (@step 1), then re-create the same key with different values (@step 2).
CREATE OR ALTER PROCEDURE dbo.usp_key_case
    @case_no int, @step int = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tbl sysname = dbo.key_case_table(), @id sysname, @code sysname, @data sysname, @sql nvarchar(max);
    SELECT @id = MAX(IIF(key_ordinal = 1, column_name, NULL)), @code = MAX(IIF(key_ordinal = 2, column_name, NULL))
    FROM dbo.design_column WHERE table_name = @tbl AND role = 'key';
    SELECT TOP 1 @data = column_name FROM dbo.design_column
    WHERE table_name = @tbl AND role = 'data' AND data_type = 'int' ORDER BY ordinal;
    DECLARE @full nvarchar(300) = CONCAT(N'erp.dbo.', QUOTENAME(@tbl));

    IF @case_no = 7
        SET @sql = CONCAT(N'SELECT TOP 1 * INTO #r FROM ', @full, N' ORDER BY ', QUOTENAME(@id), N'; ',
                          N'UPDATE #r SET ', QUOTENAME(@id), N' = (SELECT MAX(', QUOTENAME(@id), N') + 1 FROM ', @full, N'), ',
                          QUOTENAME(@code), N' = ''O''''Brien''''s''; ',
                          N'INSERT INTO ', @full, N' SELECT * FROM #r;');
    IF @case_no = 8 AND @step = 1
        SET @sql = CONCAT(N'DROP TABLE IF EXISTS dbo.hold__key_case; ',
                          N'SELECT TOP 1 * INTO dbo.hold__key_case FROM ', @full, N' ORDER BY ', QUOTENAME(@id), N', ', QUOTENAME(@code), N'; ',
                          N'DELETE t FROM ', @full, N' t JOIN dbo.hold__key_case h ON h.', QUOTENAME(@id), N' = t.', QUOTENAME(@id),
                          N' AND h.', QUOTENAME(@code), N' = t.', QUOTENAME(@code), N';');
    IF @case_no = 8 AND @step = 2
        SET @sql = CONCAT(N'UPDATE dbo.hold__key_case SET ', QUOTENAME(@data), N' = ISNULL(', QUOTENAME(@data), N', 0) + 1; ',
                          N'INSERT INTO ', @full, N' SELECT * FROM dbo.hold__key_case; DROP TABLE dbo.hold__key_case;');
    EXEC (@sql);
END;
GO
