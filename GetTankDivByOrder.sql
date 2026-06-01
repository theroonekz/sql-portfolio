USE [MB4]
GO
/****** Object:  StoredProcedure [dbo].[GetTankDivByOrder] ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/*
    -- GetTankDivByOrder - процедура, позволяющая получить:
    -- 1 Производство с начала месяца
    -- 2 Производство за сутки
    -- 3 Отгрузка с начало месяца
    -- 4 Отгрузка за сутки
    -- 5 Остаток за сутки, а так же вычисление производства
    -- 6 Остатки в разных состояниях: Неоформленные, паспортизированные, компоненты, мертвые остатки
    -- 7 Свободные объемы.
    -- 8 Остаток на начало месяца
    -- Процедура позволяет получить данные как по заводу (не передавать @div) или получить по подразделениям

    -- 1. Первым этапом создаем временные таблицы, переменные
    -- 2. Вставляем данные присадок во временные таблицы
    -- 3. Вставляем остатки во временные таблицы
    -- 4. Вставляем отгрузку во временные таблицы
    -- 5. Вставляем данные присадок.
    -- 6. Группируем данные
    -- 7. Сортируем данные

    -- Measured 
*/
ALTER PROCEDURE [dbo].[GetTankDivByOrder] @caseId INT,
                                           @div NVARCHAR(50) = NULL, -- Делаем @div необязательным
                                           @secondDiv NVARCHAR(50) = NULL,
                                           @thirdDiv NVARCHAR(50) = NULL
