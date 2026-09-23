-- Stand-in ERP generator.
--
-- Lives in erp_sim, which the warehouse's read-only login cannot see. It designs
-- a fictional vendor schema from a seed, then builds and populates the tables in
-- erp.dbo. Everything is deterministic from the seed.
--
-- What the stand-in reproduces:
--   * composite keys: an int, usually codes, sometimes a date; some codes contain quotes
--   * no declared primary keys or unique constraints
--   * create and modify dates that exist on most tables but cannot be trusted
--   * a wide spread of data types, so hashing has to cast by type
--   * a few very wide tables (250+ columns)
-- Runs on the erp instance.

IF DB_ID('erp_sim') IS NULL
    CREATE DATABASE erp_sim;
GO
ALTER DATABASE erp SET RECOVERY SIMPLE;
ALTER DATABASE erp_sim SET RECOVERY SIMPLE;
GO

USE erp_sim;
GO

-- Deterministic uniform [0, 1) from a seed and two integers. Used for design
-- decisions only; row values use cheaper inline arithmetic.
CREATE OR ALTER FUNCTION dbo.rnd (@seed int, @a int, @b int)
RETURNS float
AS
BEGIN
    RETURN CAST(CAST(CAST(HASHBYTES('MD5', CONCAT(@seed, ':', @a, ':', @b)) AS binary(4)) AS bigint) AS float)
           / 4294967296.0;
END;
GO

