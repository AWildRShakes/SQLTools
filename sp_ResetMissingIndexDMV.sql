CREATE OR ALTER PROCEDURE dbo.usp_ResetMissingIndexDMV
AS
BEGIN
    SET NOCOUNT ON;

    DROP TABLE IF EXISTS #TargetTables;

    SELECT DISTINCT
        PARSENAME(REPLACE(REPLACE(mid.[statement], '[', ''), ']', ''), 2) AS schema_name,
        PARSENAME(REPLACE(REPLACE(mid.[statement], '[', ''), ']', ''), 1) AS table_name
    INTO #TargetTables
    FROM sys.dm_db_missing_index_details AS mid
    WHERE mid.database_id = DB_ID();

    DROP TABLE IF EXISTS #IndexTargets;

    SELECT
        tt.schema_name,
        tt.table_name,
        MIN(c.name) AS column_name
    INTO #IndexTargets
    FROM #TargetTables AS tt
    INNER JOIN sys.tables AS t
        ON  t.name      = tt.table_name  COLLATE DATABASE_DEFAULT   -- ← temp table vs catalog
        AND t.schema_id = SCHEMA_ID(tt.schema_name COLLATE DATABASE_DEFAULT)  -- ← SCHEMA_ID() input
    INNER JOIN sys.columns AS c
        ON  c.object_id   = t.object_id
        AND c.is_nullable = 0
        AND c.is_computed = 0
    INNER JOIN sys.types AS ty
        ON  ty.user_type_id = c.user_type_id
        AND ty.name COLLATE DATABASE_DEFAULT NOT IN (               -- ← catalog vs literal
            'text', 'ntext', 'image',
            'xml', 'geography', 'geometry',
            'hierarchyid', 'sql_variant'
        )
    GROUP BY
        tt.schema_name,
        tt.table_name;

    DECLARE
        @schema_name  NVARCHAR(128),
        @table_name   NVARCHAR(128),
        @column_name  NVARCHAR(128),
        @index_name   NVARCHAR(128),
        @sql          NVARCHAR(MAX);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT schema_name, table_name, column_name
        FROM #IndexTargets;

    OPEN cur;
    FETCH NEXT FROM cur INTO @schema_name, @table_name, @column_name;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @index_name = N'IX_DMVReset_Temp_'
                        + @table_name
                        + N'_'
                        + @column_name;

        IF LEN(@index_name) > 128
            SET @index_name = LEFT(@index_name, 128);

        BEGIN TRY
            SET @sql = N'CREATE INDEX '
                + QUOTENAME(@index_name)
                + N' ON '
                + QUOTENAME(@schema_name) + N'.' + QUOTENAME(@table_name)
                + N' (' + QUOTENAME(@column_name) + N')'
                + N' WHERE ' + QUOTENAME(@column_name) + N' IS NULL;';

            EXEC sp_executesql @sql;

            SET @sql = N'DROP INDEX '
                + QUOTENAME(@index_name)
                + N' ON '
                + QUOTENAME(@schema_name) + N'.' + QUOTENAME(@table_name) + N';';

            EXEC sp_executesql @sql;

            PRINT N'Reset DMV entry for: '
                + QUOTENAME(@schema_name) + N'.' + QUOTENAME(@table_name)
                + N' (column: ' + @column_name + N')';
        END TRY
        BEGIN CATCH
            PRINT N'SKIPPED '
                + QUOTENAME(@schema_name) + N'.' + QUOTENAME(@table_name)
                + N' — '
                + ERROR_MESSAGE();
        END CATCH;

        FETCH NEXT FROM cur INTO @schema_name, @table_name, @column_name;
    END;

    CLOSE cur;
    DEALLOCATE cur;

END;
GO