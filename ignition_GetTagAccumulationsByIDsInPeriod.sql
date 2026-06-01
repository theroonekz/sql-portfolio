/*
получение данных о накоплениях по расходомерам

Обновление 06.04.2026:
	- Удаление дубликатов (последний фрагмент кода)
*/
DECLARE @case_id INT = {0};

-- для сообщения об ошибке
DECLARE @err_msg NVARCHAR(MAX);

-- Очистка обменной таблицы перед началом работы
TRUNCATE TABLE [ext].[GetTagAccumulationsByIDsInPeriod];

-- начальная дата периода
DECLARE @start_day DATETIME2 = (SELECT cs.StartTime FROM dbo.cases AS cs WHERE cs.id = @case_id);

IF @start_day IS NULL
BEGIN
    SET @err_msg = 'Не найден стартовый день для кейса с Id = ' + CAST(@case_id AS NVARCHAR(10));
    THROW 50000, @err_msg, 1;
END

-- количество дней для периода
DECLARE @count_day INT = (SELECT ABS(DATEDIFF(DAY, starttime, endtime)) FROM dbo.Cases WHERE Id = @case_id);

IF @count_day IS NULL OR @count_day < 1
BEGIN
    SET @err_msg = 'Неверное количество дней для кейса с Id = ' + CAST(@case_id AS NVARCHAR(10)) + ' (' + CAST(@count_day AS NVARCHAR(10)) + ')';
    THROW 50000, @err_msg, 1;
END

-- Получение списка тегов для получения накоплений
DECLARE @tag_ids NVARCHAR(MAX) = (
    SELECT STRING_AGG(ats.settings, ',') 
    FROM 
	    dbo.AttrSettings AS ats inner join Objects obj on ats.afElement=obj.SfId 
    WHERE 
		LOWER(ats.attribute) = LOWER(N'TagID') 
		and obj.SfName like 'M_%' 
		and nullif(trim(ats.settings) , '') IS NOT NULL    
		and ats.IsDeleted = 0
)

-- если переменная @tag_ids равна NULL, это значит, что нет тегов для получения накоплений 
-- мы прекращаем выполнение скрипта
IF @tag_ids IS NULL
BEGIN
    SET @err_msg = 'Нет тегов для получения накоплений. Выполнение скрипта прекращено.';
    THROW 50000, @err_msg, 1;
END

-- Код ниже для разделения строки списка тегов на подстроки меньше или равные 4000 символов
-- так как GetTagAccumulationsByIDsInPeriod в параметре @tagIDs принимает строку длиной не более 4000 символов 

DECLARE @max_length INT = 4000; -- максимальная длина строки с тегами как параметра для хранимой процедуры
DECLARE @tag_ids_part NVARCHAR(4000); -- подстрока списка тегов, которая будет передаваться в хранимую процедуру
DECLARE @start_pos INT = 1; -- начальная позиция в строке с тегами
DECLARE @delimiter_pos INT; -- позиция запятой в строке с тегами
DECLARE @tag_ids_length INT = LEN(@tag_ids); -- длина строки со всеми тегами
DECLARE @delimiter CHAR(1) = ',';

-- *debug* 
PRINT 'Длина списка тегов: ' + CAST(@tag_ids_length AS NVARCHAR(10));

IF OBJECT_ID('tempdb..#TempTableAccumulation') IS NOT NULL
    DROP TABLE #TempTableAccumulation;

CREATE TABLE #TempTableAccumulation (
    [TagID] NVARCHAR(250),
    [Position] NVARCHAR(250),
    [FullName] NVARCHAR(250),
    [Accumulation] FLOAT(53),
);

