This SQL Server auditing framework consists of a table which will 
store the details of each change at a column level.  This is 
accomplished by an audit trigger attached at the table level.

The Audit.Audit table stores the changes.  In a production system, 
this table will grow very quickly and should be put on a separate
filegroup and if possible, separate drive.

The Audit.AuditConfig table determines which columns will be
audited.  The values can be manually added, or you can execute the
s_PopulateAuditConfig procedure to initialize the table.

The s_RecreateTableTriggers procedure will recreate a trigger on all
of the tables within that schema that have an IDENTITY column.  The
framework currently doesn't allow auditing on tables without an 
unique numeric column.

There are two versions. (separate branches)0  One for Windows 
Authentication and another for web applications which use a single 
application id.  The web application branch requires the particular 
application convention of all database tables having a ModifiedBy 
field and all data changes requiring the ModifiedBy field be updated 
to the actual user id.

This framework was derived from code from this article:
http://www.codeproject.com/articles/441498/quick-sql-server-auditing-setup