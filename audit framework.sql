
PRINT 'AUDIT SETUP START.'
GO

-- delete all existing objects
PRINT 'Deleting existing objects.'
GO
IF EXISTS (SELECT 0 FROM sys.tables t INNER JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE t.name = 'Audit' AND s.name = 'Audit') DROP TABLE [Audit].[Audit]
GO
IF EXISTS (SELECT 0 FROM sys.tables t INNER JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE t.name = 'AuditConfig' AND s.name = 'Audit') DROP TABLE [Audit].[AuditConfig]
GO
IF EXISTS (SELECT * FROM sys.objects o INNER JOIN sys.schemas s ON o.schema_id = s.schema_id WHERE o.type = 'P' AND o.name = 's_PopulateAuditConfig' AND s.name = 'audit') DROP PROCEDURE [Audit].[s_PopulateAuditConfig]
GO
IF EXISTS (SELECT * FROM sys.objects o INNER JOIN sys.schemas s ON o.schema_id = s.schema_id WHERE o.type = 'P' AND o.name = 's_RecreateTableTriggers' AND s.name = 'audit') DROP PROCEDURE [Audit].[s_RecreateTableTriggers]
GO
IF EXISTS (SELECT * FROM sys.objects o INNER JOIN sys.schemas s ON o.schema_id = s.schema_id WHERE o.type = 'FN' AND o.name = 's_GetAuditSQL' AND s.name = 'audit') DROP FUNCTION [Audit].[s_GetAuditSQL]
GO
IF EXISTS (SELECT * FROM sys.objects o INNER JOIN sys.schemas s ON o.schema_id = s.schema_id WHERE o.type = 'V' AND o.name = 'v_AuditKey' AND s.name = 'Audit') DROP VIEW [Audit].[v_AuditKey];
GO
IF EXISTS (SELECT 0 FROM sys.schemas s WHERE s.name = 'Audit') DROP SCHEMA [Audit]
GO



-- create schema [Audit]
print 'Creating [Audit] schema.'
GO
CREATE SCHEMA [Audit];
GO

-- create AuditKey generating view
PRINT 'Creating AuditKey view'
GO
CREATE VIEW [Audit].[v_AuditKey] 
AS
SELECT NEWID() AS [AuditKey];
GO

-- create table [Audit]
PRINT 'Creating [Audit].[Audit] table.'
GO
CREATE TABLE [Audit].[Audit]
(
	[AuditID] [bigint] IDENTITY(1,1) NOT NULL CONSTRAINT pk_Audit PRIMARY KEY CLUSTERED,
	[AuditDateTime] [datetime2](7) NOT NULL CONSTRAINT df_Audit_AuditDateTime DEFAULT (SYSUTCDATETIME()),
	[LoginName] [nvarchar](500) NOT NULL,
	[SchemaName] [sysname] NOT NULL,
	[TableName] [sysname] NOT NULL,
	[TableID] [bigint] NOT NULL,
	[AuditKey] [uniqueidentifier] NOT NULL,
	[AuditType] [char](1) NOT NULL CONSTRAINT ck_Audit_AuditKey CHECK (AuditType IN ('I','D','U')),
	[ColumnName] [sysname] NOT NULL,
	[OldValue] [nvarchar](500) NULL,
	[NewValue] [nvarchar](500) NULL,
	[OldValueMax] [nvarchar](max) NULL,
	[NewValueMax] [nvarchar](max) NULL
) 
WITH 
(
	DATA_COMPRESSION = PAGE
);
GO

-- create table [AuditConfig]
PRINT 'Creating [Audit].[AuditConfig] table.';
GO