AS
BEGIN

    SET NOCOUNT ON;
    DECLARE @CaseIds CaseIdTable;
    DECLARE @CaseIdOnly CaseIdTable;

    DECLARE @startMonthsCaseId CaseIdTable;
    DECLARE @prevCaseIdTable CaseIdTable;
    DECLARE @MonthsDiff INT;
    DECLARE @PrevCaseId INT;

    -- @MonthCaseIds: все суточные периоды текущего месяца от 1-го числа до текущего включительно.
    -- Суточный период = AnalysisSfId = 'YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY'.
    -- Принадлежность месяцу определяется по StartTime (а не EndTime), чтобы период вида
    -- 29.04 - 01.05 корректно считался апрельским.
    -- Используется для накопительного расчёта присадок (смешение) через OtherTable1.
    DECLARE @MonthCaseIds CaseIdTable;

    SELECT @MonthsDiff =
           CASE
               WHEN c.AnalysisSfId = 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX'
                   THEN 1 -- true
               ELSE 0 -- false
               END
    FROM Cases AS c
    WHERE c.Id = @caseId;

    insert into @CaseIdOnly
    values (@caseId)

    -- Заполняем @MonthCaseIds: суточные периоды с 1-го числа месяца текущего кейса
    -- до EndTime текущего кейса включительно.
    -- Принадлежность к месяцу — по StartTime кейса (не EndTime).
    INSERT INTO @MonthCaseIds (ID)
    SELECT c.Id
    FROM Cases c
    INNER JOIN Analyses a ON a.SfId = c.AnalysisSfId
    WHERE a.Name = N'Суточный'                                          -- только суточные периоды
      AND YEAR(c.StartTime)  = YEAR((SELECT StartTime FROM Cases WHERE Id = @caseId))
      AND MONTH(c.StartTime) = MONTH((SELECT StartTime FROM Cases WHERE Id = @caseId))
      AND c.EndTime <= (SELECT EndTime FROM Cases WHERE Id = @caseId);  -- не позже конца текущего периода

    IF @MonthsDiff = 1
        BEGIN
            -- Кейc «месячный» — добавляем его же
            INSERT INTO @CaseIds
            VALUES (@caseId);

            SELECT TOP 1 @PrevCaseId = PrevCaseId
            FROM GetEarliestCase(@caseId)
            ORDER BY EarliestCaseId;

        END
    ELSE
        BEGIN
            -- Кейc не «месячный» — добавляем результат GetEarliestCase
            INSERT INTO @CaseIds
            SELECT EarliestCaseId
            FROM GetEarliestCase(@caseId);

            SELECT TOP 1 @PrevCaseId = PrevCaseId
            FROM Cases
            WHERE id = @caseId;
        END

    INSERT INTO @prevCaseIdTable VALUES (@PrevCaseId)
    INSERT INTO @startMonthsCaseId
    SELECT TOP 1 PrevCaseId
    FROM GetEarliestCase(@caseId)
    ORDER BY EarliestCaseId

    DROP TABLE IF EXISTS #TempFilteredData
    DROP TABLE IF EXISTS #PetrolComponentsDaily
    DROP TABLE IF EXISTS #PetrolComponentsMonth
    DROP TABLE IF EXISTS #AdditivesDaily
    DROP TABLE IF EXISTS #AdditivesStart

    CREATE TABLE #TempFilteredData
    (
        Product1C          NVARCHAR(255),
        GroupName          NVARCHAR(255)  DEFAULT '',
        shipmentDaily      DECIMAL(18, 3) DEFAULT 0.000,
        shipmentMonth      DECIMAL(18, 3) DEFAULT 0.000,
        Measured           DECIMAL(18, 3) DEFAULT 0.000,
        MeasuredOld        DECIMAL(18, 3) DEFAULT 0.000,
        MeasuredNotIssued  DECIMAL(18, 3) DEFAULT 0.000,
        MeasuredStart      DECIMAL(18, 3) DEFAULT 0.000,
        MeasuredPass       DECIMAL(18, 3) DEFAULT 0.000,
        MeasuredNotPass    DECIMAL(18, 3) DEFAULT 0.000,
        StartMonthMeasured DECIMAL(18, 3) DEFAULT 0.000,
        DailyMeasured      DECIMAL(18, 3) DEFAULT 0.000,
        DeadResidueMass    DECIMAL(18, 3) DEFAULT 0.000,
        FreeVolume         DECIMAL(18, 3) DEFAULT 0.000
    );

    -- Создание временной таблицы #PetrolComponentsDaily
    CREATE TABLE #PetrolComponentsDaily
    (
        ProdName   NVARCHAR(255),
        Reconciled FLOAT,
        Measured   FLOAT
    );

    -- Создание временной таблицы #PetrolComponentsMonth
    CREATE TABLE #PetrolComponentsMonth
    (
        ProdName   NVARCHAR(255),
        Reconciled DECIMAL(18, 3),
        Measured   DECIMAL(18, 3)
    );

    CREATE TABLE #AdditivesDaily
    (
        Name     NVARCHAR(255),
        Measured DECIMAL(18, 3),
    )

    CREATE TABLE #AdditivesStart
    (
        Name     NVARCHAR(255),
        Measured DECIMAL(18, 3),
    )

    INSERT INTO #AdditivesDaily (Name, Measured)
    SELECT Name, EndMass as Measured
    FROM OtherTable1
    WHERE caseId = @caseId

    INSERT INTO #AdditivesStart (Name, Measured)
    SELECT Name, EndMass as Measured
    FROM OtherTable1
    WHERE caseId = (SELECT TOP 1 PrevCaseId
                    FROM GetEarliestCase(@caseId)
                    ORDER BY EarliestCaseId)

    -- Вставка данных для присадок. Дневные
    INSERT INTO #PetrolComponentsDaily (ProdName, Measured, Reconciled)
    SELECT Name as ProdName, Measured, Reconciled
    FROM fn_arrivalOfAdditives(@CaseIdOnly)

    -- Вставка данных для присадок. Месячные
    INSERT INTO #PetrolComponentsMonth (ProdName, Measured, Reconciled)
    SELECT Name as ProdName, Measured, Reconciled
    FROM fn_arrivalOfAdditives(@CaseIds)

    IF @div IS NOT NULL
        BEGIN
            INSERT INTO #TempFilteredData (Product1C, Measured, MeasuredPass, MeasuredNotPass, MeasuredNotIssued,
                                           DeadResidueMass,
                                           FreeVolume)
            SELECT Product1C, Measured, MeasuredPass, MeasuredNotPass, MeasuredNotIssued, DeadResidueMass, FreeVolume
            FROM fn_GetTanksVarForOrderDiv(@caseId, @div, @secondDiv, @thirdDiv)

            UPDATE #TempFilteredData
            SET MeasuredOld   = COALESCE(tv.Measured, 0),
                DailyMeasured = COALESCE(tmp.Measured, 0) - COALESCE(tv.Measured, 0)
            FROM #TempFilteredData tmp
                     LEFT JOIN fn_GetTanksVarForOrderDiv(@PrevCaseId, @div, @secondDiv,
                                                         @thirdDiv) tv
                               ON tv.Product1C = tmp.Product1C

            UPDATE #TempFilteredData
            SET MeasuredStart      = COALESCE(tv.Measured, 0),
                StartMonthMeasured = COALESCE(tmp.Measured, 0) - COALESCE(tv.Measured, 0)
            FROM #TempFilteredData tmp
                     LEFT JOIN fn_GetTanksVarForOrderDiv((SELECT TOP 1 PrevCaseId
                                                          FROM GetEarliestCase(@caseId)
                                                          ORDER BY EarliestCaseId), @div, @secondDiv, @thirdDiv) tv
                               ON tv.Product1C = tmp.Product1C

        END
    ELSE
        BEGIN
            INSERT INTO #TempFilteredData (Product1C, Measured, MeasuredPass, MeasuredNotPass, MeasuredNotIssued,
                                           DeadResidueMass,
                                           FreeVolume)
            SELECT Product1C, Measured, MeasuredPass, MeasuredNotPass, MeasuredNotIssued, DeadResidueMass, FreeVolume
            FROM fn_GetTanksVarForOrder(@caseId, @div, @secondDiv, @thirdDiv)

            UPDATE #TempFilteredData
            SET MeasuredOld   = COALESCE(tv.Measured, 0),
                DailyMeasured = COALESCE(tmp.Measured, 0) - COALESCE(tv.Measured, 0)
            FROM #TempFilteredData tmp
                     LEFT JOIN fn_GetTanksVarForOrder(@PrevCaseId, @div, @secondDiv,
                                                      @thirdDiv) tv
                               ON tv.Product1C = tmp.Product1C

            UPDATE #TempFilteredData
            SET MeasuredStart      = COALESCE(tv.Measured, 0),
                StartMonthMeasured = COALESCE(tmp.Measured, 0) - COALESCE(tv.Measured, 0)
            FROM #TempFilteredData tmp
                     LEFT JOIN fn_GetTanksVarForOrder((SELECT TOP 1 PrevCaseId
                                                       FROM GetEarliestCase(@caseId)
                                                       ORDER BY EarliestCaseId), @div, @secondDiv, @thirdDiv) tv
                               ON tv.Product1C = tmp.Product1C

            INSERT INTO #TempFilteredData (Product1C, MeasuredStart, StartMonthMeasured)
            SELECT tv.Product1C,
                   COALESCE(tv.Measured, 0)     AS MeasuredStart,
                   0 - COALESCE(tv.Measured, 0) AS StartMonthMeasured
            FROM fn_GetTanksVarForOrder(
                         (SELECT TOP 1 PrevCaseId FROM GetEarliestCase(@caseId) ORDER BY EarliestCaseId),
                         @div, @secondDiv, @thirdDiv
                 ) tv
            WHERE NOT EXISTS (SELECT 1
                              FROM #TempFilteredData tmp
                              WHERE tmp.Product1C = tv.Product1C);

        END

    -- Отгрузка за день
    MERGE INTO #TempFilteredData AS target
    USING (SELECT SUM(Reconciled) as Reconciled, ProductName
           FROM fn_summary_GetShipment(@CaseIdOnly) AS source
           WHERE @div IS NULL
              OR source.div = @div
           GROUP BY ProductName) AS source
    ON target.Product1C = source.ProductName
    WHEN MATCHED THEN
        UPDATE
        SET target.shipmentDaily = COALESCE(source.Reconciled, 0),
            target.DailyMeasured = target.Measured + COALESCE(source.Reconciled, 0) - target.MeasuredOld
    WHEN NOT MATCHED THEN
        INSERT (Product1C, shipmentDaily, DailyMeasured)
        VALUES (source.ProductName, COALESCE(source.Reconciled, 0), source.Reconciled);

