-- Sync machinery on the warehouse: configuration, the table manifest, and the
-- single door to the ERP. Runs on the warehouse instance.

USE warehouse;
GO

IF SCHEMA_ID('sync') IS NULL EXEC ('CREATE SCHEMA sync');
GO

IF OBJECT_ID('sync.config') IS NULL
    CREATE TABLE sync.config (
        name   sysname       NOT NULL PRIMARY KEY,
        value  nvarchar(200) NOT NULL
    );
GO

-- The vendor driver's query-text limit. The exact figure is not recalled, but it
-- was never tight: batches ran to 2,000 keys or more. 32,767 (a signed 16-bit
-- length) gives batches that size here; the widest pull needs about 12,800.
-- capture_sql is test scaffolding: '1' makes the wrapper keep each statement's
-- text in sync.driver_log, for proof 06. Every install resets it to '0'.
MERGE sync.config AS t
USING (VALUES
    (N'text_limit', N'32767'),
    (N'capture_sql', N'0')
) AS s (name, value)
ON t.name = s.name
WHEN MATCHED THEN UPDATE SET value = s.value
WHEN NOT MATCHED THEN INSERT (name, value) VALUES (s.name, s.value);
GO

-- Which tables to replicate and what their keys are. The ERP's catalog does not
-- declare keys, so they are maintained by hand from the vendor's data
-- dictionary. Adding a row here is all it takes to start replicating a table.
IF OBJECT_ID('sync.manifest') IS NULL
    CREATE TABLE sync.manifest (
        table_name        sysname       NOT NULL PRIMARY KEY,
        key_columns       nvarchar(400) NOT NULL,  -- comma-separated, in key order
        shrink_allowance  decimal(5, 4) NOT NULL DEFAULT 0.01,
        is_active         bit           NOT NULL DEFAULT 1
    );
GO

-- One row per statement the ERP completed. Failed calls are not here: a failed
-- INSERT ... EXEC rolls back everything the wrapper did, including its log row,
-- so failures are logged by the caller's CATCH block instead.
IF OBJECT_ID('sync.driver_log') IS NULL
    CREATE TABLE sync.driver_log (
        call_id      bigint        IDENTITY PRIMARY KEY,
        called_at    datetime2(3)  NOT NULL,
        duration_ms  int           NOT NULL,
        sql_chars    int           NOT NULL,
        caller       nvarchar(200) NULL,
        rows_back    int           NULL,
        sql_text     nvarchar(max) NULL   -- only while capture_sql is '1'
    );
IF COL_LENGTH('sync.driver_log', 'rows_back') IS NULL
    ALTER TABLE sync.driver_log ADD rows_back int NULL, sql_text nvarchar(max) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_driver_log_caller' AND object_id = OBJECT_ID('sync.driver_log'))
    CREATE INDEX ix_driver_log_caller ON sync.driver_log (caller);
GO

-- Test scaffolding for the failure proofs: inert unless a row is armed.
-- A failed INSERT ... EXEC rolls back everything the wrapper did, so a fault
-- counter kept in a table would reset on every failure. Sequence values are
-- not rolled back, so the count of matching calls lives in a sequence.
IF OBJECT_ID('sync.fault_seq') IS NULL
    CREATE SEQUENCE sync.fault_seq AS bigint START WITH 1;
IF OBJECT_ID('sync.fault') IS NULL
    CREATE TABLE sync.fault (
        fault_id     int           IDENTITY PRIMARY KEY,
        caller_like  nvarchar(200) NOT NULL,  -- LIKE pattern on the caller, e.g. N'%:pj_project'
        sql_like     nvarchar(200) NOT NULL,  -- LIKE pattern on the statement, e.g. N'%JOIN (VALUES%'
        fail_calls   int           NOT NULL,  -- fail this many matching calls, then let them through
        seq_start    bigint        NOT NULL   -- sync.fault_seq value when armed
    );
GO

-- Arm a fault: the next @fail_calls calls matching both patterns fail. One
-- fault at a time: arming clears earlier ones, because they share the sequence
-- and their callers would otherwise consume this fault's count.
CREATE OR ALTER PROCEDURE sync.usp_arm_fault
    @caller_like nvarchar(200), @sql_like nvarchar(200), @fail_calls int
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM sync.fault;
    DECLARE @start bigint = NEXT VALUE FOR sync.fault_seq;
    INSERT INTO sync.fault (caller_like, sql_like, fail_calls, seq_start) VALUES (@caller_like, @sql_like, @fail_calls, @start + 1);
END;
GO

-- The only way to run a statement on the ERP.
--
-- Stands in for the vendor driver behind the linked server:
--   * rejects any statement longer than the text limit, before sending it;
--   * raises a hard error when a statement runs to the linked server's query
--     timeout and returns nothing. Microsoft's provider reports a timeout only
--     as an informational message and returns no rows, with no error to catch
--     (see proofs/00-infrastructure.md). The vendor driver raised an error, so
--     this restores that behavior.
--
-- Callers capture results with INSERT INTO ... EXEC sync.erp_exec_at @sql.

CREATE OR ALTER PROCEDURE sync.erp_exec_at
    @sql     nvarchar(max),
    @caller  nvarchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @limit int = (SELECT CAST(value AS int) FROM sync.config WHERE name = N'text_limit');
    DECLARE @chars int = LEN(@sql + N'x') - 1;
    DECLARE @timeout_s int = (SELECT query_timeout FROM sys.servers WHERE name = N'ERP');
    DECLARE @started datetime2(3) = SYSDATETIME();
    DECLARE @msg nvarchar(400);

    IF @chars > @limit
    BEGIN
        SET @msg = CONCAT(N'Statement is ', @chars, N' characters; the driver limit is ', @limit, N'.');
        THROW 50001, @msg, 1;
    END;

    -- Injected faults (tests only): fail as the driver would on a timeout.
    DECLARE @fault int, @start bigint, @fails int, @n bigint;
    SELECT TOP 1 @fault = fault_id, @start = seq_start, @fails = fail_calls FROM sync.fault
    WHERE ISNULL(@caller, N'') LIKE caller_like AND @sql LIKE sql_like ORDER BY fault_id;
    IF @fault IS NOT NULL
    BEGIN
        SET @n = NEXT VALUE FOR sync.fault_seq;
        IF @n - @start < @fails
        BEGIN
            SET @msg = CONCAT(N'Query timeout expired (injected fault ', @fault, N', call ', @n - @start + 1, N' of ', @fails, N').');
            THROW 50002, @msg, 1;
        END;
    END;

    -- A SET option resets @@ROWCOUNT to 0. A timed-out call leaves it there;
    -- a call that returns rows sets it, however close to the limit it ran.
    DECLARE @rows int;
    SET NOCOUNT ON;
    EXEC (@sql) AT ERP;
    SET @rows = @@ROWCOUNT;

    DECLARE @ms int = DATEDIFF(millisecond, @started, SYSDATETIME());
    IF @timeout_s > 0 AND @ms >= @timeout_s * 1000 - 250 AND @rows = 0
    BEGIN
        SET @msg = CONCAT(N'Query timeout expired after ', @timeout_s, N' seconds.');
        THROW 50002, @msg, 1;
    END;

    INSERT INTO sync.driver_log (called_at, duration_ms, sql_chars, caller, rows_back, sql_text)
    VALUES (@started, @ms, @chars, @caller, @rows,
            CASE WHEN EXISTS (SELECT 1 FROM sync.config WHERE name = N'capture_sql' AND value = N'1') THEN @sql END);
END;
GO
