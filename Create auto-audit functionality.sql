
print 'AUDIT SETUP START.'
GO

-- delete all existing objects
print 'Deleting existing objects.'
GO
if exists (select 0 from sys.tables t join sys.schemas s on t.schema_id = s.schema_id where t.name = 'Audit' and s.name = 'Audit') drop table [Audit].[Audit]
GO
if exists (select 0 from sys.tables t join sys.schemas s on t.schema_id = s.schema_id where t.name = 'AuditConfig' and s.name = 'Audit') drop table [Audit].[AuditConfig]
GO
if exists (select * from sys.objects o join sys.schemas s on o.schema_id = s.schema_id where o.type = 'P' and o.name = 's_PopulateAuditConfig' and s.name = 'audit') drop procedure [Audit].[s_PopulateAuditConfig]
GO
if exists (select * from sys.objects o join sys.schemas s on o.schema_id = s.schema_id where o.type = 'P' and o.name = 's_RecreateTableTriggers' and s.name = 'audit') drop procedure [Audit].[s_RecreateTableTriggers]
GO
if exists (select * from sys.objects o join sys.schemas s on o.schema_id = s.schema_id where o.type = 'FN' and o.name = 's_GetAuditSQL' and s.name = 'audit') drop function [Audit].[s_GetAuditSQL]
GO
IF EXISTS (SELECT * FROM sys.objects o JOIN sys.schemas s ON o.schema_id = s.schema_id WHERE o.type = 'V' AND o.name = 'v_AuditKey' AND s.name = 'Audit') DROP VIEW [Audit].[v_AuditKey];
GO
if exists (select 0 from sys.schemas s where s.name = 'Audit') drop schema [Audit]
GO



-- create schema [Audit]
print 'Creating [Audit] schema.'
GO
CREATE SCHEMA [Audit];
GO

-- create sequence AuditKey
PRINT 'Creating AuditKey view'
GO
CREATE VIEW [Audit].[v_AuditKey] 
AS
SELECT NEWID() AS [AuditKey];
GO

-- create table [Audit]
print 'Creating [Audit].[Audit] table.'
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
print 'Creating [Audit].[AuditConfig] table.'
GO
CREATE TABLE [Audit].[AuditConfig]
(
	[AuditConfigID] [int] IDENTITY(1,1) NOT NULL CONSTRAINT pk_AuditConfig PRIMARY KEY CLUSTERED,
	[TableName] [sysname] NOT NULL,
	[ColumnName] [sysname] NOT NULL,
	[EnableAudit] [bit] NOT NULL CONSTRAINT df_AuditConfig_EnableAudit DEFAULT (1),
	CONSTRAINT [uq_AuditConfig_TableName_ColumnName] UNIQUE NONCLUSTERED 
	(
		[Tablename] ASC,
		[ColumnName] ASC
	)
	WITH 
		(
			PAD_INDEX = OFF, 
			STATISTICS_NORECOMPUTE = OFF, 
			IGNORE_DUP_KEY = OFF, 
			ALLOW_ROW_LOCKS = ON, 
			ALLOW_PAGE_LOCKS = ON,
			DATA_COMPRESSION = PAGE,
			FILLFACTOR = 100
		)
)
WITH
(
	DATA_COMPRESSION = PAGE
);
GO


-- create procedure [PopulateAuditConfig]
print 'Creating [Audit].[s_PopulateAuditConfig] procedure.'
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
	Tablename,
	ColumnName
)
SELECT
    t.Name,
    c.Name
FROM sys.tables t
	INNER JOIN sys.columns c
		ON t.object_id = c.object_id
	INNER JOIN sys.schemas s
		ON t.schema_id = s.schema_id
WHERE (@apply_to_schema IS NULL OR s.name = @apply_to_schema)
AND	c.name NOT IN ('ID','LU','FU','LastUpdate','FirstUpdate','LastUpdateDate','FirstUpdateDate','CreateDate','CreatedDate','CreateBy','CreatedBy','ModifiedBy','ModifiedDate')
AND NOT EXISTS	(SELECT 0 FROM [Audit].[AuditConfig] ac WHERE ac.Tablename = t.[name] AND ac.ColumnName = c.[name])
AND c.user_type_id NOT IN (128,129,130) -- don't include hierarchy, geography, geometry, xml
;
GO