-- Отгрузка за месяц
    MERGE INTO #TempFilteredData AS target
    USING (SELECT SUM(Reconciled) as Reconciled, ProductName
           FROM fn_summary_GetShipment(@CaseIds) AS source
           WHERE @div IS NULL
              OR source.div = @div
           GROUP BY ProductName) AS source
    ON target.Product1C = source.ProductName
    WHEN MATCHED THEN
        UPDATE
        SET target.shipmentMonth      = COALESCE(source.Reconciled, 0),
            target.StartMonthMeasured = target.Measured + COALESCE(source.Reconciled, 0) - target.MeasuredStart
    WHEN NOT MATCHED THEN
        INSERT (Product1C, shipmentMonth, StartMonthMeasured)
        VALUES (source.ProductName, COALESCE(source.Reconciled, 0), source.Reconciled);

    -- Поставка нефти
    UPDATE #TempFilteredData
    SET DailyMeasured      = dbo.fn_summary_GetOilSupply(@CaseIdOnly),
        StartMonthMeasured = dbo.fn_summary_GetOilSupply(@CaseIds)
    WHERE Product1C = N'Нефть';

    -- Заполняем присадки
    IF @div IS NULL OR @div = N'Подразделение №1'
        BEGIN

            INSERT INTO #TempFilteredData (Product1C, Measured)
            SELECT SfName, Reconciled
            FROM fn_getTankDivByOrderSystem(@CaseIdOnly)

            UPDATE #TempFilteredData
            SET MeasuredOld   = COALESCE(tv.Reconciled, 0),
                DailyMeasured = COALESCE(tmp.Measured, 0) - COALESCE(tv.Reconciled, 0)
            FROM #TempFilteredData tmp
                     LEFT JOIN fn_getTankDivByOrderSystem(@prevCaseIdTable) tv
                               ON tv.SfName = tmp.Product1C

            WHERE tv.SfName IS NOT NULL

            UPDATE #TempFilteredData
            SET MeasuredStart      = COALESCE(tv.Reconciled, 0),
                StartMonthMeasured = COALESCE(tmp.Measured, 0) - COALESCE(tv.Reconciled, 0)
            FROM #TempFilteredData tmp
                     LEFT JOIN fn_getTankDivByOrderSystem(@startMonthsCaseId) tv
                               ON tv.SfName = tmp.Product1C
            WHERE tv.SfName IS NOT NULL

            -- Переработка нефти
            IF @MonthsDiff = 1
                BEGIN
                    INSERT #TempFilteredData (Product1C, StartMonthMeasured, DailyMeasured)
                    VALUES (N'Переработка нефти',
                            dbo.fn_summary_GetOilInProductionMonth(@CaseIds),
                            dbo.fn_summary_GetOilInProductionMonth(@CaseIdOnly));
                END
            ELSE
                BEGIN
                    INSERT #TempFilteredData (Product1C, StartMonthMeasured, DailyMeasured)
                    VALUES (N'Переработка нефти',
                            dbo.fn_summary_GetOilInProduction(@CaseIds),
                            dbo.fn_summary_GetOilInProduction(@CaseIdOnly));
                END

            --             UPDATE #TempFilteredData
--             SET shipmentDaily      = dbo.fn_summary_getMeasuredMeterVar(11766, @CaseIdOnly),
--
--                 DailyMeasured      =
--                     COALESCE(temp.DailyMeasured, 0) + dbo.fn_summary_getMeasuredMeterVar(11766, @CaseIdOnly),
--
--                 shipmentMonth      = dbo.fn_summary_getMeasuredMeterVar(11766, @CaseIds),
--
--                 StartMonthMeasured =
--                     COALESCE(temp.StartMonthMeasured, 0) + dbo.fn_summary_getMeasuredMeterVar(11766, @CaseIds)
--             FROM #TempFilteredData temp
--             WHERE temp.Product1C = N'Пропан-пропиленовая фракция'