WHILE @start_pos <= @tag_ids_length
BEGIN
    SET @tag_ids_part = N''; 

    WHILE @start_pos <= @tag_ids_length
    BEGIN
        SET @delimiter_pos = CHARINDEX(@delimiter, @tag_ids, @start_pos);
        IF @delimiter_pos > 0
        BEGIN
            -- Если найдена запятая, то расчитываем длину подстроки-тега с запятой
            DECLARE @tag_length INT = @delimiter_pos - @start_pos + 1;
            IF @tag_length + LEN(@tag_ids_part) > @max_length
            BEGIN
                -- слишком большая подстрока, будет переполнение параметра хранимой процедуры
                BREAK;
            END
            -- если длина строки с тегами и найденным тегом не превышает максимальную,
            -- то добавляем тег к строке с тегами
            SET @tag_ids_part = @tag_ids_part + SUBSTRING(@tag_ids, @start_pos, @tag_length);
            SET @start_pos = @delimiter_pos + 1;
        END
        ELSE
        BEGIN
            -- Если запятая не найдена, то это последний тег в списке
            -- и его надо добавить к строке с тегами, при условии, 
            -- что длина строки с тегами и новым не превышает максимальную
            IF @tag_ids_length - @start_pos + 1 + LEN(@tag_ids_part) > @max_length
            BEGIN
                -- слишком большая подстрока, будет переполнение параметра хранимой процедуры
                BREAK;
            END 
            ELSE 
            BEGIN
                SET @tag_ids_part = @tag_ids_part + SUBSTRING(@tag_ids, @start_pos, @tag_ids_length - @start_pos + 1);
                SET @start_pos = @tag_ids_length + 1; -- Установить @start_pos на конец строки
            END
        END
    END

    -- вышли из внутреннего цикла по break
    IF LEN(@tag_ids_part) > 0
    BEGIN
        -- если @tag_ids_part в конце содержит @delimiter, то его надо удалить
        IF RIGHT(@tag_ids_part, 1) = @delimiter
        BEGIN
            SET @tag_ids_part = LEFT(@tag_ids_part, LEN(@tag_ids_part) - 1);
        END

        -- *debug*
        --PRINT 'Длина строки-параметра с тегами: ' + CAST(LEN(@tag_ids_part) AS NVARCHAR(10));
        --PRINT 'Строка-параметр с  тегами: ' + LEFT(@tag_ids_part, 37) + ' ... ' + RIGHT(@tag_ids_part, 37);

		DELETE FROM #TempTableAccumulation;

		INSERT INTO #TempTableAccumulation
		EXEC [172.17.100.101].[MESConfiguration].[dbo].[GetTagAccumulationsByIDsInPeriod]
			@tagIDs = @tag_ids_part,
			@startDay = @start_day,
			@countDay = @count_day,
			@accumulationType = 4;

		INSERT INTO [ext].[GetTagAccumulationsByIDsInPeriod] ([TagID], [Position], [FullName], [Accumulation])
		SELECT 
			[TagID], 
			ISNULL([Position], '') AS [Position], 
			ISNULL([FullName], '') AS [FullName], 
			ISNULL([Accumulation], 0) AS [Accumulation]
		FROM #TempTableAccumulation;
/*
		INSERT INTO [ext].[GetTagAccumulationsByIDsInPeriod] ([TagID], [Position], [FullName], [Accumulation])
		SELECT 
			[TagID], 
			[Position], 
			[FullName], 
			[Accumulation]
		FROM #TempTableAccumulation
		WHERE [Position] IS NOT NULL
		  AND [FullName] IS NOT NULL
		  AND [Accumulation] IS NOT NULL;
*/
    END
END;
WITH CTE_Duplicates AS (
    SELECT 
        [TagID], 
        [Position], 
        [Accumulation],
        ROW_NUMBER() OVER (
            PARTITION BY [TagID], [Position], [Accumulation] 
            ORDER BY (SELECT NULL)
        ) AS RowNum
    FROM [ext].[GetTagAccumulationsByIDsInPeriod]
)
DELETE FROM CTE_Duplicates WHERE RowNum > 1;