-- create procedure [RecreateTableTriggers]
print 'Creating [Audit].[s_RecreateTableTriggers] procedure.'
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
	PRINT '...Dropping Triggers.'
	SET @sql = N'IF OBJECT_ID (''[' + @schema_name +'].[' + @table_name + '_UPDATE_Audit]'',''TR'') IS NOT NULL BEGIN DROP TRIGGER [' + @schema_name +'].[' + @table_name + '_UPDATE_Audit] END;'
	EXEC sp_executesql @sql
	SET @sql = N'IF OBJECT_ID (''[' + @schema_name +'].[' + @table_name + '_INSERT_Audit]'',''TR'') IS NOT NULL BEGIN DROP TRIGGER [' + @schema_name +'].[' + @table_name + '_INSERT_Audit] END;'
	EXEC sp_executesql @sql
	SET @sql = N'IF OBJECT_ID (''[' + @schema_name +'].[' + @table_name + '_DELETE_Audit]'',''TR'') IS NOT NULL BEGIN DROP TRIGGER [' + @schema_name +'].[' + @table_name + '_DELETE_Audit] END;'
	EXEC sp_executesql @sql
	PRINT '...Creating Triggers.'

	-- UPDATE Trigger
	SET @sql = N''
	SET @sql = @sql + N'CREATE TRIGGER [' + @schema_name +'].[' + @table_name + '_UPDATE_Audit] ON [' + @schema_name +'].[' + @table_name + '] AFTER UPDATE AS '
	SET @sql = @sql + N'BEGIN '
	SET @sql = @sql + N'SET NOCOUNT ON '
	SET @sql = @sql + N'select * into #tmp' + @table_name + N'_Inserted from inserted;'
	SET @sql = @sql + N'select * into #tmp' + @table_name + N'_Deleted from deleted;'
	SET @sql = @sql + N'declare @sql nvarchar(max);'
	SET @sql = @sql + N'select @sql = [Audit].[s_GetAuditSQL](''' + @schema_name + ''',''' + @table_name + ''',''update'',''#tmp' + @table_name + N'_Inserted'',''#tmp' + @table_name + N'_Deleted'');'
	SET @sql = @sql + N'if isnull(@sql,'''') <> '''' exec sp_executesql @sql;'
	SET @sql = @sql + N'drop table #tmp' + @table_name + N'_Inserted;'
	SET @sql = @sql + N'drop table #tmp' + @table_name + N'_Deleted;'
	SET @sql = @sql + N'END'

	EXEC sp_executesql @sql
	SET @sql = N''
	SET @sql = @sql + N'CREATE TRIGGER [' + @schema_name +'].[' + @table_name + '_INSERT_Audit] ON [' + @schema_name +'].[' + @table_name + '] AFTER INSERT AS '
	SET @sql = @sql + N'BEGIN '
	SET @sql = @sql + N'SET NOCOUNT ON '
	SET @sql = @sql + N'select * into #tmp' + @table_name + N'_Inserted from inserted;'
	SET @sql = @sql + N'declare @sql nvarchar(max);'
	SET @sql = @sql + N'select @sql = [Audit].[s_GetAuditSQL](''' + @schema_name + ''',''' + @table_name + ''',''insert'',''#tmp' + @table_name + N'_Inserted'','''');'
	SET @sql = @sql + N'if isnull(@sql,'''') <> '''' exec sp_executesql @sql;'
	SET @sql = @sql + N'drop table #tmp' + @table_name + N'_Inserted;'
	SET @sql = @sql + N'END'

	EXEC sp_executesql @sql
	SET @sql = N''
	SET @sql = @sql + N'CREATE TRIGGER [' + @schema_name +'].[' + @table_name + '_DELETE_Audit] ON [' + @schema_name +'].[' + @table_name + '] AFTER DELETE AS '
	SET @sql = @sql + N'BEGIN '
	SET @sql = @sql + N'SET NOCOUNT ON '
	SET @sql = @sql + N'select * into #tmp' + @table_name + N'_Deleted from deleted;'
	SET @sql = @sql + N'declare @sql nvarchar(max);'
	SET @sql = @sql + N'select @sql = [Audit].[s_GetAuditSQL](''' + @schema_name + ''',''' + @table_name + ''',''delete'','''',''#tmp' + @table_name + N'_Deleted'');'
	SET @sql = @sql + N'if isnull(@sql,'''') <> '''' exec sp_executesql @sql;'
	SET @sql = @sql + N'drop table #tmp' + @table_name + N'_Deleted;'
	SET @sql = @sql + N'END'
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
			@retval nvarchar(max) = N''

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
			SET @retval = @retval + N' union '
		
		IF @audit_type = 'insert'
			BEGIN
				SET @retval = @retval + N'
					SELECT ''' + @column_name + ''' ColumnName, i.' + @table_name + N'GID, NULL OldValue, ' + 
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
					SELECT ''' + @column_name + N''' ColumnName, i.' + @table_name + N'GID, ' +
					CASE
						WHEN @is_max = 1 THEN N'NULL OldValue, NULL NewValue, CONVERT(nvarchar(500),d.['+ @column_name + N']) OldValueMax, CONVERT(nvarchar(500),i.['+ @column_name + N']) NewValueMax '
						ELSE N'CONVERT(nvarchar(max),d.['+ @column_name + N']) OldValue, CONVERT(nvarchar(max),i.['+ @column_name + N']) NewValue, NULL OldValueMax, NULL NewValueMax '
					END + N' FROM [' + @inserted_table_name + '] i ' +
					N'INNER JOIN [' + @deleted_table_name + '] d ON i.' + @table_name + N'GID = d.' + @table_name + N'GID AND (i.['+ @column_name + '] <> d.['+ @column_name + '] OR i.['+ @column_name + '] IS NOT NULL AND d.['+ @column_name + '] IS NULL)'
			END
		
		IF @audit_type = 'delete'
			BEGIN
				SET @retval = @retval + N'
					SELECT ''' + @column_name + N''' ColumnName, i.' + @table_name + N'GID, ' + 
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


-- execute setup procedures
print 'Executing setup procedures.'
GO
-- *** (2) ***
declare @TargetSchemaToAudit varchar(100) = 'dbo' -- schema to apply the audit function to
if isnull(@TargetSchemaToAudit,'') <> ''
begin
	print 'Executing [Audit].[s_PopulateAuditConfig].'
	exec  [Audit].[s_PopulateAuditConfig] @TargetSchemaToAudit
	print 'Executing [Audit].[s_RecreateTableTriggers].'
	exec  [Audit].[s_RecreateTableTriggers] @TargetSchemaToAudit
end
GO

print 'AUDIT SETUP COMPLETE.'
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