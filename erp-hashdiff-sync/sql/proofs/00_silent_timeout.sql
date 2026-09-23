-- A timed-out linked-server query inside TRY/CATCH, the way a procedure would run it.
SET NOCOUNT ON;
CREATE TABLE #pulled (n int);
BEGIN TRY
    INSERT INTO #pulled EXEC ('WAITFOR DELAY ''00:00:$(WAIT_S)''; SELECT 1') AT ERP;
    SELECT 'no error raised' AS outcome, @@ERROR AS error_number, (SELECT count(*) FROM #pulled) AS rows_pulled;
END TRY
BEGIN CATCH
    SELECT 'error caught' AS outcome, ERROR_NUMBER() AS error_number, (SELECT count(*) FROM #pulled) AS rows_pulled;
END CATCH