CREATE TABLE [Audit].[AuditConfig]
(
	[AuditConfigID] [int] IDENTITY(1,1) NOT NULL CONSTRAINT pk_AuditConfig PRIMARY KEY CLUSTERED,
	[SchemaName] [sysname] NOT NULL,
	[TableName] [sysname] NOT NULL,
	[ColumnName] [sysname] NOT NULL,
	[EnableAudit] [bit] NOT NULL CONSTRAINT df_AuditConfig_EnableAudit DEFAULT (1),
	CONSTRAINT [uq_AuditConfig_TableName_ColumnName] UNIQUE NONCLUSTERED 
	(
		[SchemaName] ASC,
		[Tablename] ASC,
		[ColumnName] ASC
	)
	WITH 
		(
			FILLFACTOR = 100
		)
);
GO


-- create procedure [PopulateAuditConfig]
PRINT 'Creating [Audit].[s_PopulateAuditConfig] procedure.';
GO

CREATE procedure [Audit].[s_PopulateAuditConfig]
(
	@apply_to_schema sysname = NULL,
	@repopulate bit = 0
)
AS
SET NOCOUNT ON

IF @repopulate  = 1 
	TRUNCATE TABLE [Audit].[AuditConfig]

INSERT  INTO [Audit].[AuditConfig]
(
	SchemaName,
	TableName,
	ColumnName
)
SELECT
	s.[name],
    t.[name],
    c.[name]
FROM sys.tables t
	INNER JOIN sys.columns c
		ON t.object_id = c.object_id
	INNER JOIN sys.schemas s
		ON t.schema_id = s.SCHEMA_ID
	INNER JOIN	(
				SELECT 
					TABLE_SCHEMA,
					TABLE_NAME
				FROM INFORMATION_SCHEMA.COLUMNS
				WHERE COLUMNPROPERTY(OBJECT_ID(TABLE_NAME),COLUMN_NAME,'IsIdentity') = 1
				) i
		ON t.name = i.TABLE_NAME
		AND s.name = i.TABLE_SCHEMA
WHERE (@apply_to_schema IS NULL OR s.name = @apply_to_schema)
AND	c.name NOT IN ('ID','LU','FU','LastUpdate','FirstUpdate','LastUpdateDate','FirstUpdateDate','CreateDate','CreatedDate','CreateBy','CreatedBy','ModifiedBy','ModifiedDate')
AND NOT EXISTS	(SELECT 0 FROM [Audit].[AuditConfig] ac WHERE ac.Tablename = t.[name] AND ac.ColumnName = c.[name] AND ac.SchemaName = s.[name])
AND c.user_type_id NOT IN (128,129,130,241) -- don't include hierarchy, geography, geometry, xml
AND EXISTS(	SELECT 0 FROM INFORMATION_SCHEMA.COLUMNS WHERE COLUMNPROPERTY(OBJECT_ID(TABLE_NAME),COLUMN_NAME,'IsIdentity') = 1 AND t.name = TABLE_NAME AND s.name = TABLE_SCHEMA) -- only tables with IDENTITY
;
GO

-- create procedure [RecreateTableTriggers]
PRINT 'Creating [Audit].[s_RecreateTableTriggers] procedure.'
GO

CREATE PROCEDURE [Audit].[s_RecreateTableTriggers]
(
	@apply_to_schema_name varchar(100) = NULL
)  
AS
SET NOCOUNT ON

DECLARE @schema_name sysname = N'',
		@table_name sysname = N'',
		@sql nvarchar(max) = N''

DECLARE curs CURSOR FOR 
	SELECT 
		s.name, 
		t.name 
	FROM sys.tables t 
		INNER JOIN sys.schemas s 
			ON t.schema_id = s.schema_id 
	WHERE (@apply_to_schema_name IS NULL OR s.name = @apply_to_schema_name)

OPEN curs
FETCH NEXT FROM curs INTO @schema_name, @table_name

