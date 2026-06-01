USE [MB4]
GO
/****** Object:  UserDefinedFunction [dbo].[fn_GetTanksVarForOrderDiv]    Script Date: 28.05.2026 19:51:19 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER FUNCTION [dbo].[fn_GetTanksVarForOrderDiv](
    @caseId INT,
    @div NVARCHAR(255) = NULL,
    @secondDiv NVARCHAR(255) = NULL,
    @thirdDiv NVARCHAR(255) = NULL
)
    RETURNS @TempTable TABLE
                       (
                           Product1C         NVARCHAR(255),
                           shipmentDaily     INT,
                           Measured          FLOAT,
                           MeasuredPass      FLOAT,
                           MeasuredNotPass   FLOAT,
                           MeasuredNotIssued FLOAT,
                           DeadResidueMass   FLOAT,
                           FreeVolume        FLOAT
                       )
AS
BEGIN
    INSERT INTO @TempTable (Product1C, shipmentDaily, Measured, MeasuredPass, MeasuredNotPass, MeasuredNotIssued,
                            DeadResidueMass, FreeVolume)
    SELECT ot.Product1C,
           0 AS shipmentDaily,
           SUM(ot.Measured),
           SUM(ot.MeasuredPass),
           SUM(ot.MeasuredNotPass),
           SUM(ot.MeasuredNotIssued),
           SUM(ot.DeadResidueMass),
           SUM(ot.FreeVolume)
    FROM (
             SELECT DISTINCT obj3.SfName,
                             CASE
								WHEN obj3.SfName LIKE N'%Цех №8%'
									THEN N'Цех №8'

								WHEN obj3.SfName NOT LIKE N'%Цех №8%' AND pr.Name = 'Уловленный нефтепродукт'
									THEN N'ПКОН'

                                 WHEN pr.Name = N'ТОПЛИВО ДИЗЕЛЬНОЕ МЕЖСЕЗОННОЕ ДТ-Е-К4, сорт Е'
                                     THEN N'Компонент дизельного топлива'
                                 WHEN pr.Name = N'Пропан-пропиленовая фракция' THEN N'Компонент ПБТ'
                                 WHEN pr.Name = N'Бутан-бутиленовая фракция' THEN N'Компонент бутана'
                                 WHEN CHARINDEX(N'(УСТАРЕЛ 3.0)', pr.Name) > 0
                                     THEN TRIM(REPLACE(pr.Name, N'(УСТАРЕЛ 3.0)', ''))
                                 WHEN pn.Name IS NOT NULL THEN pn.Name
                                 ELSE pr.Name
                                 END                                                      AS Product1C,
                             tvCur.Measured,
                             IIF(pr.Name IN (N'Сера', N'КОКС'), 0,
                                 IIF(tvCur.PassportState = N'п', tvCur.MassWithoutDR, 0)) AS MeasuredPass,
                             IIF(pr.Name IN (N'Сера', N'КОКС'), tvCur.Measured,
                                 IIF(tvCur.PassportState <> N'п' OR tvCur.PassportState IS NULL, tvCur.MassWithoutDR,
                                     0))                                                  AS MeasuredNotPass,
                             IIF(obj3.SfName LIKE N'%TNOF%' AND pr.Name NOT IN (
                                         N'KMC-LUB', 
                                         N'KMC R-260 (ДДП)', 
                                         N'Присадка противоизносная DCI-4A', 
                                         N'Присадка Агидол-1 марка Б',
                                        N'Цетаноповышающая присадка к ДТ'
                                     ), tvCur.Measured, 0)           AS MeasuredNotIssued,
                             tvCur.DeadResidueMass,
                             tvCur.FreeVolume

             FROM LayersToObjects lo
                      INNER JOIN Objects obj ON lo.ObjectId = obj.Id
                      INNER JOIN TanksVar tvCur ON lo.ObjectId = tvCur.Id AND tvCur.CaseId = @caseId
                      INNER JOIN Objects obj3 ON obj3.Id = tvCur.Id AND obj3.IsDeleted = 0
                      INNER JOIN Cases cs ON tvCur.CaseId = cs.Id
                      INNER JOIN Objects obj2 ON lo.LayerId = obj2.Id
                      INNER JOIN Products pr ON tvCur.ProductId = pr.Id AND pr.IsDeleted = 0
                      INNER JOIN Analyses a ON a.SfId = cs.AnalysisSfId
                      LEFT JOIN [Reports_1C].[dbo].[ProductNames] pn ON pn.NameProduct = pr.Name

             WHERE obj.IsDeleted != 1
               AND (
                 pr.Name NOT LIKE N'%Сырье вторичной переработки%' AND
                 (
                     pr.Name NOT LIKE N'%Вода подтоварная%' OR
                     (@div = N'ПКОН' AND obj3.SfName LIKE N'%TNOF_Присадка%')
                     )
                 )
               AND (tvCur.NumberPark IS NOT NULL OR obj3.SfName LIKE N'%TNOF%')
               AND obj3.Name NOT LIKE N'%система%'
               AND pr.Name NOT LIKE N'Пустой'
               AND NOT (@div = N'ПКОН' AND pr.Name = N'Фр. 450-500 УПБ')
               AND (
                 ((
                      (@div IS NULL AND obj2.SfName = N'Завод') OR
                      (obj2.SfName = @div) OR
                      (@secondDiv IS NOT NULL AND obj2.SfName = @secondDiv) OR
                      (@thirdDiv IS NOT NULL AND obj2.SfName = @thirdDiv)
                      )
                     AND (
                      (pr.Name IN (N'сера', N'Гудрон УПБ', N'Цетаноповышающая присадка к ДТ') AND tvCur.Grouping LIKE '1%') OR
                      (pr.Name NOT IN (N'сера', N'Гудрон УПБ', N'Цетаноповышающая присадка к ДТ') AND tvCur.Grouping LIKE '2%') OR
                      tvCur.Grouping IS NULL OR
                      tvCur.Grouping = ''
                      )) OR (@div = N'ПКОН' AND (obj3.SfName LIKE N'%TNOF_Присадка%' OR obj3.SfName LIKE '%TNOF_KMC-LUB%' OR obj3.SfName LIKE '%TNOF%R-260%' OR obj3.SfName LIKE '%TNOF%Краситель%')))) AS ot
    GROUP BY ot.Product1C;

    WITH ProductsCTE AS (SELECT DISTINCT CASE
                                             WHEN pr.Name = N'ТОПЛИВО ДИЗЕЛЬНОЕ МЕЖСЕЗОННОЕ ДТ-Е-К4, сорт Е'
                                                 THEN N'Компонент дизельного топлива'
                                             WHEN CHARINDEX(N'(УСТАРЕЛ 3.0)', pr.Name) > 0
                                                 THEN LTRIM(RTRIM(REPLACE(pr.Name, N'(УСТАРЕЛ 3.0)', '')))
                                             WHEN pn.Name IS NOT NULL THEN pn.Name
                                             ELSE pr.Name
                                             END                      AS Product1C,
                                         SUM(DISTINCT tvCur.Measured) AS SumMeasured
                         FROM LayersToObjects lo
                                  INNER JOIN Objects obj ON lo.ObjectId = obj.Id
                                  INNER JOIN TanksVar tvCur ON lo.ObjectId = tvCur.Id AND tvCur.CaseId = @caseId
                                  INNER JOIN Objects obj3 ON obj3.Id = tvCur.Id AND obj3.IsDeleted = 0
                                  INNER JOIN Cases cs ON tvCur.CaseId = cs.Id
                                  INNER JOIN Objects obj2 ON lo.LayerId = obj2.Id
                                  INNER JOIN Products pr ON tvCur.ProductId = pr.Id AND pr.IsDeleted = 0
                                  INNER JOIN Analyses a ON a.SfId = cs.AnalysisSfId
                                  LEFT JOIN [Reports_1C].[dbo].[ProductNames] pn ON pn.NameProduct = pr.Name
                         WHERE obj.IsDeleted != 1
                           AND pr.Name NOT LIKE N'%Сырье вторичной переработки%'
                           AND pr.Name NOT LIKE N'%Вода подтоварная%'
                           AND pr.Name NOT LIKE N'%KMC-LUB%'
                           AND pr.Name NOT LIKE N'%R-260%'
                           AND pr.Name NOT LIKE N'%Краситель%'
                           AND (tvCur.NumberPark IS NOT NULL OR obj3.SfName LIKE N'%TNOF%')
                           AND (obj3.SfName LIKE N'%TNOF%')
                           AND @div <> N'ПППН'
                           AND obj3.SfName NOT LIKE N'%TNOF_Присадка%'
                           AND obj3.Name NOT LIKE N'%система%'
                           AND pr.Name NOT LIKE N'Пустой'
                           AND tvCur.Measured > 0
                           AND (
                             (pr.Name IN (N'сера', N'Гудрон УПБ', N'Цетаноповышающая присадка к ДТ') AND tvCur.Grouping LIKE '1%') OR
                             (pr.Name NOT IN (N'сера', N'Гудрон УПБ', N'Цетаноповышающая присадка к ДТ') AND tvCur.Grouping LIKE '2%') OR
                             tvCur.Grouping IS NULL OR
                             tvCur.Grouping = ''
                             )
                         GROUP BY CASE
                                      WHEN pr.Name = N'ТОПЛИВО ДИЗЕЛЬНОЕ МЕЖСЕЗОННОЕ ДТ-Е-К4, сорт Е'
                                          THEN N'Компонент дизельного топлива'
                                      WHEN CHARINDEX(N'(УСТАРЕЛ 3.0)', pr.Name) > 0
                                          THEN LTRIM(RTRIM(REPLACE(pr.Name, N'(УСТАРЕЛ 3.0)', '')))
                                      WHEN pn.Name IS NOT NULL THEN pn.Name
                                      ELSE pr.Name
                                      END)
    UPDATE t
    SET t.MeasuredNotIssued = pcte.SumMeasured,
        t.Measured          = t.Measured + pcte.SumMeasured
    FROM @TempTable t
             INNER JOIN ProductsCTE pcte ON pcte.Product1C = t.Product1C
    RETURN;
END