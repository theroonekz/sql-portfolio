/*
получение значений плотностей дл€ расчета объема —оломон
*/
DECLARE @case_id INT = {0};

-- дл€ сообщени€ об ошибке
DECLARE @err_msg NVARCHAR(MAX);

-- ќчистка обменной таблицы перед началом работы
TRUNCATE TABLE [ext].[GetDensity];

-- конечна€ дата периода
DECLARE @End_day DATETIME2 = (SELECT cs.Endtime FROM dbo.cases AS cs WHERE cs.id = @case_id);

IF @End_day IS NULL
BEGIN
    SET @err_msg = 'Ќе найден конечный день дл€ кейса с Id = ' + CAST(@case_id AS NVARCHAR(10));
    THROW 50000, @err_msg, 1;
END


-- ѕолучение списка тегов дл€ получени€ значени€ плотности
DECLARE @tag_ids NVARCHAR(MAX) = (
    SELECT STRING_AGG(ats.settings, ',') 
    FROM 
	    dbo.AttrSettings AS ats inner join Objects obj on ats.afElement=obj.SfId 
    WHERE 
		LOWER(ats.attribute) = LOWER(N'TagDensity') 
		and obj.SfName like 'F_%' 
		and nullif(trim(ats.settings) , '') IS NOT NULL    
		and ats.IsDeleted = 0
)

-- если переменна€ @tag_ids равна NULL, это значит, что нет тегов дл€ получени€ плотностей 
-- мы прекращаем выполнение скрипта
IF @tag_ids IS NULL
BEGIN
    SET @err_msg = 'Ќет тегов дл€ получени€ плотностей. ¬ыполнение скрипта прекращено.';
    THROW 50000, @err_msg, 1;
END

--  од ниже дл€ разделени€ строки списка тегов на подстроки меньше или равные 4000 символов
-- так как EncryptedGetLastTagValues в параметре @tagIDs принимает строку длиной не более 4000 символов 

DECLARE @max_length INT = 4000; -- максимальна€ длина строки с тегами как параметра дл€ хранимой процедуры
DECLARE @tag_ids_part NVARCHAR(4000); -- подстрока списка тегов, котора€ будет передаватьс€ в хранимую процедуру
DECLARE @start_pos INT = 1; -- начальна€ позици€ в строке с тегами
DECLARE @delimiter_pos INT; -- позици€ зап€той в строке с тегами
DECLARE @tag_ids_length INT = LEN(@tag_ids); -- длина строки со всеми тегами
DECLARE @delimiter CHAR(1) = ',';
 
PRINT 'ƒлина списка тегов: ' + CAST(@tag_ids_length AS NVARCHAR(10));

IF OBJECT_ID('tempdb..#TempTableDensity') IS NOT NULL
    DROP TABLE #TempTableDensity;

CREATE TABLE #TempTableDensity (
    [TagPath]        NVARCHAR(250),
    [TagValue]       FLOAT(53),
    [TagState]       INT,
    [TStampInMillis] BIGINT,
    [TStamp]         DATETIME
	
);

WHILE @start_pos <= @tag_ids_length
BEGIN
    SET @tag_ids_part = N''; 

    WHILE @start_pos <= @tag_ids_length
    BEGIN
        SET @delimiter_pos = CHARINDEX(@delimiter, @tag_ids, @start_pos);
        IF @delimiter_pos > 0
        BEGIN
            DECLARE @tag_length INT = @delimiter_pos - @start_pos + 1;
            IF @tag_length + LEN(@tag_ids_part) > @max_length
            BEGIN
                BREAK;
            END
            SET @tag_ids_part = @tag_ids_part + SUBSTRING(@tag_ids, @start_pos, @tag_length);
            SET @start_pos = @delimiter_pos + 1;
        END
        ELSE
        BEGIN
            IF @tag_ids_length - @start_pos + 1 + LEN(@tag_ids_part) > @max_length
            BEGIN
                -- слишком больша€ подстрока, будет переполнение параметра хранимой процедуры
                BREAK;
            END 
            ELSE 
            BEGIN
                SET @tag_ids_part = @tag_ids_part + SUBSTRING(@tag_ids, @start_pos, @tag_ids_length - @start_pos + 1);
                SET @start_pos = @tag_ids_length + 1; -- ”становить @start_pos на конец строки
            END
        END
    END

    IF LEN(@tag_ids_part) > 0
    BEGIN
        -- если @tag_ids_part в конце содержит @delimiter, то его надо удалить
        IF RIGHT(@tag_ids_part, 1) = @delimiter
        BEGIN
            SET @tag_ids_part = LEFT(@tag_ids_part, LEN(@tag_ids_part) - 1);
        END

        -- *debug*
        --PRINT 'ƒлина строки-параметра с тегами: ' + CAST(LEN(@tag_ids_part) AS NVARCHAR(10));
        --PRINT '—трока-параметр с  тегами: ' + LEFT(@tag_ids_part, 37) + ' ... ' + RIGHT(@tag_ids_part, 37);

		DELETE FROM #TempTableDensity;

		INSERT INTO #TempTableDensity
		EXEC [0.0.0.0].[DBNAME].[SCHEME].[FuncName]
			@tagPaths = @tag_ids_part,
			@periodEnd = @End_day;


		INSERT INTO [ext].[GetDensity] ([TagDensity],[DensityValue])
		SELECT 
			[TagPath] as [TagDensity], 
			ISNULL([TagValue], 0) AS DensityValue
		FROM #TempTableDensity;

    END
END
