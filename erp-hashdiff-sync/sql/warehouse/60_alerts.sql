-- Failure alerts by email. Runs on the warehouse instance.
--
-- At the original site, the SSIS package ran a Send Mail task on failure.
-- Here the runner calls sync.usp_alert_run at the end of every run, and the
-- email goes out through Database Mail, the same mechanism under that task.
-- In this repository the mail server is Mailpit, which catches every message
-- and delivers none (see compose.yaml).

USE master;
GO
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1;
RECONFIGURE;
GO

USE msdb;
GO
IF EXISTS (SELECT 1 FROM dbo.sysmail_profile WHERE name = N'sync_alerts')
    EXEC dbo.sysmail_delete_profile_sp @profile_name = N'sync_alerts';
IF EXISTS (SELECT 1 FROM dbo.sysmail_account WHERE name = N'sync_alerts')
    EXEC dbo.sysmail_delete_account_sp @account_name = N'sync_alerts';
EXEC dbo.sysmail_add_account_sp
    @account_name    = N'sync_alerts',
    @email_address   = N'sync@warehouse.local',
    @display_name    = N'Warehouse sync',
    @mailserver_name = N'mailpit',
    @port            = 1025;
EXEC dbo.sysmail_add_profile_sp @profile_name = N'sync_alerts';
EXEC dbo.sysmail_add_profileaccount_sp
    @profile_name = N'sync_alerts', @account_name = N'sync_alerts', @sequence_number = 1;
GO

USE warehouse;
GO

MERGE sync.config AS t
USING (VALUES
    (N'alert_recipients', N'data-team@example.com')
) AS s (name, value)
ON t.name = s.name
WHEN MATCHED THEN UPDATE SET value = s.value
WHEN NOT MATCHED THEN INSERT (name, value) VALUES (s.name, s.value);
GO

IF OBJECT_ID('sync.alert') IS NULL
    CREATE TABLE sync.alert (
        alert_id     int            IDENTITY PRIMARY KEY,
        run_id       int            NOT NULL,
        sent_at      datetime2(0)   NOT NULL DEFAULT SYSDATETIME(),
        recipients   nvarchar(400)  NOT NULL,
        subject      nvarchar(300)  NOT NULL,
        body         nvarchar(max)  NOT NULL,
        mailitem_id  int            NULL  -- msdb.dbo.sysmail_allitems
    );
GO

-- One email per run, only if a table ended the run in failure. A table's
-- outcome is its last attempt: a table that failed once and then succeeded
-- is not an alert. A variance-guard stop is called out separately, because it
-- needs a person to look before the next run, not just a rerun.
CREATE OR ALTER PROCEDURE sync.usp_alert_run
    @run_id int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @failed TABLE (table_name sysname, status varchar(12), attempts int, message nvarchar(2000));
    INSERT INTO @failed
    SELECT l.table_name, l.status, a.attempts, l.message
    FROM sync.run_table_log l
    CROSS APPLY (SELECT COUNT(*) AS attempts FROM sync.run_table_log x
                 WHERE x.run_id = l.run_id AND x.table_name = l.table_name) a
    WHERE l.run_id = @run_id
      AND l.log_id = (SELECT MAX(log_id) FROM sync.run_table_log x WHERE x.run_id = l.run_id AND x.table_name = l.table_name)
      AND l.status <> 'succeeded';

    IF NOT EXISTS (SELECT 1 FROM @failed) RETURN;

    DECLARE @n_failed int = (SELECT COUNT(*) FROM @failed WHERE status = 'failed');
    DECLARE @n_variance int = (SELECT COUNT(*) FROM @failed WHERE status = 'variance');
    DECLARE @n_ok int = (SELECT COUNT(DISTINCT table_name) FROM sync.run_table_log WHERE run_id = @run_id) - (SELECT COUNT(*) FROM @failed);
    DECLARE @run_at datetime2(0) = (SELECT run_at FROM sync.run WHERE run_id = @run_id);
    DECLARE @recipients nvarchar(400) = (SELECT value FROM sync.config WHERE name = N'alert_recipients');
    DECLARE @nl nchar(1) = NCHAR(10), @gap nchar(2) = NCHAR(10) + NCHAR(10);

    DECLARE @subject nvarchar(300) = CONCAT(N'[sync] Run ', @run_id, N': ',
        IIF(@n_failed > 0, CONCAT(@n_failed, N' table', IIF(@n_failed = 1, N'', N's'), N' failed'), N''),
        IIF(@n_failed > 0 AND @n_variance > 0, N', ', N''),
        IIF(@n_variance > 0, CONCAT(@n_variance, N' stopped by the variance guard'), N''));

    DECLARE @body nvarchar(max) = CONCAT(
        N'Run ', @run_id, N' (', CONVERT(nvarchar(19), @run_at, 120), N'): ', @n_ok, N' tables succeeded, ',
        @n_failed + @n_variance, N' did not.', @nl, @nl,
        (SELECT STRING_AGG(CAST(CONCAT(
                    table_name, N': ', IIF(status = 'variance', N'stopped by the variance guard', N'failed'),
                    N' after ', attempts, N' attempt', IIF(attempts = 1, N'', N's'), N'.', @nl,
                    N'  ', message, @nl,
                    IIF(status = 'variance',
                        N'  Not retried. The replica was left untouched. Check the source before the next run.',
                        N'  The replica was left as it was before this run; the next run picks up what this one missed.'))
                AS nvarchar(max)), @gap) WITHIN GROUP (ORDER BY status, table_name)
         FROM @failed));

    DECLARE @mailitem_id int;
    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = N'sync_alerts',
        @recipients   = @recipients,
        @subject      = @subject,
        @body         = @body,
        @mailitem_id  = @mailitem_id OUTPUT;

    INSERT INTO sync.alert (run_id, recipients, subject, body, mailitem_id)
    VALUES (@run_id, @recipients, @subject, @body, @mailitem_id);
END;
GO