--             UPDATE #TempFilteredData
--             SET shipmentDaily      = dbo.fn_summary_getMeasuredMeterVar(11761, @CaseIdOnly),
--                 DailyMeasured      =
--                     COALESCE(temp.DailyMeasured, 0) + dbo.fn_summary_getMeasuredMeterVar(11761, @CaseIdOnly),
--
--                 shipmentMonth      = dbo.fn_summary_getMeasuredMeterVar(11761, @CaseIds),
--
--                 StartMonthMeasured =
--                     COALESCE(temp.StartMonthMeasured, 0) + dbo.fn_summary_getMeasuredMeterVar(11761, @CaseIds)
--             FROM #TempFilteredData temp
--             WHERE temp.Product1C = N'Бутан-бутиленовая фракция'

            UPDATE #TempFilteredData
            SET shipmentMonth      = shipmentMonth + dbo.fn_summary_getMeasuredMeterVar(11766, @CaseIds),
                shipmentDaily      = shipmentDaily + dbo.fn_summary_getMeasuredMeterVar(11766, @CaseIdOnly),
                StartMonthMeasured = StartMonthMeasured + dbo.fn_summary_getMeasuredMeterVar(11766, @CaseIds),
                DailyMeasured      = DailyMeasured + dbo.fn_summary_getMeasuredMeterVar(11766, @CaseIdOnly)
            WHERE Product1C = N'Компонент ПБТ'

            UPDATE #TempFilteredData
            SET shipmentMonth      = shipmentMonth + dbo.fn_summary_getMeasuredMeterVar(11761, @CaseIds),
                shipmentDaily      = shipmentDaily + dbo.fn_summary_getMeasuredMeterVar(11761, @CaseIdOnly),
                StartMonthMeasured = StartMonthMeasured + dbo.fn_summary_getMeasuredMeterVar(11761, @CaseIds),
                DailyMeasured      = DailyMeasured + dbo.fn_summary_getMeasuredMeterVar(11761, @CaseIdOnly)
            WHERE Product1C = N'Компонент бутана'

                        -- Продукт №12
            INSERT #TempFilteredData (Product1C, DailyMeasured, StartMonthMeasured)
            SELECT N'Продукт №12 (смешение)',
                   (select SUM(fv.Reconciled) as Reconciled
                    from Flows fl
                             inner join Objects fl_obj on fl_obj.id = fl.id and fl_obj.IsDeleted = 0
                             inner join Products pr on fl.ProductId = pr.id and pr.IsDeleted = 0
                             inner join Products pr2 on fl.SecondProductId = pr2.id and pr2.IsDeleted = 0
                             inner join Objects src on src.Id = fl.SourceId and src.IsDeleted = 0
                             inner join Objects dst on dst.Id = fl.DestId and dst.IsDeleted = 0
                             inner join ObjectTypes ot1 on src.ObjectTypeId = ot1.Id
                             inner join ObjectTypes ot2 on dst.ObjectTypeId = ot2.Id
                             inner join Links l on l.FlowId = fl.Id
                             inner join Objects l_obj on l_obj.Id = l.Id and l_obj.IsDeleted = 0
                             INNER JOIN FlowsVar fv ON fv.id = fl.id AND fv.CaseId = @caseId
                    where src.SfName LIKE N'%Объект №1%'
                      AND pr.Name LIKE N'%Компонент бутана%'),
                   (select SUM(fv.Reconciled) as Reconciled
                    from Flows fl
                             inner join Objects fl_obj on fl_obj.id = fl.id and fl_obj.IsDeleted = 0
                             inner join Products pr on fl.ProductId = pr.id and pr.IsDeleted = 0
                             inner join Products pr2 on fl.SecondProductId = pr2.id and pr2.IsDeleted = 0
                             inner join Objects src on src.Id = fl.SourceId and src.IsDeleted = 0
                             inner join Objects dst on dst.Id = fl.DestId and dst.IsDeleted = 0
                             inner join ObjectTypes ot1 on src.ObjectTypeId = ot1.Id
                             inner join ObjectTypes ot2 on dst.ObjectTypeId = ot2.Id
                             inner join Links l on l.FlowId = fl.Id
                             inner join Objects l_obj on l_obj.Id = l.Id and l_obj.IsDeleted = 0
                             INNER JOIN FlowsVar fv ON fv.id = fl.id AND fv.CaseId IN (SELECT ID FROM @CaseIds)
                    where src.SfName LIKE N'%Объект №1%'
                      AND pr.Name LIKE N'%Компонент бутана%')

