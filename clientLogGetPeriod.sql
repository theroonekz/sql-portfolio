USE [MB4]
GO
/****** Object:  StoredProcedure [dbo].[clientLogGetPeriod]    Script Date: 28.05.2026 19:24:26 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--	📅 Дата создания: 08.12.2025
--	👤 Автор скрипта: Габдуллин А. М.
--	📌 Назначение: Выгрузка изменении действий пользователей в АССМБ

ALTER PROCEDURE [dbo].[clientLogGetPeriod]
    @starttime DATETIME,
    @endtime DATETIME
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #SelectedCases (
        CaseId INT PRIMARY KEY,
        ModelSfId UNIQUEIDENTIFIER,
        StartTime DATETIME,
        EndTime DATETIME,
        IsCumulative INT
    )

    INSERT INTO #SelectedCases
    SELECT 
        C.Id, A.ModelSfId, C.StartTime, C.EndTime,
        CASE WHEN DAY(C.StartTime) = 1 AND DATEDIFF(day, C.StartTime, C.EndTime) > 1 THEN 1 ELSE 0 END
    FROM dbo.Cases C
    INNER JOIN dbo.Analyses A ON C.AnalysisSfId = A.SfId
    WHERE C.StartTime >= @starttime AND C.EndTime <= @endtime

    SELECT DISTINCT
    SC.CaseId,
    SC.IsCumulative,
    SC.StartTime,
    SC.EndTime,
    L.Id,
    L.Dt,
    L.ObjectId,
    L.UserId,
    L.HistoryType,
    L.AttributeName,
    L.AttributeSfName,
    CONVERT(NVARCHAR(MAX), L.PrevValue) AS PrevValue,
    CONVERT(NVARCHAR(MAX), L.NewValue) AS NewValue,
    L.IsCancelationAction
INTO #TotalLog
FROM #SelectedCases SC
CROSS APPLY dbo.fn_GetCaseLog(SC.ModelSfId, SC.CaseId) L

    CREATE INDEX IX_TotalLog_Search ON #TotalLog(ObjectId, CaseId, UserId)

    SELECT 
        CONVERT(NVARCHAR(10), SC.StartTime, 104) AS [Начало периода],
        CONVERT(NVARCHAR(10), SC.EndTime, 104) AS [Конец периода],
        CASE WHEN L.IsCumulative = 1 THEN 'Накопительный' ELSE 'Суточный' END AS [Тип периода],
        CONVERT(NVARCHAR(10), L.Dt, 104) + ' ' + CONVERT(NVARCHAR(8), L.Dt, 108) AS [Время действия],
        CASE 
            WHEN U.NAME IN ('Admin', 'Admin2', 'Admin3') THEN 'Сетин И.С.' 
            ELSE U.NAME 
        END AS [Пользователь],
        CASE 
            WHEN OT.[Name] = 'OtherType1' THEN 'Присадки' 
            ELSE OT.[Name] 
        END AS [Тип объекта],
        dbo.fn_GetName(L.ObjectId, L.CaseId) AS [Имя объекта],
        CASE L.HistoryType
            WHEN 0 THEN 'Создание'
            WHEN 1 THEN 'Удаление'
            WHEN 2 THEN 'Редактирование'
            WHEN 4 THEN 'Система'
            ELSE CAST(L.HistoryType AS NVARCHAR(10))
        END AS [Тип изменения],
        L.AttributeName AS [Атрибут],
        CASE
            WHEN (ISNUMERIC(L.PrevValue) = 1 AND L.AttributeSfName IN ('PrototypeId', 'SourceId', 'DestId'))
                THEN dbo.fn_GetName(CAST(L.PrevValue AS INT), L.CaseId)
            WHEN (ISNUMERIC(L.PrevValue) = 1 AND L.AttributeSfName IN ('ProductId', 'SecondProductId'))
                THEN (SELECT TOP 1 Name FROM dbo.fn_GetProductsInCase(L.CaseId) WHERE Id = CAST(L.PrevValue AS INT))
            ELSE L.PrevValue
        END AS [До],
        CASE
            WHEN (ISNUMERIC(L.NewValue) = 1 AND L.AttributeSfName IN ('PrototypeId', 'SourceId', 'DestId'))
                THEN dbo.fn_GetName(CAST(L.NewValue AS INT), L.CaseId)
            WHEN (ISNUMERIC(L.NewValue) = 1 AND L.AttributeSfName IN ('ProductId', 'SecondProductId'))
                THEN (SELECT TOP 1 Name FROM dbo.fn_GetProductsInCase(L.CaseId) WHERE Id = CAST(L.NewValue AS INT))
            ELSE L.NewValue
        END AS [После],
        CASE WHEN L.IsCancelationAction = 1 THEN 'Да' ELSE 'Нет' END AS [Отменено]
    FROM #TotalLog L
    INNER JOIN #SelectedCases SC ON L.CaseId = SC.CaseId
    LEFT JOIN Users U ON L.UserId = U.Id
    LEFT JOIN dbo.Objects O ON L.ObjectId = O.Id
    LEFT JOIN dbo.ObjectTypes OT ON O.ObjectTypeId = OT.Id
    WHERE OT.id <> 1024
    ORDER BY 
        SC.StartTime DESC, 
        L.IsCumulative ASC, 
        L.Dt DESC

    DROP TABLE #SelectedCases
    DROP TABLE #TotalLog
END