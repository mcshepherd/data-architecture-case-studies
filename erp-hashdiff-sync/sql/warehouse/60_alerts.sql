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

-- One email per run, only if a table ended the run anything but succeeded.
-- A table's outcome is its last attempt (sync.fn_run_outcome), so a table
-- that failed once and then succeeded is not an alert. A variance-guard stop
-- is called out separately, because it needs a person to look before the next
-- run, not just a rerun.
CREATE OR ALTER PROCEDURE sync.usp_alert_run
    @run_id int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @outcome TABLE (table_name sysname, status varchar(12), attempts int, message nvarchar(2000));
    INSERT INTO @outcome SELECT table_name, status, attempts, message FROM sync.fn_run_outcome(@run_id);

    DECLARE @n_bad int = (SELECT COUNT(*) FROM @outcome WHERE status <> 'succeeded');
    IF @n_bad = 0 RETURN;

    DECLARE @n_variance int = (SELECT COUNT(*) FROM @outcome WHERE status = 'variance');
    DECLARE @n_failed int = @n_bad - @n_variance;
    DECLARE @n_ok int = (SELECT COUNT(*) FROM @outcome) - @n_bad;
    DECLARE @run_at datetime2(0) = (SELECT run_at FROM sync.run WHERE run_id = @run_id);
    DECLARE @recipients nvarchar(400) = (SELECT value FROM sync.config WHERE name = N'alert_recipients');
    DECLARE @nl nchar(1) = NCHAR(10), @gap nchar(2) = NCHAR(10) + NCHAR(10);

    DECLARE @subject nvarchar(300) = CONCAT(N'[sync] Run ', @run_id, N': ',
        IIF(@n_failed > 0, CONCAT(@n_failed, N' table', IIF(@n_failed = 1, N'', N's'), N' failed'), N''),
        IIF(@n_failed > 0 AND @n_variance > 0, N', ', N''),
        IIF(@n_variance > 0, CONCAT(@n_variance, N' stopped by the variance guard'), N''));

    DECLARE @body nvarchar(max) = CONCAT(
        N'Run ', @run_id, N' (', CONVERT(nvarchar(19), @run_at, 120), N'): ',
        @n_ok, N' table', IIF(@n_ok = 1, N'', N's'), N' succeeded, ', @n_bad, N' did not.', @nl, @nl,
        (SELECT STRING_AGG(CAST(CONCAT(
                    table_name, N': ',
                    CASE status
                        WHEN 'variance' THEN N'stopped by the variance guard'
                        WHEN 'interrupted' THEN N'interrupted before it finished'
                        WHEN 'not started' THEN N'never started'
                        ELSE N'failed' END,
                    IIF(attempts > 0, CONCAT(N' after ', attempts, N' attempt', IIF(attempts = 1, N'', N's')), N''), N'.', @nl,
                    IIF(message IS NULL, N'', CONCAT(N'  ', message, @nl)),
                    CASE
                        WHEN status = 'variance' THEN N'  Not retried. The replica was left untouched. Check the source before the next run.'
                        WHEN status = 'not started' THEN N'  The replica was not touched.'
                        WHEN message LIKE N'Error 50023:%' THEN N'  The replica was left as it was. It will fail every run until it is rebuilt.'
                        ELSE N'  The replica was left as it was before this run; the next run picks up what this one missed.' END)
                AS nvarchar(max)), @gap) WITHIN GROUP (ORDER BY status, table_name)
         FROM @outcome WHERE status <> 'succeeded'));

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
