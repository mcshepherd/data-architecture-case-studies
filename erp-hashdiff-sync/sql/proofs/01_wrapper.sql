-- The wrapper, sync.erp_exec_at, called the way the sync will call it. Prints a
-- markdown table. Runs on the warehouse.
USE warehouse;
SET NOCOUNT ON;
DECLARE @limit int = (SELECT CAST(value AS int) FROM sync.config WHERE name = N'text_limit');
DECLARE @head nvarchar(100) = N'SELECT 1 AS n /*', @tail nvarchar(10) = N'*/';
DECLARE @pad int = @limit - LEN(@head) - LEN(@tail);
DECLARE @tests TABLE (ord int, test nvarchar(100), stmt nvarchar(max));
INSERT INTO @tests VALUES
    (1, N'Statement exactly at the text limit', CONCAT(@head, REPLICATE(CAST(N'x' AS nvarchar(max)), @pad), @tail)),
    (2, N'Statement one character over', CONCAT(@head, REPLICATE(CAST(N'x' AS nvarchar(max)), @pad + 1), @tail)),
    (3, N'Statement that runs past the timeout', CONCAT(N'WAITFOR DELAY ''00:00:', $(WAIT_S), N'''; SELECT 1 AS n'));

CREATE TABLE #r (n int);
DECLARE @results TABLE (ord int, test nvarchar(100), chars int, outcome nvarchar(300));
DECLARE @ord int = 1, @test nvarchar(100), @stmt nvarchar(max);
WHILE @ord <= 3
BEGIN
    SELECT @test = test, @stmt = stmt FROM @tests WHERE ord = @ord;
    BEGIN TRY
        INSERT INTO #r EXEC sync.erp_exec_at @stmt, N'proof';
        INSERT INTO @results VALUES (@ord, @test, LEN(@stmt), N'Sent. Result returned.');
    END TRY
    BEGIN CATCH
        INSERT INTO @results VALUES (@ord, @test, LEN(@stmt), CONCAT(N'Error ', ERROR_NUMBER(), N': ', ERROR_MESSAGE()));
    END CATCH;
    SET @ord += 1;
END;

PRINT '| Test | Characters | Outcome |';
PRINT '|---|---|---|';
DECLARE @line nvarchar(max);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT CONCAT('| ', test, ' | ', FORMAT(chars, 'N0'), ' | ', outcome, ' |') FROM @results ORDER BY ord;
OPEN c; FETCH NEXT FROM c INTO @line;
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END;
CLOSE c; DEALLOCATE c;
