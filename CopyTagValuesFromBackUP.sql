USE [iomsdb]
GO
/****** Object:  StoredProcedure [dbo].[CopyTagValuesFromBackUP]    Script Date: 28.05.2026 19:21:51 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER   PROCEDURE [dbo].[CopyTagValuesFromBackUP]
    @Year INT,           -- Год (например, 2026)
    @Month INT,          -- Месяц (например, 5)
    @StartDay INT,       -- Число, с которого начинаем (например, 15)
    @DaysCount INT       -- Сколько дней берем (например, 4)
AS
BEGIN
    SET NOCOUNT ON;


    DECLARE @StartDate DATETIME = DATEFROMPARTS(@Year, @Month, @StartDay);
    DECLARE @EndDate DATETIME = DATEADD(DAY, @DaysCount, @StartDate);
    
    DECLARE @DynamicSQL NVARCHAR(MAX);

    BEGIN TRANSACTION

    BEGIN TRY
        DELETE FROM [iomsdb].[dbo].[ExternalTagValues];

        -- На .13 сервере это скомпилируется без ошибок, так как это просто текст
        SET @DynamicSQL = N'
            INSERT INTO [iomsdb].[dbo].[ExternalTagValues] (TagName, [Value], TS)
            SELECT TagName, [Value], TS
            FROM [0.0.0.0].[iomsdb].[dbo].[ExternalTagValuesBackUP]
            WHERE TS >= @Start AND TS < @End';

        EXEC sp_executesql @DynamicSQL, 
             N'@Start DATETIME, @End DATETIME', 
             @Start = @StartDate, 
             @End = @EndDate;

        COMMIT TRANSACTION;
        PRINT 'Данные успешно перенесены за период с ' + CAST(@StartDate AS VARCHAR) + ' по ' + CAST(DATEADD(SECOND, -1, @EndDate) AS VARCHAR);
    END TRY

    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
            
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR ('Ошибка при переносе данных: %s', 16, 1, @ErrorMessage);
    END CATCH
END