WHILE @@FETCH_STATUS = 0
BEGIN
	PRINT 'Processing table: ' + @table_name
	PRINT '...Dropping Trigger.'

	SET @sql = N'IF OBJECT_ID (''[' + @schema_name + N'].[tr_' + @table_name + N'_Audit]'',''TR'') IS NOT NULL BEGIN DROP TRIGGER [' + @schema_name + N'].[tr_' + @table_name + N'_Audit] END;'
	EXEC sp_executesql @sql
	
	PRINT '...Creating Trigger.'

	DECLARE @lf nchar(1) = NCHAR(10)

	-- INSERT, UPDATE, DELETE Trigger
	SET @sql = N''
	SET @sql = @sql + N'CREATE TRIGGER [' + @schema_name + N'].[tr_' + @table_name + N'_Audit] ON [' + @schema_name + N'].[' + @table_name + N'] ' + @lf + N'AFTER INSERT, UPDATE, DELETE ' + @lf + N'AS ' + @lf
	SET @sql = @sql + N'SET NOCOUNT ON ' + @lf
	SET @sql = @sql + N'BEGIN ' + @lf
	SET @sql = @sql + N'  SELECT * INTO #tmp' + @table_name + N'_Inserted FROM inserted; ' + @lf
	SET @sql = @sql + N'  SELECT * INTO #tmp' + @table_name + N'_Deleted FROM deleted; ' + @lf + @lf
	SET @sql = @sql + N'  DECLARE @sql nvarchar(max), @action nvarchar(10) = ''insert''; ' + @lf + @lf
	SET @sql = @sql + N'  IF EXISTS(SELECT * FROM deleted) ' + @lf
	SET @sql = @sql + N'    BEGIN ' + @lf
	SET @sql = @sql + N'      SET @action = CASE WHEN EXISTS(SELECT * FROM inserted) THEN N''update'' ELSE N''delete'' END ' + @lf
	SET @sql = @sql + N'    END ' + @lf + @lf
	SET @sql = @sql + N'  SELECT @sql = [Audit].[s_GetAuditSQL](''' + @schema_name + N''',''' + @table_name + N''','''' + @action + '''',''#tmp' + @table_name + N'_Inserted'',''#tmp' + @table_name + N'_Deleted''); ' + @lf + @lf
	SET @sql = @sql + N'  IF ISNULL(@sql,'''') <> '''' EXEC sp_executesql @sql; ' + @lf + @lf
	SET @sql = @sql + N'  DROP TABLE #tmp' + @table_name + N'_Inserted; ' + @lf
	SET @sql = @sql + N'  DROP TABLE #tmp' + @table_name + N'_Deleted; ' + @lf
	SET @sql = @sql + N'END' + @lf
	
	EXEC sp_executesql @sql

	FETCH NEXT FROM curs INTO @schema_name, @table_name
END

CLOSE curs
DEALLOCATE curs;
GO

-- create function [GetAuditSQL]
print 'Creating [Audit].[s_GetAuditSQL] function.'
GO
CREATE FUNCTION [Audit].[s_GetAuditSQL]
(
	@schema_name sysname = N'',
	@table_name sysname = N'',
	@audit_type nvarchar(10) = N'',
	@inserted_table_name varchar(100),
	@deleted_table_name varchar(100)
) 
RETURNS nvarchar(max)
AS
BEGIN
	DECLARE @audit_key nvarchar(100),
			@retval nvarchar(max) = N'',
			@key_col sysname = N'';

	SELECT	@key_col = COLUMN_NAME
	FROM INFORMATION_SCHEMA.COLUMNS
	WHERE TABLE_SCHEMA = @schema_name
	AND TABLE_NAME = @table_name
	AND COLUMNPROPERTY(OBJECT_ID(TABLE_NAME),COLUMN_NAME,'IsIdentity') = 1

	SELECT	@audit_key = CAST(AuditKey AS nvarchar(100)) FROM [Audit].[v_AuditKey]

	IF NOT EXISTS (SELECT 0 FROM [Audit].[AuditConfig] WHERE Tablename = @table_name AND EnableAudit = 1)
		RETURN @retval

	SET @retval =	N'
					INSERT INTO [Audit].[Audit] (LoginName,AuditKey,SchemaName,TableName,AuditType,ColumnName,TableID,OldValue,NewValue,OldValueMax,NewValueMax) 
					SELECT ORIGINAL_LOGIN(), ''' + @audit_key + ''',''' + @schema_name + ''',''' + @table_name + ''',''' + LOWER(LEFT(@audit_type,1)) + ''', 
					* 
					FROM 
					(
					'

	DECLARE @add_union bit = 0,
			@column_name varchar(100) = '',
			@is_max bit = 0

	DECLARE curs CURSOR FOR 
		SELECT 
			ac.ColumnName,
			CASE
				WHEN c.DATA_TYPE IN ('nvarchar','varchar','varbinary','char','nchar') THEN CASE
																				WHEN c.CHARACTER_MAXIMUM_LENGTH > 500 OR c.CHARACTER_MAXIMUM_LENGTH = - 1 THEN 1
																				ELSE 0
																			END
				WHEN c.DATA_TYPE IN ('image','text','ntext') THEN 1
				ELSE 0
			END AS IsMax
		FROM Audit.AuditConfig ac
			INNER JOIN INFORMATION_SCHEMA.COLUMNS c
				ON ac.ColumnName = c.COLUMN_NAME
				AND ac.TableName = c.TABLE_NAME
		WHERE ac.Tablename = @table_name 
		AND ac.EnableAudit = 1

	OPEN curs
	FETCH NEXT FROM curs INTO @column_name, @is_max
	WHILE @@FETCH_STATUS = 0 
	BEGIN

		IF @add_union = 1 
			SET @retval = @retval + N' UNION '
		
		IF @audit_type = 'insert'
			BEGIN
				SET @retval = @retval + N'
					SELECT ''' + @column_name + ''' ColumnName, i.' + @key_col + N', NULL OldValue, ' + 
					CASE 
						WHEN @is_max = 1 THEN N'NULL NewValue' 
						ELSE N'CONVERT(nvarchar(500),i.['+ @column_name + N']) NewValue' 
					END + N', NULL OldValueMax, ' + 
					CASE 
						WHEN @is_max = 1 THEN N'CONVERT(nvarchar(max),i.[' + @column_name + N']) NewValueMax' 
						ELSE N'NULL NewValueMax' 
					END + 
					N' FROM [' + @inserted_table_name + N'] i'
			END
		
		IF @audit_type = 'update'
			BEGIN
				SET @retval = @retval + N'
					SELECT ''' + @column_name + N''' ColumnName, i.' + @key_col + N', ' +
					CASE
						WHEN @is_max = 1 THEN N'NULL OldValue, NULL NewValue, CONVERT(nvarchar(500),d.['+ @column_name + N']) OldValueMax, CONVERT(nvarchar(500),i.['+ @column_name + N']) NewValueMax '
						ELSE N'CONVERT(nvarchar(max),d.['+ @column_name + N']) OldValue, CONVERT(nvarchar(max),i.['+ @column_name + N']) NewValue, NULL OldValueMax, NULL NewValueMax '
					END + N' FROM [' + @inserted_table_name + '] i ' +
					N'INNER JOIN [' + @deleted_table_name + '] d ON i.' + @key_col + N' = d.' + @key_col + N' AND (i.['+ @column_name + '] <> d.['+ @column_name + '] OR i.['+ @column_name + '] IS NOT NULL AND d.['+ @column_name + '] IS NULL)'
			END
		
		IF @audit_type = 'delete'
			BEGIN
				SET @retval = @retval + N'
					SELECT ''' + @column_name + N''' ColumnName, i.' + @key_col + N', ' + 
					CASE
						WHEN @is_max = 1 THEN N'NULL OldValue, '
						ELSE N'CONVERT(nvarchar(500),i.['+ @column_name + N']) OldValue, '
					END + N'NULL NewValue, ' +
					CASE
						WHEN @is_max = 1 THEN N'CONVERT(nvarchar(max),i.[' + @column_name + N']) OldValueMax, '
						ELSE N'NULL OldValueMax, '
					END + N'NULL NewValueMax FROM [' + @deleted_table_name + N'] i'
			END
        
		SET @add_union = 1
		
		FETCH NEXT FROM curs INTO @column_name, @is_max
	END
    
	CLOSE curs
	DEALLOCATE curs
	
	SET @retval = @retval + N') d'
	
	RETURN @retval
END;
GO



DECLARE @schema sysname = 'dbo' -- schema to apply the audit function to

-- execute setup procedures
PRINT N'------------------------------------------------------------------------------------------'
PRINT N'Executing setup procedures on schema: ' + @schema
PRINT N'If other schemas need to be setup, please rerun this last section with schema name changed'

IF ISNULL(@schema,'') <> ''
BEGIN
	PRINT 'Executing [Audit].[s_PopulateAuditConfig].'
	EXEC  [Audit].[s_PopulateAuditConfig] @schema
	
	PRINT 'Executing [Audit].[s_RecreateTableTriggers].'
	EXEC  [Audit].[s_RecreateTableTriggers] @schema
END
GO

PRINT 'AUDIT SETUP COMPLETE.'
GO




-- Testing code
/*
-- *** REMOVE OUTER COMMENTING TAGS TO RUN TEST CODE ***

-- drop test table if it exists
if exists (select 0 from sys.tables t join sys.schemas s on t.schema_id = s.schema_id where t.name = 'Testing' and s.name = 'dbo') drop table [dbo].[Testing];

-- recreate test table
CREATE TABLE dbo.Testing
(
	TestingGID int NOT NULL IDENTITY(1,1) CONSTRAINT pk_Testing PRIMARY KEY CLUSTERED,
	FirstName varchar(100) NULL,
	LastName varchar(100) NULL,
	Notes varchar(max) NULL,
	OpenDate datetime NOT NULL CONSTRAINT df_Testing_OpenDate DEFAULT (GETDATE()),
	CloseDate datetime NULL,
	IsReal bit NOT NULL CONSTRAINT df_Testing_IsReal DEFAULT (0),
	CreatedBy sysname NOT NULL CONSTRAINT df_TestingCreatedBy DEFAULT ORIGINAL_LOGIN(),
	CreatedDate datetime2(7) NOT NULL CONSTRAINT df_TestingCreatedDate DEFAULT (SYSUTCDATETIME()),
	ModifiedBy sysname NOT NULL CONSTRAINT df_TestingModifiedBy DEFAULT ORIGINAL_LOGIN(),
	ModifiedDate datetime2(7) NOT NULL CONSTRAINT df_TestingModifiedDate DEFAULT (SYSUTCDATETIME())
);

-- repopulate auditconfig table and triggers
EXEC  [Audit].[s_PopulateAuditConfig] 'dbo';
EXEC  [Audit].[s_RecreateTableTriggers] 'dbo';

-- make sure the audit table is empty
SELECT * FROM Audit.Audit;
SELECT * FROM AUDIT.AuditConfig;

-- add some rows into testing table
INSERT INTO dbo.Testing (FirstName,LastName,IsReal) 
VALUES	
	('Joe','Blow',1),
	('Roy','Rogers',1);

-- see what went into audit table
SELECT * FROM Audit.Audit;

-- update a single record
UPDATE dbo.Testing
SET FirstName = 'Jose'
WHERE FirstName = 'Joe'
AND LastName = 'Blow';

-- see what went into audit table
SELECT * FROM Audit.Audit;

-- update multiple records
UPDATE dbo.Testing
SET CloseDate = '3/3/2013'

-- see what went into audit table
SELECT * FROM Audit.Audit;

-- insert long varchar data
INSERT INTO dbo.Testing (FirstName,LastName,Notes,IsReal) 
VALUES	
	('Marilyn','Monroe','This could be a really long note',1);

-- see what went into audit table
SELECT * FROM Audit.Audit;

-- update long varchar data
UPDATE dbo.Testing
SET Notes = 'This is a different really long note ' + REPLICATE('.',600)
WHERE Notes IS NOT NULL;

-- see what went into audit table
SELECT * FROM Audit.Audit;

-- delete multiple records
DELETE dbo.Testing
WHERE CloseDate IS NOT NULL;

-- see what went into audit table
SELECT * FROM Audit.Audit;

*/