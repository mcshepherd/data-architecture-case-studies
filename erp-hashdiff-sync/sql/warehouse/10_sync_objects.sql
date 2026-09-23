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

MERGE sync.config AS t
USING (VALUES
    (N'text_limit', N'10000')          -- the vendor driver's query-text limit
) AS s (name, value)
ON t.name = s.name
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
        caller       nvarchar(200) NULL
    );
GO

-- The only way to run a statement on the ERP.
--
-- Stands in for the vendor driver behind the linked server:
--   * rejects any statement longer than the text limit, before sending it;
--   * raises a hard error when a statement runs to the linked server's query
--     timeout. Microsoft's provider reports a timeout only as an informational
--     message and returns no rows, with no error to catch (see
--     proofs/00-infrastructure.md). The vendor driver raised an error, so this
--     restores that behavior.
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

    EXEC (@sql) AT ERP;

    DECLARE @ms int = DATEDIFF(millisecond, @started, SYSDATETIME());
    IF @timeout_s > 0 AND @ms >= @timeout_s * 1000 - 250
    BEGIN
        SET @msg = CONCAT(N'Query timeout expired after ', @timeout_s, N' seconds.');
        THROW 50002, @msg, 1;
    END;

    INSERT INTO sync.driver_log (called_at, duration_ms, sql_chars, caller)
    VALUES (@started, @ms, @chars, @caller);
END;
GO
