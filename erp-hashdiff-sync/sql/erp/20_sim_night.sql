-- One simulated business day on the stand-in ERP. Runs on the erp instance.
--
-- Per changing table: inserts, updates, and deletes, with no tombstones. Some keys
-- deleted the day before are re-created with new values. Updates set modified_on
-- only 70% of the time, and new rows are missing their dates 10% of the time.
-- Everything is deterministic from the seed and the night number.

USE erp_sim;
GO

IF OBJECT_ID('dbo.sim_log') IS NULL
    CREATE TABLE dbo.sim_log (
        night               int     NOT NULL,
        table_name          sysname NOT NULL,
        inserted            int     NOT NULL,
        updated             int     NOT NULL,
        deleted             int     NOT NULL,
        reinserted          int     NOT NULL,
        modified_left_stale int     NOT NULL,  -- updated rows whose modified_on was not touched
        PRIMARY KEY (night, table_name)
    );
GO

CREATE OR ALTER PROCEDURE dbo.usp_run_night
    @night int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @seed int, @last int;
    SELECT @seed = seed, @last = night FROM dbo.sim_state;
    IF @night <> @last + 1
        THROW 50100, 'Nights must run in order.', 1;
    IF @night = 1
        DELETE FROM dbo.sim_log;

    DECLARE @day nchar(10) = CONVERT(nchar(10), DATEADD(day, @night - 1, CAST('2026-01-01' AS date)), 23);
    DECLARE @name sysname, @ord int, @churn varchar(6), @dates bit, @next bigint, @t nvarchar(300),
            @ins_ppm int, @upd_ppm int, @del_ppm int, @keys nvarchar(max), @key_exprs nvarchar(max),
            @key_match nvarchar(max), @names nvarchar(max), @exprs nvarchar(max), @sets nvarchar(max),
            @count bigint, @n_ins int, @expected float, @sql nvarchar(max),
            @inserted int, @updated int, @deleted int, @reinserted int, @stale int, @n_upd int;

    DECLARE t CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name, ordinal, churn, has_dates, next_n FROM dbo.design_table
        WHERE churn <> 'static' ORDER BY ordinal;
    OPEN t;
    FETCH NEXT FROM t INTO @name, @ord, @churn, @dates, @next;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @ins_ppm = IIF(@churn = 'high', 1000, 100),
               @upd_ppm = IIF(@churn = 'high', 2000, 200),
               @del_ppm = IIF(@churn = 'high', 100, 20);
        SET @t = CONCAT(N'erp.dbo.', QUOTENAME(@name));

        SELECT @keys = STRING_AGG(CAST(QUOTENAME(column_name) AS nvarchar(max)), N', '':'', ') WITHIN GROUP (ORDER BY key_ordinal),
               @key_exprs = STRING_AGG(dbo.value_sql(table_name, ordinal, 0, @seed), N', '':'', ') WITHIN GROUP (ORDER BY key_ordinal),
               @key_match = STRING_AGG(CAST(CONCAT(N'x.', QUOTENAME(column_name), N' = ', dbo.value_sql(table_name, ordinal, 0, @seed))
                                            AS nvarchar(max)), N' AND ') WITHIN GROUP (ORDER BY key_ordinal)
        FROM dbo.design_column WHERE table_name = @name AND role = 'key';
        SELECT @names = STRING_AGG(CAST(QUOTENAME(column_name) AS nvarchar(max)), N', ') WITHIN GROUP (ORDER BY ordinal),
               @exprs = STRING_AGG(CAST(IIF(role = 'key', dbo.value_sql(table_name, ordinal, 0, @seed),
                                            dbo.value_sql(table_name, ordinal, @night, @seed)) AS nvarchar(max)), N', ')
                        WITHIN GROUP (ORDER BY ordinal)
        FROM dbo.design_column WHERE table_name = @name;

        -- Deletes. No tombstone, no flag: the row is simply gone.
        SET @sql = CONCAT(N'DELETE FROM ', @t, N' WHERE ', dbo.pick_sql(@keys, N'@night', 1), N' % 1000000 < ', @del_ppm,
                          N'; SET @rc = @@ROWCOUNT;');
        EXEC sp_executesql @sql, N'@night int, @seed int, @rc int OUTPUT', @night, @seed, @deleted OUTPUT;

        -- Updates to one to three business columns. modified_on moves only 70% of the time.
        SET @n_upd = 1 + FLOOR(dbo.rnd(@seed, @night * 1000 + @ord, 20) * 3);
        SELECT @sets = STRING_AGG(CAST(CONCAT(QUOTENAME(column_name), N' = ',
                                              REPLACE(dbo.value_sql(table_name, ordinal, @night, @seed), N'n.n', N'x.nn'))
                                       AS nvarchar(max)), N', ')
        FROM (
            SELECT TOP (@n_upd) table_name, ordinal, column_name
            FROM dbo.design_column
            WHERE table_name = @name AND role = 'data'
            ORDER BY dbo.rnd(@seed, @night * 100000 + @ord * 1000 + ordinal, 21)
        ) c;
        IF @dates = 1
            SET @sets = CONCAT(@sets, N', modified_on = CASE WHEN x.nn % 10 < 7 THEN ',
                               N'DATEADD(minute, CAST(x.nn % 600 AS int), CAST(''', @day, N' 08:00'' AS datetime)) ',
                               N'ELSE modified_on END');
        SET @sql = CONCAT(N'WITH x AS (SELECT *, ', dbo.pick_sql(@keys, N'@night', 2), N' AS nn FROM ', @t,
                          N' WHERE ', dbo.pick_sql(@keys, N'@night', 3), N' % 1000000 < ', @upd_ppm, N') ',
                          N'UPDATE x SET ', @sets, N'; SET @rc = @@ROWCOUNT;');
        EXEC sp_executesql @sql, N'@night int, @seed int, @rc int OUTPUT', @night, @seed, @updated OUTPUT;
        SET @stale = 0;
        IF @dates = 1
        BEGIN
            SET @sql = CONCAT(N'SELECT @rc = COUNT(*) FROM ', @t,
                              N' WHERE ', dbo.pick_sql(@keys, N'@night', 3), N' % 1000000 < ', @upd_ppm,
                              N' AND ', dbo.pick_sql(@keys, N'@night', 2), N' % 10 >= 7;');
            EXEC sp_executesql @sql, N'@night int, @seed int, @rc int OUTPUT', @night, @seed, @stale OUTPUT;
        END;

        -- Inserts: new keys past the highest row number so far.
        SET @sql = CONCAT(N'SELECT @rc = COUNT(*) FROM ', @t);
        EXEC sp_executesql @sql, N'@rc bigint OUTPUT', @count OUTPUT;
        SET @expected = @count * @ins_ppm / 1000000.0;
        SET @n_ins = FLOOR(@expected) + IIF(dbo.rnd(@seed, @night * 1000 + @ord, 22) < @expected - FLOOR(@expected), 1, 0);
        SET @inserted = 0;
        IF @n_ins > 0
        BEGIN
            SET @sql = CONCAT(N'INSERT INTO ', @t, N' (', @names, N') SELECT ', @exprs,
                              N' FROM erp_sim.dbo.numbers n WHERE n.n BETWEEN ', @next, N' AND ', @next + @n_ins - 1,
                              N'; SET @rc = @@ROWCOUNT;');
            EXEC sp_executesql @sql, N'@rc int OUTPUT', @inserted OUTPUT;
            UPDATE dbo.design_table SET next_n = next_n + @n_ins WHERE table_name = @name;
        END;

        -- Key reuse: a quarter of yesterday's deleted keys come back with new values.
        SET @reinserted = 0;
        IF @night > 1
        BEGIN
            SET @sql = CONCAT(N'INSERT INTO ', @t, N' (', @names, N') SELECT ', @exprs,
                              N' FROM erp_sim.dbo.numbers n WHERE n.n < ', @next,
                              N' AND ', dbo.pick_sql(@key_exprs, N'@night - 1', 1), N' % 1000000 < ', @del_ppm,
                              N' AND ', dbo.pick_sql(@key_exprs, N'@night', 4), N' % 4 = 0',
                              N' AND NOT EXISTS (SELECT 1 FROM ', @t, N' x WHERE ', @key_match, N')',
                              N'; SET @rc = @@ROWCOUNT;');
            EXEC sp_executesql @sql, N'@night int, @seed int, @rc int OUTPUT', @night, @seed, @reinserted OUTPUT;
        END;

        INSERT INTO dbo.sim_log VALUES (@night, @name, @inserted, @updated, @deleted, @reinserted, @stale);
        FETCH NEXT FROM t INTO @name, @ord, @churn, @dates, @next;
    END;
    CLOSE t;
    DEALLOCATE t;

    UPDATE dbo.sim_state SET night = @night;
END;
GO
