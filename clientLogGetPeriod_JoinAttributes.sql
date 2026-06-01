USE [MB4]
GO
/****** Object:  StoredProcedure [dbo].[clientLogGetPeriod_JoinAttributes]    Script Date: 28.05.2026 19:25:07 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--	📅 Дата создания: 15.03.2026
--	👤 Автор скрипта: Габдуллин А. М.
--	📌 Назначение: Выгрузка изменении действий пользователей в АССМБ. Используется в Web-сервисе на APP2

ALTER PROCEDURE [dbo].[clientLogGetPeriod_JoinAttributes]
    @starttime      DATETIME,
    @endtime        DATETIME,
    @OnlySearchDate BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        C.Id AS CaseId,
        A.ModelSfId,
        C.StartTime,
        C.EndTime,
        CASE 
            WHEN A.SfId = 'AAF1C8C0-F71C-4303-8ECD-2EE245E8B0DE' THEN 1 
            ELSE 0 
        END AS IsCumulative
    INTO #SelectedCases
    FROM dbo.Cases C
    INNER JOIN dbo.Analyses A ON C.AnalysisSfId = A.SfId
    WHERE
        CASE
            WHEN @OnlySearchDate = 1 THEN
                CASE WHEN C.StartTime = @starttime AND C.EndTime = @endtime THEN 1 ELSE 0 END
            ELSE
                CASE WHEN C.StartTime >= @starttime AND C.EndTime <= @endtime THEN 1 ELSE 0 END
        END = 1

    SELECT 
        SC.CaseId, SC.IsCumulative, L.Id, L.ObjectId, L.UserId, L.Dt,
        L.HistoryType, L.AttributeName, L.AttributeSfName,
        CONVERT(NVARCHAR(MAX), L.PrevValue) as PrevValue, 
        CONVERT(NVARCHAR(MAX), L.NewValue) as NewValue,
        L.IsCancelationAction,
        CONVERT(DATETIME, CONVERT(NVARCHAR(19), L.Dt, 120), 120) AS DtSec
    INTO #TotalLog
    FROM #SelectedCases SC
    CROSS APPLY dbo.fn_GetCaseLog(SC.ModelSfId, SC.CaseId) L;

    CREATE CLUSTERED INDEX IX_TempLog ON #TotalLog (DtSec, ObjectId, UserId);
    ALTER TABLE #TotalLog ADD RowKey INT IDENTITY(1,1);

    ;WITH Deduped AS (
        SELECT 
            TL.RowKey,
            ROW_NUMBER() OVER (
                PARTITION BY TL.Id
                ORDER BY 
                    CASE WHEN O.ObjectTypeId = 1024 THEN 1 ELSE 0 END ASC,
                    CASE WHEN O.ObjectTypeId IS NULL THEN 1 ELSE 0 END ASC,
                    TL.CaseId DESC
            ) AS rn
        FROM #TotalLog TL
        LEFT JOIN dbo.Objects O ON TL.ObjectId = O.Id
    )
    DELETE FROM #TotalLog WHERE RowKey IN (SELECT RowKey FROM Deduped WHERE rn > 1);

    SELECT 
        L.*,
        CASE WHEN U.NAME IN ('Admin', 'Admin2', 'Admin3') THEN 'Иванов И.И.' ELSE U.NAME END AS UserName,
        CASE WHEN OT.[Name] = 'OtherType1' THEN 'Присадки' ELSE OT.[Name] END AS ObjectType,
        dbo.fn_GetName(L.ObjectId, L.CaseId) AS ObjectName,
        CASE
            WHEN (ISNUMERIC(L.PrevValue) = 1 AND L.AttributeSfName IN ('PrototypeId', 'SourceId', 'DestId'))
                THEN dbo.fn_GetName(CAST(L.PrevValue AS INT), L.CaseId)
            WHEN (ISNUMERIC(L.PrevValue) = 1 AND L.AttributeSfName IN ('ProductId', 'SecondProductId'))
                THEN (SELECT TOP 1 Name FROM dbo.fn_GetProductsInCase(L.CaseId) WHERE Id = CAST(L.PrevValue AS INT))
            ELSE L.PrevValue
        END AS FormattedPrevValue,
        CASE
            WHEN (ISNUMERIC(L.NewValue) = 1 AND L.AttributeSfName IN ('PrototypeId', 'SourceId', 'DestId'))
                THEN dbo.fn_GetName(CAST(L.NewValue AS INT), L.CaseId)
            WHEN (ISNUMERIC(L.NewValue) = 1 AND L.AttributeSfName IN ('ProductId', 'SecondProductId'))
                THEN (SELECT TOP 1 Name FROM dbo.fn_GetProductsInCase(L.CaseId) WHERE Id = CAST(L.NewValue AS INT))
            ELSE L.NewValue
        END AS FormattedNewValue
    INTO #PreFormatted
    FROM #TotalLog L
    LEFT JOIN Users U ON L.UserId = U.Id
    LEFT JOIN dbo.Objects O ON L.ObjectId = O.Id
    LEFT JOIN dbo.ObjectTypes OT ON O.ObjectTypeId = OT.Id
    WHERE OT.id <> 1024

    SELECT 
        FinalResult.[LogId],
        FinalResult.[Начало периода], FinalResult.[Конец периода], FinalResult.[Тип периода], FinalResult.[Время действия], 
        FinalResult.[Пользователь],

        CASE
            WHEN Obj.ObjNameLeft LIKE '%НОФ %' THEN 'НОФ'
            WHEN (Obj.ObjNameLeft LIKE '%Склад%' AND Obj.ObjNameLeft NOT LIKE '%Склад серы%') 
                 OR Obj.ObjNameLeft LIKE '%Присадки%' 
                 OR Obj.ObjNameLeft LIKE '%Краситель%' THEN 'Присадки'
            WHEN Obj.ObjNameLeft LIKE '%Система%' THEN 'Система'
            ELSE FinalResult.[Тип объекта]
        END AS [Тип объекта],
        FinalResult.[Имя объекта], FinalResult.[Тип изменения], FinalResult.[Атрибут], FinalResult.[До], FinalResult.[После], FinalResult.[Отменено],
        ISNULL(lc.Comment, '') AS [Комментарий],
        ISNULL(sc.Sign, '') AS [Признак]
    FROM (

        SELECT 
            MIN(PF.Id) AS [LogId],
            CONVERT(NVARCHAR(10), SC.StartTime, 104) AS [Начало периода],
            CONVERT(NVARCHAR(10), SC.EndTime, 104) AS [Конец периода],
            CASE WHEN PF.IsCumulative = 1 THEN 'Накопительный' ELSE 'Суточный' END AS [Тип периода],
            CONVERT(NVARCHAR(10), PF.DtSec, 104) + ' ' + CONVERT(NVARCHAR(8), PF.DtSec, 108) AS [Время действия],
            PF.UserName AS [Пользователь],
            PF.ObjectType AS [Тип объекта],
            PF.ObjectName AS [Имя объекта],
            'Создание' AS [Тип изменения],
            STUFF((
                SELECT ', ' + t.AttributeName + '=' + ISNULL(t.FormattedNewValue, 'NULL')
                FROM #PreFormatted t
                WHERE t.DtSec = PF.DtSec AND t.ObjectId = PF.ObjectId 
                  AND t.UserId = PF.UserId AND t.HistoryType = 0
                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS [Атрибут],
            NULL AS [До], NULL AS [После],
            CASE WHEN PF.IsCancelationAction = 1 THEN 'Да' ELSE 'Нет' END AS [Отменено],
            PF.DtSec AS RawDt, PF.IsCumulative AS RawIsCum, SC.StartTime as RawStart
        FROM #PreFormatted PF
        INNER JOIN #SelectedCases SC ON PF.CaseId = SC.CaseId
        WHERE PF.HistoryType = 0
        GROUP BY SC.StartTime, SC.EndTime, PF.IsCumulative, PF.DtSec, PF.UserName, 
                 PF.ObjectType, PF.ObjectName, PF.IsCancelationAction, PF.ObjectId, PF.UserId

        UNION ALL

        SELECT 
            MIN(PF.Id) AS [LogId],
            CONVERT(NVARCHAR(10), SC.StartTime, 104),
            CONVERT(NVARCHAR(10), SC.EndTime, 104),
            CASE WHEN PF.IsCumulative = 1 THEN 'Накопительный' ELSE 'Суточный' END,
            CONVERT(NVARCHAR(10), PF.DtSec, 104) + ' ' + CONVERT(NVARCHAR(8), PF.DtSec, 108),
            PF.UserName, PF.ObjectType,
            'Зависимость потерь: ' + STUFF((
                SELECT ', ' + REPLACE(t.ObjectName, 'Зависимость потерь ', '')
                FROM #PreFormatted t
                WHERE t.DtSec = PF.DtSec AND t.UserId = PF.UserId 
                  AND t.AttributeName = 'Состояние зависимости' AND t.HistoryType = 4
                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''),
            'Система', 'Состояние зависимости',
            MAX(PF.PrevValue), MAX(PF.NewValue),
            CASE WHEN PF.IsCancelationAction = 1 THEN 'Да' ELSE 'Нет' END,
            PF.DtSec, PF.IsCumulative, SC.StartTime
        FROM #PreFormatted PF
        INNER JOIN #SelectedCases SC ON PF.CaseId = SC.CaseId
        WHERE PF.AttributeName = 'Состояние зависимости' AND PF.HistoryType = 4
        GROUP BY SC.StartTime, SC.EndTime, PF.IsCumulative, PF.DtSec, PF.UserName, 
                 PF.ObjectType, PF.IsCancelationAction, PF.UserId

        UNION ALL

        SELECT 
            PF.Id AS [LogId],
            CONVERT(NVARCHAR(10), SC.StartTime, 104),
            CONVERT(NVARCHAR(10), SC.EndTime, 104),
            CASE WHEN PF.IsCumulative = 1 THEN 'Накопительный' ELSE 'Суточный' END,
            CONVERT(NVARCHAR(10), PF.Dt, 104) + ' ' + CONVERT(NVARCHAR(8), PF.Dt, 108),
            PF.UserName, PF.ObjectType, PF.ObjectName,
            CASE PF.HistoryType WHEN 1 THEN 'Удаление' WHEN 2 THEN 'Редактирование' ELSE 'Инфо' END,
            PF.AttributeName,
            PF.FormattedPrevValue, PF.FormattedNewValue,
            CASE WHEN PF.IsCancelationAction = 1 THEN 'Да' ELSE 'Нет' END,
            PF.Dt, PF.IsCumulative, SC.StartTime
        FROM #PreFormatted PF
        INNER JOIN #SelectedCases SC ON PF.CaseId = SC.CaseId
        WHERE PF.HistoryType NOT IN (0) 
          AND NOT (PF.AttributeName = 'Состояние зависимости' AND PF.HistoryType = 4)
    ) AS FinalResult

    CROSS APPLY (
        SELECT CASE 
            WHEN CHARINDEX(' -> ', FinalResult.[Имя объекта]) > 0 
            THEN LTRIM(RTRIM(LEFT(FinalResult.[Имя объекта], CHARINDEX(' -> ', FinalResult.[Имя объекта]) - 1)))
            ELSE FinalResult.[Имя объекта] 
        END AS ObjNameLeft
    ) AS Obj
    LEFT JOIN (
        SELECT lc1.* FROM [TestReport].dbo.LogComments lc1
        INNER JOIN (SELECT LogId, MAX(Id) AS MaxId FROM [TestReport].dbo.LogComments GROUP BY LogId) lc2 
        ON lc1.LogId = lc2.LogId AND lc1.Id = lc2.MaxId
    ) lc ON lc.LogId = FinalResult.[LogId]
    LEFT JOIN (
        SELECT sc1.* FROM [TestReport].dbo.SignComments sc1
        INNER JOIN (SELECT LogId, MAX(Id) AS MaxId FROM [TestReport].dbo.SignComments GROUP BY LogId) sc2 
        ON sc1.LogId = sc2.LogId AND sc1.Id = sc2.MaxId
    ) sc ON sc.LogId = FinalResult.[LogId]
    ORDER BY 
        RawStart DESC,
        RawIsCum ASC,
        RawDt DESC

    DROP TABLE #SelectedCases; DROP TABLE #TotalLog; DROP TABLE #PreFormatted;
END