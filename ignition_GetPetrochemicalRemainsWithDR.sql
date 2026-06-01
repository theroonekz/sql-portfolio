
/*
получение данных о резервуарах (продукты, уровень, объем, остатки и т.д.)
*/
DECLARE @case_id INT = {0};

-- для сообщения об ошибке
DECLARE @err_msg NVARCHAR(MAX);

--* 
begin try

-- Очистка обменной таблицы перед началом работы
TRUNCATE TABLE [ext].[GetPetrochemicalRemainsWithDR];

-- конечная дата периода
DECLARE @end_day DATETIME2 = (SELECT cs.endTime FROM dbo.cases AS cs WHERE cs.id = @case_id);

IF @end_day IS NULL
BEGIN
    SET @err_msg = 'Не найден конечный день для кейса с Id = ' + CAST(@case_id AS NVARCHAR(10));
    THROW 50000, @err_msg, 1;
END

DECLARE @formatted_end_day NVARCHAR(10) = FORMAT(@end_day, 'yyyy-MM-dd');

PRINT 'Выборка остатков на дату: ' + @formatted_end_day;


DECLARE @SamplingPointID NVARCHAR(25);
DECLARE @SamplingPointIDInt INT;

IF OBJECT_ID('tempdb..#TempPetrochemicalRemainsWithDR') IS NOT NULL
    DROP TABLE #TempPetrochemicalRemainsWithDR;

CREATE TABLE #TempPetrochemicalRemainsWithDR (
    [ID]                 INT,
    [SamplingPointID]    INT,
    [Datetime]           DATETIME,
    [Level]              FLOAT (53),
    [Volume]             FLOAT (53),
    [Mass]               FLOAT (53),
    [MassWithoutDR]      FLOAT (53),
    [FreeVolume]         FLOAT (53),
    [PetrochemicalID]    INT,
    [pShortName]         NVARCHAR (250),
    [IsConfirmed]        BIT,
    [DeadResidueMass]    FLOAT (53),
    [TankCapacity]       FLOAT (53),
    [TankUsefulCapacity] FLOAT (53),
    [Temperature]        FLOAT (53),
    [LabDensity]         FLOAT (53),
    [LabDensityDatetime] DATETIME,
    [Density]            FLOAT (53),
	[Passport]			 NVARCHAR (250)
);

DECLARE sampling_point_cursor CURSOR FOR
	SELECT ats.settings 
	FROM 
		dbo.AttrSettings AS ats inner join Objects obj on ats.afElement=obj.SfId 
	WHERE LOWER(ats.attribute) = LOWER(N'TagID') 
		and obj.SfName like 'T_%' 
		and nullif(trim(ats.settings) , '') IS NOT NULL
		AND ats.IsDeleted = 0
    
OPEN sampling_point_cursor;

FETCH NEXT FROM sampling_point_cursor INTO @SamplingPointID;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @SamplingPointIDInt = CAST(@SamplingPointID AS INT);
    -- Вызов хранимой процедуры и вставка результата в таблицу
    INSERT INTO #TempPetrochemicalRemainsWithDR
    EXEC [172.17.100.101].[DISP].[dbo].[GetPetrochemicalRemainsWithDR] 
        @date = @formatted_end_day,
        @hour = N'00',
        @min = N'00',
        @samplingPointID  = @SamplingPointIDInt;

	INSERT INTO [ext].[GetPetrochemicalRemainsWithDR] (
			[ID], [SamplingPointID], [Datetime], [Level], [Volume], [Mass], 
			[MassWithoutDR], [FreeVolume], [PetrochemicalID], [pShortName], 
			[IsConfirmed], [DeadResidueMass], [TankCapacity], [TankUsefulCapacity], 
			[Temperature], [LabDensity], [LabDensityDatetime], [Density], [Passport]
		)
		SELECT 
			[ID], 
			ISNULL([SamplingPointID], 0), 
			ISNULL([Datetime], '1900-01-01') AS [Datetime],
			ISNULL([Level], 0), 
			ISNULL([Volume], 0), 
			ISNULL([Mass], 0), 
			ISNULL([MassWithoutDR], 0), 
			ISNULL([FreeVolume], 0), 
			ISNULL([PetrochemicalID], 0), 
			ISNULL([pShortName], '') AS [pShortName], 
			ISNULL([IsConfirmed], 0), 
			ISNULL([DeadResidueMass], 0), 
			ISNULL([TankCapacity], 0), 
			ISNULL([TankUsefulCapacity], 0), 
			ISNULL([Temperature], 0), 
			ISNULL([LabDensity], 0), 
			ISNULL([LabDensityDatetime], '1900-01-01') AS [LabDensityDatetime], 
			ISNULL([Density], 0),
			ISNULL([Passport], '')
		FROM #TempPetrochemicalRemainsWithDR;

	DELETE FROM #TempPetrochemicalRemainsWithDR
    -- Чтение следующей строки курсора
    FETCH NEXT FROM sampling_point_cursor INTO @SamplingPointID;
END

-- Закрытие и освобождение ресурсов курсора
CLOSE sampling_point_cursor;
DEALLOCATE sampling_point_cursor;

DROP TABLE #TempPetrochemicalRemainsWithDR;

END TRY
BEGIN CATCH
    -- Запись ошибки в таблицу
    INSERT INTO dbo.ErrorLog (ErrorMessage)
    VALUES (ERROR_MESSAGE());
    
    -- Повторное выбрасывание ошибки
    THROW;
END CATCH;