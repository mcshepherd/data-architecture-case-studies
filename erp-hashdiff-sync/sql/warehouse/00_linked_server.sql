-- Warehouse: database and the linked server to the stand-in ERP.
-- Runs on the warehouse instance.

IF DB_ID('warehouse') IS NULL
    CREATE DATABASE warehouse;
GO

IF EXISTS (SELECT 1 FROM sys.servers WHERE name = 'ERP')
    EXEC sp_dropserver @server = 'ERP', @droplogins = 'droplogins';
GO

EXEC sp_addlinkedserver
    @server     = 'ERP',
    @srvproduct = '',
    @provider   = 'MSOLEDBSQL',
    @datasrc    = 'erp,1433',
    @catalog    = 'erp',
    @provstr    = 'TrustServerCertificate=yes';

-- Every warehouse login reaches the ERP as the read-only reader.
EXEC sp_addlinkedsrvlogin
    @rmtsrvname  = 'ERP',
    @useself     = 'false',
    @locallogin  = NULL,
    @rmtuser     = 'erp_reader',
    @rmtpassword = '$(READER_PASSWORD)';

-- EXEC (...) AT ERP needs RPC out.
EXEC sp_serveroption 'ERP', 'rpc out', 'true';

-- Keep INSERT ... EXEC (...) AT ERP inside a local transaction from being
-- promoted to a distributed transaction.
EXEC sp_serveroption 'ERP', 'remote proc transaction promotion', 'false';

-- The vendor driver's hard timeout, scaled down with the data.
EXEC sp_serveroption 'ERP', 'query timeout', '$(QUERY_TIMEOUT_S)';
GO

-- A second linked server for the audit only. Same read-only login, but no
-- timeout and no wrapper: the audit is a referee, not part of the process.
IF EXISTS (SELECT 1 FROM sys.servers WHERE name = 'ERP_AUDIT')
    EXEC sp_dropserver @server = 'ERP_AUDIT', @droplogins = 'droplogins';
GO

EXEC sp_addlinkedserver
    @server     = 'ERP_AUDIT',
    @srvproduct = '',
    @provider   = 'MSOLEDBSQL',
    @datasrc    = 'erp,1433',
    @catalog    = 'erp',
    @provstr    = 'TrustServerCertificate=yes';
EXEC sp_addlinkedsrvlogin
    @rmtsrvname  = 'ERP_AUDIT',
    @useself     = 'false',
    @locallogin  = NULL,
    @rmtuser     = 'erp_reader',
    @rmtpassword = '$(READER_PASSWORD)';
EXEC sp_serveroption 'ERP_AUDIT', 'rpc out', 'true';
EXEC sp_serveroption 'ERP_AUDIT', 'query timeout', '0';
GO
