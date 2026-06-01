-- =======================================================================
-- >> Шаг 1: ОСНОВНЫЕ ПАРАМЕТРЫ <<
-- =======================================================================
DECLARE @CaseID INT = {0}; -- C# подставит сюда ID расчета
DECLARE @CaseTypeName NVARCHAR(100) = 'Суточный'; -- тип (напр. 'Суточный')

-- Шаг 2: Начинаем общую транзакцию для всех операций
BEGIN TRAN;

-- Шаг 3: Создание "таблицы-инструкции" для всех задач
DECLARE @Tasks TABLE (
	TaskID int IDENTITY(1,1) PRIMARY KEY,
	-- Параметры для ПОИСКА значения (откуда берем цифру)
	Source_ObjectID int, Source_FlowSourceID int, Source_ProductSourceID int, Source_FlowDestID int, Source_ProductDestID int,
	-- Параметры для ЗАМЕНЫ (где обнуляем и вставляем)
	Target_SourceID int, Target_DestID int, Target_ProductSourceID int, Target_ProductDestID int
);

-- #############################################################################
-- ## Шаг 4: ЗАПОЛНИТЬ ТАБЛИЦУ НЕОБХОДИМЫМИ ЗНАЧЕНИЯМИ                        ##
-- ## Добавлять новые строки INSERT INTO для каждой новой операции            ##
-- #############################################################################

INSERT INTO @Tasks (
	Source_ObjectID, Source_FlowSourceID, Source_ProductSourceID, Source_FlowDestID, Source_ProductDestID,
	Target_SourceID, Target_DestID, Target_ProductSourceID, Target_ProductDestID
) VALUES
-- # Из [Узел_ПКОН_Выход_FI-71F_Пропан-пропиленовая фракция] в [ЕЦ 16-22] #
(3585, 3585, 357, 488, 357,   -- Откуда берем значение
 488, 10204, 357, 442),       -- Где будем менять

-- # Из [Узел_ПКОН_Выход_FI-82F_Бутан-бутиленовая фракция] в [ЕС 01,02,05,06] #
(3585, 3585, 83, 434, 83,   -- Откуда берем значение
 434, 10193, 83, 351);--запятая вместо ;       -- Где будем менять

-- ЗАДАЧА 3
--(9999, 9999, 888, 777, 888,   -- Откуда берем значение
-- 666, 5555, 444, 333);       -- Где будем менять

-- #############################################################################
-- ## Дальше ничего менять не нужно. Скрипт все сделает сам.                  ##
-- #############################################################################

-- Шаг 5: Объявление переменных для цикла
DECLARE @CurrentTaskID int = 1;
DECLARE @MaxTaskID int = (SELECT MAX(TaskID) FROM @Tasks);
DECLARE @NewValue numeric(38, 3);
DECLARE @IdsToUpdate TABLE (Id int);