-- Продукт №10 (смешение)
            INSERT #TempFilteredData (Product1C, DailyMeasured, StartMonthMeasured, shipmentDaily, Measured,
                                      MeasuredStart)
            SELECT N'Продукт №10 (смешение)'                           as Product1C,
                   ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                       COALESCE(temp.Measured, 0))                  as DailyMeasured,
                   ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                       COALESCE(temp.Measured, 0))                          as StartMonthMeasured,
                   OtherTable.MeasuredMassDay,
                   OtherTable.EndMass,
                   (SELECT SUM(Measured) as Measured
                    FROM #AdditivesStart
                    WHERE Name LIKE N'%Продукт №10%') as MeasuredStart
            FROM #TempFilteredData temp
                     LEFT JOIN
                 (SELECT N'Продукт №10'    as Name,
                         SUM(ComingMix)         As ComingMix,
                         SUM(MeasuredMassDay)   as MeasuredMassDay,
                         SUM(MeasuredMassAccum) as MeasuredMassAccum,
                         SUM(EndMass)           as EndMass
                  FROM OtherTable1
                  WHERE CaseId = @caseId
                    AND Name LIKE N'%Продукт №10%') AS OtherTable
                 ON OtherTable.Name = temp.Product1C

                     LEFT JOIN #PetrolComponentsDaily daily
                               ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №10';

            UPDATE #TempFilteredData
            SET shipmentMonth = (MeasuredStart + StartMonthMeasured - Measured)
            WHERE Product1C = N'Продукт №10 (смешение)'

            UPDATE #TempFilteredData
            SET DailyMeasured      = daily.Measured,
                StartMonthMeasured = PCM.Measured,
                shipmentDaily      = ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                                         COALESCE(temp.Measured, 0)),
                shipmentMonth      = ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                                         COALESCE(temp.Measured, 0))
            FROM #TempFilteredData temp
                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №10'

            -- Продукт №11
            INSERT #TempFilteredData (Product1C, DailyMeasured, StartMonthMeasured, shipmentDaily,
                                      Measured, MeasuredStart)
            SELECT N'Продукт №11 (смешение)'      as Product1C,
               --    ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) - COALESCE(temp.Measured, 0))      
                   OtherTable.ComingMix as DailyMeasured,
                   ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                       COALESCE(temp.Measured, 0))      as StartMonthMeasured,
                   OtherTable.MeasuredMassDay,
                   OtherTable.EndMass,
                   (SELECT SUM(Measured) as Measured
                    FROM #AdditivesStart
                    WHERE Name LIKE N'%Продукт №11%') as MeasuredStart
            FROM #TempFilteredData temp
                     LEFT JOIN
                 (SELECT N'Продукт №11'   as Name,
                         SUM(ComingMix)         As ComingMix,
                         SUM(MeasuredMassDay)   as MeasuredMassDay,
                         SUM(MeasuredMassAccum) as MeasuredMassAccum,
                         SUM(EndMass)           as EndMass
                  FROM OtherTable1
                  WHERE CaseId = @caseId
                    AND Name LIKE N'%Продукт №11') AS OtherTable
                 ON OtherTable.Name = temp.Product1C
                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №11';

            UPDATE #TempFilteredData
            SET shipmentMonth = (MeasuredStart + StartMonthMeasured - Measured)
            WHERE Product1C = N'Продукт №11 (смешение)'
            UPDATE #TempFilteredData
            SET DailyMeasured      = daily.Measured,
                StartMonthMeasured = PCM.Measured,
                shipmentDaily      = ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                                         COALESCE(temp.Measured, 0)),
                shipmentMonth      = ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                                         COALESCE(temp.Measured, 0))
            FROM #TempFilteredData temp
                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №11'

            -- Противоизносная присадка Продукт №1
            INSERT #TempFilteredData (Product1C, DailyMeasured, StartMonthMeasured, shipmentDaily,
                                      Measured, MeasuredStart)
            SELECT N'Продукт №1 (смешение)'          as Product1C,
                   ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                       COALESCE(temp.Measured, 0))                  as DailyMeasured,
                   ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                       COALESCE(temp.Measured, 0))                  as StartMonthMeasured,
                   OtherTable.MeasuredMassDay,
                   OtherTable.EndMass,
                   (SELECT SUM(Measured) as Measured
                    FROM #AdditivesStart
                    WHERE Name LIKE N'%Продукт №1%') as MeasuredStart
            FROM #TempFilteredData temp

                     LEFT JOIN
                 (SELECT N'Продукт №1' as Name,
                         SUM(MeasuredMassDay)         as MeasuredMassDay,
                         SUM(MeasuredMassAccum)       as MeasuredMassAccum,
                         SUM(EndMass)                 as EndMass
                  FROM OtherTable1
                  WHERE CaseId = @caseId
                    AND Name LIKE N'%Продукт №1%') AS OtherTable
                 ON OtherTable.Name = temp.Product1C

                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №1';

            UPDATE #TempFilteredData
            SET DailyMeasured      = daily.Measured,
                StartMonthMeasured = PCM.Measured,
                shipmentDaily      = ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                                         COALESCE(temp.Measured, 0)),
                shipmentMonth      = ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                                         COALESCE(temp.Measured, 0))

            FROM #TempFilteredData temp
                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №1'

            -- Антиокислительная присадка
            INSERT #TempFilteredData (Product1C, DailyMeasured, StartMonthMeasured, shipmentDaily,
                                      Measured, MeasuredStart)
            SELECT N'Продукт №2 (смешение)'          as Product1C,
                   ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                       COALESCE(temp.Measured, 0))                  as DailyMeasured,
                   ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                       COALESCE(temp.Measured, 0))                  as StartMonthMeasured,
                   OtherTable.MeasuredMassDay,
                   OtherTable.EndMass,
                   (SELECT SUM(Measured) as Measured
                    FROM #AdditivesStart
                    WHERE Name LIKE N'%Продукт №2%') as MeasuredStart
            FROM #TempFilteredData temp

                     LEFT JOIN
                 (SELECT N'Продукт №2' as Name,
                         SUM(MeasuredMassDay)         as MeasuredMassDay,
                         SUM(MeasuredMassAccum)       as MeasuredMassAccum,
                         SUM(EndMass)                 as EndMass
                  FROM OtherTable1
                  WHERE CaseId = @caseId
                    AND Name LIKE N'%Продукт №2%') AS OtherTable
                 ON OtherTable.Name = temp.Product1C

                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №2';

            UPDATE #TempFilteredData
            SET shipmentMonth = (MeasuredStart + StartMonthMeasured - Measured)
            WHERE Product1C = N'Продукт №2 (смешение)'

            UPDATE #TempFilteredData
            SET DailyMeasured      = daily.Measured,
                StartMonthMeasured = PCM.Measured,
                shipmentDaily      = ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                                         COALESCE(temp.Measured, 0)),
                shipmentMonth      = ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                                         COALESCE(temp.Measured, 0))
            FROM #TempFilteredData temp
                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №2'

            -- Продукт №3
            INSERT #TempFilteredData (Product1C, shipmentDaily)
            VALUES (N'Продукт №3 (смешение)', 0)

            -- Продукт №4
            INSERT #TempFilteredData (Product1C, DailyMeasured, StartMonthMeasured, shipmentDaily, shipmentMonth,
                                      Measured, MeasuredStart)
            SELECT N'Продукт №4 (смешение)' as Product1C,
                   --ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) - COALESCE(temp.Measured, 0)),
                   COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) - COALESCE(temp.Measured, 0) as DailyMeasured,
                   ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                       COALESCE(temp.Measured, 0)),
                   OtherTable.MeasuredMassDay,
                   OtherTable.MeasuredMassAccum,
                   OtherTable.EndMass,
                   (SELECT SUM(Measured) as Measured
                    FROM #AdditivesStart
                    WHERE Name LIKE N'%Продукт №4%')                  as MeasuredStart
            FROM #TempFilteredData temp

                     LEFT JOIN
                 (SELECT N'Продукт №4' as Name,
                         SUM(MeasuredMassDay)                     as MeasuredMassDay,
                         SUM(MeasuredMassAccum)                   as MeasuredMassAccum,
                         SUM(EndMass)                             as EndMass
                  FROM OtherTable1
                  WHERE CaseId = @caseId
                    AND Name LIKE N'%Продукт №4%') AS OtherTable
                 ON OtherTable.Name = temp.Product1C

                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = 'Продукт №4'
                     LEFT JOIN #PetrolComponentsMonth PCM on 'Продукт №4' = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №4';

            UPDATE #TempFilteredData
            SET shipmentMonth = (MeasuredStart + StartMonthMeasured - Measured)
            WHERE Product1C = N'Продукт №4 (смешение)'

            UPDATE #TempFilteredData
            SET DailyMeasured      = daily.Measured,
                StartMonthMeasured = PCM.Measured,
                shipmentDaily      = ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                                         COALESCE(temp.Measured, 0)),
                shipmentMonth      = ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                                         COALESCE(temp.Measured, 0))
            FROM #TempFilteredData temp
                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = 'Продукт №4'
                     LEFT JOIN #PetrolComponentsMonth PCM on 'Продукт №4' = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №4'

            -- Продукт №5
            INSERT #TempFilteredData (Product1C, DailyMeasured, StartMonthMeasured, shipmentDaily, shipmentMonth,
                                      Measured, MeasuredStart)
            SELECT N'Продукт №5 (смешение)' as Product1C,
                 --  ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) - COALESCE(temp.Measured, 0)),

                   COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) - COALESCE(temp.Measured, 0) as DailyMeasured,
                   ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                       COALESCE(temp.Measured, 0)),
                   OtherTable.MeasuredMassDay,
                   OtherTable.MeasuredMassAccum,
                   OtherTable.EndMass,
                   (SELECT SUM(Measured) as Measured
                    FROM #AdditivesStart
                    WHERE Name LIKE N'%Продукт №5%')                  as MeasuredStart
            FROM #TempFilteredData temp

                     LEFT JOIN
                 (SELECT N'Продукт №5' as Name,
                         SUM(MeasuredMassDay)                     as MeasuredMassDay,
                         SUM(MeasuredMassAccum)                   as MeasuredMassAccum,
                         SUM(EndMass)                             as EndMass
                  FROM OtherTable1
                  WHERE CaseId = @caseId
                    AND Name LIKE N'%Продукт №5%') AS OtherTable
                 ON OtherTable.Name = temp.Product1C

                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №5';

            UPDATE #TempFilteredData
            SET shipmentMonth = (MeasuredStart + StartMonthMeasured - Measured)
            WHERE Product1C = N'Продукт №5 (смешение)'
            UPDATE #TempFilteredData
            SET DailyMeasured      = daily.Measured,
                StartMonthMeasured = PCM.Measured,
                shipmentDaily      = ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                                         COALESCE(temp.Measured, 0)),
                shipmentMonth      = ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                                         COALESCE(temp.Measured, 0))

            FROM #TempFilteredData temp
                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №5'

            -- Продукт №6
            INSERT #TempFilteredData (Product1C, DailyMeasured, StartMonthMeasured, shipmentDaily,
                                      Measured, MeasuredStart)
            SELECT N'Продукт №6 (смешение)'          as Product1C,
                   ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                       COALESCE(temp.Measured, 0))  as DailyMeasured,
                   ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                       COALESCE(temp.Measured, 0))  as StartMonthMeasured,
                   OtherTable.MeasuredMassDay,
                   OtherTable.EndMass,
                   CASE 
                        WHEN (SELECT c.AnalysisSfId FROM Cases c WHERE c.id = @caseid) = 'YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY'
                        THEN (SELECT SUM(ads.Measured) FROM #AdditivesStart ads WHERE ads.Name LIKE N'%Продукт №6%')
                        ELSE OtherTable.NachMass 
                   END AS MeasuredStart
            FROM #TempFilteredData temp
                     LEFT JOIN
                 (SELECT N'Продукт №6'               as Name,
                         SUM(MeasuredMassDay)       as MeasuredMassDay,
                         SUM(MeasuredMassAccum)     as MeasuredMassAccum,
                         SUM(EndMass)               as EndMass,
                         SUM(NachMass)              as NachMass
                  FROM OtherTable1
                  WHERE CaseId = @caseId
                    AND Name LIKE N'%Продукт №6%') AS OtherTable
                 ON OtherTable.Name = temp.Product1C

                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №6';

            UPDATE #TempFilteredData
            SET shipmentMonth = (StartMonthMeasured)
            -- MeasuredStart = 0.023
            -- StartMonthMeasured = 0.882
            -- Measured = 0
            WHERE Product1C = N'Продукт №6 (смешение)';

            UPDATE #TempFilteredData
            SET DailyMeasured      = daily.Measured,
                StartMonthMeasured = PCM.Measured,
                shipmentDaily      = ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                                         COALESCE(temp.Measured, 0)),
                shipmentMonth      = ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                                         COALESCE(temp.Measured, 0))
            FROM #TempFilteredData temp
                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №6';

            -- Продукт №7
            INSERT #TempFilteredData (Product1C, DailyMeasured, StartMonthMeasured, shipmentDaily,
                                      Measured, MeasuredStart)
            SELECT N'Продукт №7 (смешение)'           as Product1C,
                   ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                       COALESCE(temp.Measured, 0)) as DailyMeasured,
                   ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                       COALESCE(temp.Measured, 0)) as StartMonthMeasured,
                   OtherTable.MeasuredMassDay,
                   OtherTable.EndMass,
                   CASE 
        WHEN (SELECT c.AnalysisSfId FROM Cases c WHERE c.id = @caseid) = 'YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY'
        THEN (SELECT SUM(ads.Measured) FROM #AdditivesStart ads WHERE ads.Name LIKE N'%Продукт №7%')
        ELSE OtherTable.NachMass 
    END AS MeasuredStart
            FROM #TempFilteredData temp

                     LEFT JOIN
                 (SELECT N'Продукт №7'             as Name,
                         SUM(MeasuredMassDay)   as MeasuredMassDay,
                         SUM(MeasuredMassAccum) as MeasuredMassAccum,
                         SUM(EndMass)           as EndMass,
                         SUM(NachMass)           as NachMass
                  FROM OtherTable1
                  WHERE CaseId = @caseId
                    AND Name LIKE N'%Продукт №7%') AS OtherTable
                 ON OtherTable.Name = temp.Product1C

                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №7';

            UPDATE #TempFilteredData
            SET shipmentMonth = (MeasuredStart + StartMonthMeasured - Measured)
            WHERE Product1C = N'Продукт №7 (смешение)'

            UPDATE #TempFilteredData
            SET DailyMeasured      = daily.Measured,
                StartMonthMeasured = PCM.Measured,
                shipmentDaily      = ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                                         COALESCE(temp.Measured, 0)),
                shipmentMonth      = ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                                         COALESCE(temp.Measured, 0))
            FROM #TempFilteredData temp
                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №7'

            -- Продукт №8 
            INSERT #TempFilteredData (Product1C, DailyMeasured, StartMonthMeasured, shipmentDaily, 
                                      Measured, MeasuredStart)
            SELECT N'Продукт №8 (смешение)' as Product1C,
                   -- DailyMeasured (суточный приход по формуле баланса)
                   --ABS(
                   COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) - COALESCE(temp.Measured, 0) as DailyMeasured,

                   -- StartMonthMeasured (месячный приход по формуле баланса)
                   ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) - 
                       COALESCE(temp.Measured, 0)) as StartMonthMeasured,
                   -- shipmentDaily (из OtherTable1)
                   OtherTable.MeasuredMassDay,
                   -- Measured (из OtherTable1)
                   OtherTable.EndMass,
                   -- MeasuredStart (остаток на начало месяца из #AdditivesStart)
                   (SELECT SUM(Measured) FROM #AdditivesStart WHERE Name LIKE N'%Продукт №8%') as MeasuredStart
            FROM #TempFilteredData temp
            LEFT JOIN (
                SELECT N'Продукт №8' as Name,
                       SUM(CASE WHEN c.AnalysisSfId = 'YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY' 
                                THEN t1.MeasuredMassDay ELSE t1.MeasuredMassAccum END) as MeasuredMassDay,
                       SUM(t1.EndMass) as EndMass
                FROM OtherTable1 t1
                LEFT JOIN Cases c ON t1.CaseId = c.id
                WHERE t1.CaseId = @caseId AND t1.Name LIKE N'%Продукт №8%'
            ) AS OtherTable ON 1=1
            LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
            LEFT JOIN #PetrolComponentsMonth PCM ON PCM.ProdName = temp.Product1C
            WHERE temp.Product1C = N'Продукт №8';

            -- Продукт №9 
            INSERT #TempFilteredData (Product1C, DailyMeasured, StartMonthMeasured, shipmentDaily,
                                      Measured, MeasuredStart)
            SELECT N'Продукт №9 (смешение)'           as Product1C,
                   ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                       COALESCE(temp.Measured, 0)) as DailyMeasured,
                   ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                       COALESCE(temp.Measured, 0)) as StartMonthMeasured,
                   OtherTable.MeasuredMassDay,
                   OtherTable.EndMass,
                   CASE 
        WHEN (SELECT c.AnalysisSfId FROM Cases c WHERE c.id = @caseid) = 'YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY'
        THEN (SELECT SUM(ads.Measured) FROM #AdditivesStart ads WHERE ads.Name LIKE N'%Продукт №9%')
        ELSE OtherTable.NachMass 
    END AS MeasuredStart
            FROM #TempFilteredData temp

                     LEFT JOIN
                 (SELECT N'Продукт №9'             as Name,
                         SUM(MeasuredMassDay)   as MeasuredMassDay,
                         SUM(MeasuredMassAccum) as MeasuredMassAccum,
                         SUM(EndMass)           as EndMass,
                         SUM(NachMass)           as NachMass
                  FROM OtherTable1
                  WHERE CaseId = @caseId
                    AND Name LIKE N'%Продукт №9%') AS OtherTable
                 ON OtherTable.Name = temp.Product1C

                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №9';

            UPDATE #TempFilteredData
            SET shipmentMonth = (MeasuredStart + StartMonthMeasured - Measured)
            WHERE Product1C = N'Продукт №9 (смешение)'

            UPDATE #TempFilteredData
            SET DailyMeasured      = daily.Measured,
                StartMonthMeasured = PCM.Measured,
                shipmentDaily      = ABS(COALESCE(temp.MeasuredOld, 0) + COALESCE(daily.Measured, 0) -
                                         COALESCE(temp.Measured, 0)),
                shipmentMonth      = ABS(COALESCE(temp.MeasuredStart, 0) + COALESCE(PCM.Measured, 0) -
                                         COALESCE(temp.Measured, 0))
            FROM #TempFilteredData temp
                     LEFT JOIN #PetrolComponentsDaily daily ON daily.ProdName = temp.Product1C
                     LEFT JOIN #PetrolComponentsMonth PCM on temp.Product1C = PCM.ProdName
            WHERE temp.Product1C = N'Продукт №9'
        END;

    INSERT INTO #TempFilteredData
    SELECT N'Продукт №13'     as Product1C,
           N'Продукт №13' as GroupName,
           SUM(shipmentDaily)         as shipmentDaily,
           SUM(shipmentMonth)         as shipmentMonth,
           SUM(Measured)              as Measured,
           SUM(MeasuredOld)           as MeasuredOld,
           SUM(MeasuredNotIssued)     as MeasuredNotIssued,
           SUM(MeasuredStart)         as MeasuredStart,
           SUM(MeasuredPass)          as MeasuredPass,
           SUM(MeasuredNotPass)       as MeasuredNotPass,
           SUM(StartMonthMeasured)    as StartMonthMeasured,
           SUM(DailyMeasured)         as DailyMeasured,
           SUM(DeadResidueMass)       as DeadResidueMass,
           SUM(FreeVolume)            as FreeVolume
    FROM #TempFilteredData
    WHERE Product1C IN (N'Продукт №17', N'Продукт №16', N'Продукт №15',
                        N'Продукт №14')
    DELETE
    FROM #TempFilteredData
    WHERE Product1C IN (N'Продукт №17', N'Продукт №16', N'Продукт №15',
                        N'Продукт №14')
END;

-- Группировка
WITH GroupingData AS (SELECT CASE
                                 WHEN GROUPING(Summary.Product1C) = 1 THEN Summary.GroupName
                                 ELSE Summary.Product1C
                                 END                                      AS Product1C,
                             Summary.GroupName,
                             COALESCE(SUM(Summary.DailyMeasured), 0)      AS DailyMeasured,
                             COALESCE(SUM(Summary.StartMonthMeasured), 0) AS StartMonthMeasured,
                             COALESCE(SUM(Summary.shipmentDaily), 0)      AS shipmentDaily,
                             COALESCE(SUM(Summary.shipmentMonth), 0)      AS shipmentMonth,
                             COALESCE(SUM(Summary.Measured), 0)           AS Measured,
                             COALESCE(SUM(Summary.MeasuredStart), 0)      AS MeasuredStart,
                             COALESCE(SUM(Summary.MeasuredPass), 0)       AS MeasuredPass,
                             COALESCE(SUM(Summary.MeasuredNotPass), 0)    AS MeasuredNotPass,
                             COALESCE(SUM(Summary.MeasuredNotIssued), 0)  as MeasuredNotIssued,
                             COALESCE(SUM(Summary.DeadResidueMass), 0)    AS DeadResidueMass,
                             COALESCE(SUM(Summary.FreeVolume), 0)         AS FreeVolume
                      FROM (SELECT COALESCE(SUM(fd.DailyMeasured), 0)      AS DailyMeasured,
                                   COALESCE(SUM(fd.StartMonthMeasured), 0) AS StartMonthMeasured,
                                   COALESCE(SUM(fd.shipmentDaily), 0)      AS shipmentDaily,
                                   COALESCE(SUM(fd.shipmentMonth), 0)      AS shipmentMonth,
                                   COALESCE(SUM(fd.Measured), 0)           AS Measured,
                                   COALESCE(SUM(fd.MeasuredStart), 0)      AS MeasuredStart,
                                   COALESCE(SUM(fd.MeasuredPass), 0)       AS MeasuredPass,
                                   COALESCE(SUM(fd.MeasuredNotPass), 0)    AS MeasuredNotPass,
                                   COALESCE(SUM(fd.MeasuredNotIssued), 0)  AS MeasuredNotIssued,
                                   COALESCE(SUM(fd.Measured) - SUM(fd.MeasuredNotIssued) -
                                            (SUM(fd.MeasuredPass) + SUM(fd.MeasuredNotPass)), 0)
                                                                           AS DeadResidueMass,
                                   COALESCE(SUM(fd.FreeVolume), 0)         AS FreeVolume,
                                   fd.Product1C,
                                   CASE
                                       WHEN @div IS NULL AND fd.Product1C LIKE N'Продукт №19'
                                           THEN N'Продукт №18'
                                       ELSE gp.GroupName
                                       END                                 AS GroupName
                            FROM #TempFilteredData fd
                                     LEFT JOIN [Reports_1C].[dbo].[ProductGroups] gp ON gp.ProductName = fd.Product1C
                            GROUP BY fd.Product1C,
                                     CASE
                                         WHEN @div IS NULL AND fd.Product1C LIKE N'Продукт №19'
                                             THEN N'Продукт №18'
                                         ELSE gp.GroupName
                                         END) AS Summary
                      WHERE (Summary.Product1C LIKE N'%смешение%'
                          OR (
                                 Summary.DailyMeasured != 0
                                     OR Summary.StartMonthMeasured != 0
                                     OR Summary.shipmentDaily != 0
                                     OR Summary.shipmentMonth != 0
                                     OR Summary.Measured != 0
                                     OR Summary.MeasuredPass != 0
                                     OR Summary.MeasuredNotPass != 0
                                     OR Summary.DeadResidueMass != 0
                                     OR Summary.FreeVolume != 0
                                 )
                                )
                      GROUP BY GROUPING SETS ((Summary.Product1C, Summary.GroupName), (Summary.GroupName))),
--сортировка
     SortedProducts AS (
         -- Базовый уровень: записи, которые не имеют предшественника
         SELECT ps.id,
                ps.name,
                ps.after_id,
                1 AS SortOrder
         FROM Reports_1C.dbo.ProductSorting ps
         WHERE ps.after_id IS NULL

         UNION ALL

-- Рекурсия: выбираем записи, которые ссылаются на текущий уровень
         SELECT ps.id,
                ps.name,
                ps.after_id,
                sp.SortOrder + 1 AS SortOrder
         FROM Reports_1C.dbo.ProductSorting ps
                  INNER JOIN SortedProducts sp ON ps.after_id = sp.id)

SELECT DISTINCT g.*,
                ps.id,
                sp.SortOrder
INTO #TempGroupedData
FROM GroupingData g
         LEFT JOIN Reports_1C.dbo.ProductSorting ps ON g.Product1C = ps.name
         LEFT JOIN SortedProducts sp ON ps.id = sp.id
WHERE g.Product1C IS NOT NULL;

UPDATE #TempGroupedData
SET GroupName = tv.GroupName
FROM #TempGroupedData tmp
         LEFT JOIN fn_getTankDivByOrderSystem(@CaseIds) tv
                   ON tv.SfName = tmp.Product1C
WHERE tv.SfName IS NOT NULL

UPDATE t
SET t.DailyMeasured      = t.DailyMeasured + ISNULL(s.TotalDailyMeasured, 0),
    t.StartMonthMeasured = t.StartMonthMeasured + ISNULL(s.TotalDailyMeasured, 0)
FROM #TempGroupedData t
         LEFT JOIN (SELECT GroupName, SUM(DailyMeasured) AS TotalDailyMeasured
                    FROM #TempGroupedData
                    WHERE Product1C LIKE N'%Система%'
                    GROUP BY GroupName) s ON s.GroupName = t.Product1C
WHERE t.Product1C = t.GroupName

/* ЖЕСТКИЕ КОРРЕКТИРОВКИ */
UPDATE #TempGroupedData
SET DeadResidueMass = 0, MeasuredNotIssued = 0
WHERE Product1C IN (
    N'Продукт №1 (смешение)',
    N'Продукт №2 (смешение)',
    N'Продукт №6 (смешение)',
    N'Продукт №8 (смешение)',
    N'Продукт №7 (смешение)',
    N'Продукт №9 (смешение)'
);

/* -------------------  */
SELECT *
FROM #TempGroupedData
--WHERE product1c NOT LIKE '%система%'    -- Убрать эту строку, чтобы появились системы
ORDER BY CASE WHEN SortOrder IS NOT NULL THEN 0 ELSE 1 END,
         SortOrder;