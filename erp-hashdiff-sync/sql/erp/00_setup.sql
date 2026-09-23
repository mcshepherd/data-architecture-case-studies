-- Stand-in ERP: database and the read-only login the warehouse connects with.
-- Runs on the erp instance.

IF DB_ID('erp') IS NULL
    CREATE DATABASE erp;
GO

USE erp;
GO

IF SUSER_ID('erp_reader') IS NULL
    CREATE LOGIN erp_reader WITH PASSWORD = '$(READER_PASSWORD)', CHECK_POLICY = OFF;
GO

IF USER_ID('erp_reader') IS NULL
BEGIN
    CREATE USER erp_reader FOR LOGIN erp_reader;
    -- Read only. Like the vendor environment, the warehouse cannot create or
    -- change anything here.
    ALTER ROLE db_datareader ADD MEMBER erp_reader;
END
GO

ALTER LOGIN erp_reader WITH DEFAULT_DATABASE = erp;
GO