-- Основной цикл, который проходит по каждой задаче из таблицы @Tasks
WHILE @CurrentTaskID <= @MaxTaskID
BEGIN
	PRINT 'Выполняется задача #' + CAST(@CurrentTaskID AS nvarchar(10)) + '...';
	SET @NewValue = NULL;
	DELETE FROM @IdsToUpdate;
 
	DECLARE @s_obj int, @s_fsrc int, @s_psrc int, @s_fdest int, @s_pdest int;
	DECLARE @t_src int, @t_dest int, @t_psrc int, @t_pdest int;

	SELECT
		@s_obj = Source_ObjectID, @s_fsrc = Source_FlowSourceID, @s_psrc = Source_ProductSourceID, @s_fdest = Source_FlowDestID, @s_pdest = Source_ProductDestID,
		@t_src = Target_SourceID, @t_dest = Target_DestID, @t_psrc = Target_ProductSourceID, @t_pdest = Target_ProductDestID
	FROM @Tasks WHERE TaskID = @CurrentTaskID;

	-- 1. Получаем значение, которое нужно вставить
	SELECT TOP 1 @NewValue = Measured FROM [MB4].[dbo].[PNHZ_OBJECTS_FLOW_DETAILS_VIEW]
	WHERE CaseID = @CaseID AND CaseTypeName = @CaseTypeName AND ObjectID = @s_obj AND FlowSourceID = @s_fsrc
		AND ProductSourceID = @s_psrc AND FlowDestID = @s_fdest AND ProductDestID = @s_pdest;

	IF @NewValue IS NULL BEGIN
		PRINT '  > ВНИМАНИЕ: Для задачи #' + CAST(@CurrentTaskID AS nvarchar(10)) + ' не найдено исходное значение. Пропускаем...';
	END ELSE BEGIN
		-- 2. Находим ID всех строк для обновления и сохраняем их
		INSERT INTO @IdsToUpdate (Id)
		SELECT T.Id FROM MB4.dbo.Transactions AS T
		INNER JOIN dbo.Cases AS c ON c.id = t.caseid INNER JOIN dbo.Analyses AS a ON a.sfid = c.AnalysisSfId
		INNER JOIN dbo.Objects AS OTR ON T.Id = OTR.Id AND OTR.IsDeleted != 1
		INNER JOIN dbo.Objects AS OS ON T.SourceId = OS.Id AND OS.IsDeleted != 1 AND OS.ObjectTypeId IN (SELECT OT.Id FROM MB4.dbo.ObjectTypes OT WHERE OT.CodeName IN ('Tank', 'Node'))
		INNER JOIN dbo.Objects AS OD ON T.DestId = OD.Id AND OD.IsDeleted != 1
		INNER JOIN MB4.dbo.Products AS P ON (T.ProductId = P.Id AND P.IsDeleted != 1) INNER JOIN MB4.dbo.Products AS PSEC ON (T.SecondProductId = PSEC.Id AND PSEC.IsDeleted != 1)
		LEFT JOIN MB4.dbo.Ports AS PD ON T.DestId = PD.Id LEFT JOIN dbo.Objects AS PDO ON PDO.Id = PD.UnitId AND PDO.IsDeleted != 1
		LEFT JOIN MB4.dbo.Ports AS PS ON T.SourceId = PS.Id LEFT JOIN dbo.Objects AS PSO ON PSO.Id = PS.UnitId AND PSO.IsDeleted != 1
		WHERE T.caseid = @CaseID AND a.Name = @CaseTypeName AND T.sourceid = @t_src AND OD.ID = @t_dest AND OS.ID = @t_src AND T.ProductId = @t_psrc AND T.SecondProductId = @t_pdest;

		IF NOT EXISTS (SELECT 1 FROM @IdsToUpdate) BEGIN
				PRINT '  > ВНИМАНИЕ: Для задачи #' + CAST(@CurrentTaskID AS nvarchar(10)) + ' не найдено строк для обновления. Пропускаем...';
		END ELSE BEGIN
			-- 3. Обнуляем ВСЕ найденные строки
			UPDATE T SET T.Measured = 0, T.Reconciled = 0
			FROM MB4.dbo.Transactions AS T INNER JOIN @IdsToUpdate AS I ON T.Id = I.Id;

			-- 4. Записываем новое значение в ОДНУ из этих строк (с наименьшим ID)
			UPDATE T SET T.Measured = @NewValue
			FROM MB4.dbo.Transactions AS T WHERE T.Id = (SELECT MIN(Id) FROM @IdsToUpdate);

			PRINT '  > Задача #' + CAST(@CurrentTaskID AS nvarchar(10)) + ' выполнена успешно.';
		END
	END

	SET @CurrentTaskID = @CurrentTaskID + 1;
END

PRINT '==================================================';
PRINT 'Все задачи выполнены. Завершение транзакции...';

-- Шаг 6: Завершение транзакции.
COMMIT TRAN;    -- Сохраняем все изменения, сделанные в цикле
-- ROLLBACK TRAN;  -- Или откатываем, если нужно прервать