IF OBJECT_ID('dbo.numbers') IS NULL
BEGIN
    CREATE TABLE dbo.numbers (n bigint NOT NULL PRIMARY KEY);
    INSERT INTO dbo.numbers (n)
    SELECT TOP (1000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN sys.all_objects c;
END;
GO

IF OBJECT_ID('dbo.design_table') IS NULL
    CREATE TABLE dbo.design_table (
        table_name  sysname     NOT NULL PRIMARY KEY,
        ordinal     int         NOT NULL,
        module      varchar(2)  NOT NULL,
        key_shape   varchar(3)  NOT NULL,  -- I, IC, ICD, ICC
        fan_a       int         NOT NULL,  -- codes per id
        fan_b       int         NOT NULL,  -- dates or line codes per code
        weight      float       NOT NULL,
        row_count   int         NULL,
        next_n      bigint      NULL,      -- next row number to insert
        churn       varchar(6)  NOT NULL,  -- static, low, high
        is_wide     bit         NOT NULL,
        has_dates   bit         NOT NULL
    );

IF OBJECT_ID('dbo.design_column') IS NULL
    CREATE TABLE dbo.design_column (
        table_name     sysname     NOT NULL,
        ordinal        int         NOT NULL,
        column_name    sysname     NOT NULL,
        data_type      sysname     NOT NULL,
        max_length     int         NULL,
        num_precision  int         NULL,
        num_scale      int         NULL,
        is_nullable    bit         NOT NULL,
        role           varchar(8)  NOT NULL,  -- key, created, modified, data
        key_ordinal    int         NULL,
        PRIMARY KEY (table_name, ordinal)
    );

IF OBJECT_ID('dbo.sim_state') IS NULL
    CREATE TABLE dbo.sim_state (seed int NOT NULL, night int NOT NULL);
GO

-- SQL text for a deterministic pseudo-random bigint in [0, 2147483647),
-- from the row number n.n and a salt.
CREATE OR ALTER FUNCTION dbo.h_sql (@salt bigint)
RETURNS nvarchar(200)
AS
BEGIN
    RETURN CONCAT(N'(((n.n * 2654435761 + ', @salt, N') % 2147483647) * 48271 % 2147483647)');
END;
GO

-- SQL text for a key code from a code index expression. Every seventh code
-- contains a quote, the way real vendor codes sometimes do.
CREATE OR ALTER FUNCTION dbo.code_sql (@ci nvarchar(200), @prefix nchar(1))
RETURNS nvarchar(600)
AS
BEGIN
    RETURN CONCAT(N'CASE WHEN (', @ci, N') % 7 = 3 THEN CONCAT(''', @prefix, N''', CHAR(39), ', @ci, N') ',
                  N'ELSE CONCAT(''', @prefix, N''', RIGHT(CONCAT(''000'', ', @ci, N'), 3)) END');
END;
GO

-- SQL text for one column's value for row n.n.
CREATE OR ALTER FUNCTION dbo.value_sql (
    @table_name sysname, @ordinal int, @night int, @seed int)
RETURNS nvarchar(max)
AS
BEGIN
    DECLARE @c TABLE (data_type sysname, max_length int, num_precision int, num_scale int,
                      is_nullable bit, role varchar(8), key_ordinal int);
    INSERT INTO @c
    SELECT data_type, max_length, num_precision, num_scale, is_nullable, role, key_ordinal
    FROM dbo.design_column WHERE table_name = @table_name AND ordinal = @ordinal;

    DECLARE @data_type sysname, @len int, @p int, @s int, @nullable bit, @role varchar(8), @ko int;
    SELECT @data_type = data_type, @len = max_length, @p = num_precision, @s = num_scale,
           @nullable = is_nullable, @role = role, @ko = key_ordinal FROM @c;

    DECLARE @shape varchar(3), @a int, @b int;
    SELECT @shape = key_shape, @a = fan_a, @b = fan_b FROM dbo.design_table WHERE table_name = @table_name;

    DECLARE @salt bigint = CAST(@seed AS bigint) * 1000003 + @night * 10007 + @ordinal;
    DECLARE @h nvarchar(200) = dbo.h_sql(@salt);
    DECLARE @v nvarchar(max);

    IF @role = 'key'
    BEGIN
        SET @v = CASE
            WHEN @ko = 1 AND @shape = 'I'  THEN N'CAST(n.n AS int)'
            WHEN @ko = 1 AND @shape = 'IC' THEN CONCAT(N'CAST((n.n - 1) / ', @a, N' + 1 AS int)')
            WHEN @ko = 1                   THEN CONCAT(N'CAST((n.n - 1) / ', @a * @b, N' + 1 AS int)')
            WHEN @ko = 2 AND @shape = 'IC' THEN dbo.code_sql(CONCAT(N'(n.n - 1) % ', @a), N'C')
            WHEN @ko = 2                   THEN dbo.code_sql(CONCAT(N'((n.n - 1) / ', @b, N') % ', @a), N'C')
            WHEN @ko = 3 AND @shape = 'ICD' THEN CONCAT(N'DATEADD(day, ((n.n - 1) % ', @b, N') * 7, CAST(''2020-01-06'' AS date))')
            WHEN @ko = 3 AND @shape = 'ICC' THEN dbo.code_sql(CONCAT(N'(n.n - 1) % ', @b), N'L')
        END;
        RETURN @v;
    END;

    IF @role = 'created'
        RETURN CONCAT(N'CASE WHEN ', @h, N' % 10 = 0 THEN NULL ',
                      N'ELSE DATEADD(minute, -CAST(', @h, N' % 5000000 AS int), CAST(''2026-01-01'' AS datetime)) END');
    IF @role = 'modified'
        RETURN CONCAT(N'CASE WHEN ', @h, N' % 7 = 0 THEN NULL ',
                      N'ELSE DATEADD(minute, -CAST(', @h, N' % 2000000 AS int), CAST(''2026-01-01'' AS datetime)) END');

    SET @v = CASE @data_type
        WHEN 'int'       THEN CONCAT(N'CAST(', @h, N' % 100000 AS int)')
        WHEN 'bigint'    THEN CONCAT(N'CAST(', @h, N' AS bigint) * 1000 + ', @h, N' % 1000')
        WHEN 'smallint'  THEN CONCAT(N'CAST(', @h, N' % 30000 AS smallint)')
        WHEN 'bit'       THEN CONCAT(N'CAST(', @h, N' % 2 AS bit)')
        WHEN 'decimal'   THEN CONCAT(N'CAST(CAST(', @h, N' % ', POWER(CAST(10 AS bigint), IIF(@p - @s > 9, 9, @p - @s)),
                                     N' AS decimal(38, 6)) + CAST(', @h, N' % 997 AS decimal(38, 6)) / 997 AS decimal(',
                                     @p, N', ', @s, N'))')
        WHEN 'money'     THEN CONCAT(N'CAST(', @h, N' % 10000000 AS money) / 100')
        WHEN 'float'     THEN CONCAT(N'CAST(', @h, N' AS float) / 7.0')
        WHEN 'date'      THEN CONCAT(N'DATEADD(day, CAST(', @h, N' % 5000 AS int), CAST(''2012-01-01'' AS date))')
        WHEN 'datetime'  THEN CONCAT(N'DATEADD(millisecond, CAST(', @h, N' % 1000 AS int), DATEADD(second, CAST(', @h,
                                     N' % 400000000 AS int), CAST(''2012-01-01'' AS datetime)))')
        WHEN 'datetime2' THEN CONCAT(N'DATEADD(millisecond, CAST(', @h, N' % 1000 AS int), DATEADD(second, CAST(', @h,
                                     N' % 400000000 AS int), CAST(''2012-01-01'' AS datetime2(3))))')
        WHEN 'varchar'   THEN CONCAT(N'LEFT(CASE ', @h, N' % 23 WHEN 0 THEN '''' ',
                                     N'WHEN 1 THEN CONCAT(''O'', CHAR(39), ''Brien '', ', @h, N' % 1000) ',
                                     N'WHEN 2 THEN CONCAT(''A|B '', ', @h, N' % 1000) ',
                                     N'ELSE CONCAT(CHAR(65 + ', @h, N' % 26), CHAR(65 + ', @h, N' / 26 % 26), ''-'', ',
                                     @h, N' % 100000) END, ', @len, N')')
        WHEN 'nvarchar'  THEN CONCAT(N'LEFT(CASE ', @h, N' % 19 WHEN 0 THEN N'''' ',
                                     N'WHEN 1 THEN CONCAT(N''Caf'', NCHAR(233), N'' '', ', @h, N' % 1000) ',
                                     N'ELSE CONCAT(NCHAR(65 + ', @h, N' % 26), N''-'', ', @h, N' % 100000) END, ', @len, N')')
        WHEN 'char'      THEN CONCAT(N'LEFT(CONCAT(CHAR(65 + ', @h, N' % 26), ', @h, N' % 10), ', @len, N')')
        WHEN 'uniqueidentifier' THEN CONCAT(N'CAST(HASHBYTES(''MD5'', CONCAT(n.n, '':'', ', @salt, N')) AS uniqueidentifier)')
    END;

    IF @nullable = 1
        SET @v = CONCAT(N'CASE WHEN (n.n * 40503 + ', @salt, N' * 7) % 5 = 0 THEN NULL ELSE ', @v, N' END');
    RETURN @v;
END;
GO

-- Design the schema: tables, key shapes, sizes, churn, columns.
CREATE OR ALTER PROCEDURE dbo.usp_design
    @seed int = 7, @tables int = 120, @total_rows int = 1500000
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.design_column;
    TRUNCATE TABLE dbo.design_table;

    DECLARE @nouns TABLE (module varchar(2), noun varchar(20), i int);
    INSERT INTO @nouns (module, noun, i) VALUES
        ('gl','account',0),('gl','journal',1),('gl','period',2),('gl','budget',3),('gl','allocation',4),('gl','entry',5),
        ('ap','vendor',0),('ap','invoice',1),('ap','payment',2),('ap','voucher',3),('ap','check',4),('ap','remit',5),
        ('ar','client',0),('ar','invoice',1),('ar','receipt',2),('ar','credit',3),('ar','statement',4),('ar','dunning',5),
        ('pj','project',0),('pj','phase',1),('pj','task',2),('pj','milestone',3),('pj','estimate',4),('pj','contract',5),
        ('hr','employee',0),('hr','position',1),('hr','department',2),('hr','benefit',3),('hr','leave',4),('hr','review',5),
        ('tm','timesheet',0),('tm','labor',1),('tm','expense',2),('tm','rate',3),('tm','schedule',4),('tm','approval',5),
        ('bl','billing',0),('bl','draft',1),('bl','line',2),('bl','markup',3),('bl','retainer',4),('bl','fee',5),
        ('cf','code',0),('cf','status',1),('cf','type',2),('cf','category',3),('cf','region',4),('cf','currency',5);
    DECLARE @modules TABLE (module varchar(2), i int);
    INSERT INTO @modules SELECT module, ROW_NUMBER() OVER (ORDER BY module) - 1 FROM @nouns GROUP BY module;

    -- Data types with weights out of 100, and the column-name stems for each.
    DECLARE @types TABLE (data_type sysname, lo int, hi int, stems varchar(200));
    INSERT INTO @types VALUES
        ('varchar',           0, 30, 'code,name,descr,ref,note,status,memo'),
        ('nvarchar',         30, 38, 'label,title,comment'),
        ('char',             38, 42, 'flag_code,type_code,class'),
        ('int',              42, 54, 'qty,seq,level,period,units'),
        ('bigint',           54, 57, 'ext_id,batch_no'),
        ('smallint',         57, 60, 'priority,rank'),
        ('bit',              60, 68, 'active,billable,closed,taxable'),
        ('decimal',          68, 80, 'amount,rate,cost,hours,fee,balance'),
        ('money',            80, 84, 'total,tax,discount'),
        ('float',            84, 87, 'factor,ratio,pct'),
        ('date',             87, 94, 'due_date,start_date,end_date,posted_date'),
        ('datetime',         94, 98, 'entered_at,approved_at'),
        ('datetime2',        98, 99, 'sent_at'),
        ('uniqueidentifier', 99,100, 'guid');

    DECLARE @i int = 1, @module varchar(2), @noun varchar(20), @name sysname, @suffix int,
            @u1 float, @u2 float, @r float, @shape varchar(3), @churn varchar(6),
            @wide bit, @dates bit, @ncols int, @j int, @ord int,
            @type sysname, @stems varchar(200), @stem varchar(40), @nstems int,
            @len int, @p int, @s int;

    WHILE @i <= @tables
    BEGIN
        SELECT @module = module FROM @modules WHERE i = FLOOR(dbo.rnd(@seed, @i, 1) * 8);
        SELECT @noun = noun FROM @nouns WHERE module = @module AND i = FLOOR(dbo.rnd(@seed, @i, 2) * 6);
        SET @name = CONCAT(@module, '_', @noun);
        SET @suffix = 2;
        WHILE EXISTS (SELECT 1 FROM dbo.design_table WHERE table_name = @name)
        BEGIN
            SET @name = CONCAT(@module, '_', @noun, '_', @suffix);
            SET @suffix += 1;
        END;

        SET @r = dbo.rnd(@seed, @i, 6);
        SET @shape = CASE WHEN @r < 0.25 THEN 'I' WHEN @r < 0.70 THEN 'IC' WHEN @r < 0.90 THEN 'ICD' ELSE 'ICC' END;
        SET @r = dbo.rnd(@seed, @i, 9);
        SET @churn = CASE WHEN @module = 'cf' OR @r < 0.30 THEN 'static' WHEN @r < 0.80 THEN 'low' ELSE 'high' END;
        SET @wide = IIF(dbo.rnd(@seed, @i, 3) < 0.05, 1, 0);
        SET @dates = IIF(dbo.rnd(@seed, @i, 10) < 0.85, 1, 0);
        -- Log-normal size weight: a few large tables, many small ones.
        SET @u1 = dbo.rnd(@seed, @i, 4) + 1e-9;
        SET @u2 = dbo.rnd(@seed, @i, 5);

        INSERT INTO dbo.design_table
            (table_name, ordinal, module, key_shape, fan_a, fan_b, weight, churn, is_wide, has_dates)
        VALUES (@name, @i, @module, @shape,
                2 + FLOOR(dbo.rnd(@seed, @i, 7) * 8), 2 + FLOOR(dbo.rnd(@seed, @i, 8) * 5),
                EXP(2.0 * SQRT(-2.0 * LOG(@u1)) * COS(2.0 * PI() * @u2)),
                @churn, @wide, @dates);

        -- Key columns first.
        INSERT INTO dbo.design_column VALUES (@name, 1, CONCAT(@noun, '_id'), 'int', NULL, NULL, NULL, 0, 'key', 1);
        SET @ord = 2;
        IF @shape <> 'I'
        BEGIN
            INSERT INTO dbo.design_column VALUES (@name, 2, CONCAT(@noun, '_code'), 'varchar', 12, NULL, NULL, 0, 'key', 2);
            SET @ord = 3;
        END;
        IF @shape = 'ICD'
            INSERT INTO dbo.design_column VALUES (@name, 3, CONCAT(@noun, '_date'), 'date', NULL, NULL, NULL, 0, 'key', 3);
        IF @shape = 'ICC'
            INSERT INTO dbo.design_column VALUES (@name, 3, 'line_code', 'varchar', 8, NULL, NULL, 0, 'key', 3);
        IF @shape IN ('ICD', 'ICC') SET @ord = 4;

        IF @dates = 1
        BEGIN
            INSERT INTO dbo.design_column VALUES (@name, @ord, 'created_on', 'datetime', NULL, NULL, NULL, 1, 'created', NULL);
            INSERT INTO dbo.design_column VALUES (@name, @ord + 1, 'modified_on', 'datetime', NULL, NULL, NULL, 1, 'modified', NULL);
            SET @ord += 2;
        END;

        SET @ncols = IIF(@wide = 1, 250 + FLOOR(dbo.rnd(@seed, @i, 11) * 71), 6 + FLOOR(dbo.rnd(@seed, @i, 11) * 55));
        SET @j = 1;
        WHILE @j <= @ncols
        BEGIN
            SET @r = dbo.rnd(@seed, @i * 1000 + @j, 12) * 100;
            SELECT @type = data_type, @stems = stems FROM @types WHERE @r >= lo AND @r < hi;
            SELECT @nstems = COUNT(*) FROM STRING_SPLIT(@stems, ',');
            SELECT @stem = value FROM STRING_SPLIT(@stems, ',', 1)
            WHERE ordinal = 1 + FLOOR(dbo.rnd(@seed, @i * 1000 + @j, 13) * @nstems);
            SET @r = dbo.rnd(@seed, @i * 1000 + @j, 14);
            SELECT @len = NULL, @p = NULL, @s = NULL;
            IF @type IN ('varchar', 'nvarchar')
                SET @len = CASE WHEN @r < 0.3 THEN 10 WHEN @r < 0.6 THEN 20 WHEN @r < 0.8 THEN 40 WHEN @r < 0.95 THEN 80 ELSE 255 END;
            IF @type = 'char'
                SET @len = CASE WHEN @r < 0.5 THEN 1 WHEN @r < 0.8 THEN 2 ELSE 3 END;
            IF @type = 'decimal'
                SELECT @p = CASE WHEN @r < 0.5 THEN 19 WHEN @r < 0.85 THEN 12 ELSE 9 END,
                       @s = CASE WHEN @r < 0.5 THEN 4 WHEN @r < 0.85 THEN 2 ELSE 6 END;
            INSERT INTO dbo.design_column VALUES
                (@name, @ord, CONCAT(@stem, '_', RIGHT(CONCAT('00', @j), 3)), @type, @len, @p, @s,
                 IIF(dbo.rnd(@seed, @i * 1000 + @j, 15) < 0.3, 1, 0), 'data', NULL);
            SET @ord += 1;
            SET @j += 1;
        END;

        SET @i += 1;
    END;

    -- Sizes: cap any one table at 12% of rows, wide tables at 20,000, floor at 10.
    DECLARE @total float = (SELECT SUM(weight) FROM dbo.design_table);
    UPDATE dbo.design_table SET weight = IIF(weight > @total * 0.12, @total * 0.12, weight);
    SET @total = (SELECT SUM(weight) FROM dbo.design_table);
    UPDATE dbo.design_table
    SET row_count = CASE
            WHEN is_wide = 1 AND ROUND(@total_rows * weight / @total, 0) > 20000 THEN 20000
            WHEN ROUND(@total_rows * weight / @total, 0) < 10 THEN 10
            ELSE CAST(ROUND(@total_rows * weight / @total, 0) AS int) END;
    UPDATE dbo.design_table SET next_n = row_count + 1;

    DELETE FROM dbo.sim_state;
    INSERT INTO dbo.sim_state VALUES (@seed, 0);
END;
GO

-- SQL text for a column's type.
CREATE OR ALTER FUNCTION dbo.type_sql (@data_type sysname, @len int, @p int, @s int)
RETURNS nvarchar(100)
AS
BEGIN
    RETURN CASE
        WHEN @data_type IN ('varchar', 'nvarchar', 'char') THEN CONCAT(@data_type, '(', @len, ')')
        WHEN @data_type = 'decimal' THEN CONCAT('decimal(', @p, ', ', @s, ')')
        WHEN @data_type = 'datetime2' THEN 'datetime2(3)'
        ELSE @data_type END;
END;
GO

-- Build and populate every designed table in erp.dbo.
CREATE OR ALTER PROCEDURE dbo.usp_build
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @seed int = (SELECT seed FROM dbo.sim_state);
    DECLARE @name sysname, @rows int, @sql nvarchar(max), @cols nvarchar(max), @keys nvarchar(max),
            @exprs nvarchar(max), @names nvarchar(max);

    DECLARE t CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name, row_count FROM dbo.design_table ORDER BY ordinal;
    OPEN t;
    FETCH NEXT FROM t INTO @name, @rows;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @cols = STRING_AGG(CAST(CONCAT(QUOTENAME(column_name), ' ',
                           dbo.type_sql(data_type, max_length, num_precision, num_scale),
                           IIF(is_nullable = 1, ' NULL', ' NOT NULL')) AS nvarchar(max)), ', ')
                       WITHIN GROUP (ORDER BY ordinal),
               @names = STRING_AGG(CAST(QUOTENAME(column_name) AS nvarchar(max)), ', ') WITHIN GROUP (ORDER BY ordinal),
               @exprs = STRING_AGG(CAST(dbo.value_sql(table_name, ordinal, 0, @seed) AS nvarchar(max)), N', ')
                        WITHIN GROUP (ORDER BY ordinal)
        FROM dbo.design_column WHERE table_name = @name;
        SELECT @keys = STRING_AGG(QUOTENAME(column_name), ', ') WITHIN GROUP (ORDER BY key_ordinal)
        FROM dbo.design_column WHERE table_name = @name AND role = 'key';

        -- An index on the key columns, but no primary key or unique constraint:
        -- the catalog does not say what the key is.
        SET @sql = CONCAT(N'DROP TABLE IF EXISTS dbo.', QUOTENAME(@name), N'; ',
                          N'CREATE TABLE dbo.', QUOTENAME(@name), N' (', @cols, N'); ',
                          N'CREATE CLUSTERED INDEX cx ON dbo.', QUOTENAME(@name), N' (', @keys, N'); ',
                          N'INSERT INTO dbo.', QUOTENAME(@name), N' WITH (TABLOCK) (', @names, N') ',
                          N'SELECT ', @exprs, N' FROM erp_sim.dbo.numbers n WHERE n.n <= ', @rows, N';');
        EXEC erp.sys.sp_executesql @sql;

        FETCH NEXT FROM t INTO @name, @rows;
    END;
    CLOSE t;
    DEALLOCATE t;
END;
GO
