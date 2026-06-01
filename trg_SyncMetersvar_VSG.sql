USE [MB4]
GO
/****** Object:  Trigger [dbo].[trg_SyncMetersvar_VSG]    Script Date: 28.05.2026 19:39:10 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--	====================================================================
--	📅 Дата создания: 06.08.2025
--	👤 Автор скрипта: Габдуллин А.
--	📌 Назначение: Триггер отлавливает изменение значения у одного из трех счётчиков(meters) и устанавливает новое значение для остальных двух
--	====================================================================
--	Если поменяют значение в клиенте у одного из этих счётчиков, то оно поменяется во всех трех:
--	1. Приемка - УПВ - Водородсодержащий газ (FI3-254-1M)
--	2. Отгрузка - УПВ - Водородсодержащий газ (FI3-254-1M)
--	3. МБ Установок - 5. С-200/2 ПППН - В исходящих портах Водородсодержащий газ (FI3-254-1M)
--	====================================================================


ALTER TRIGGER [dbo].[trg_SyncMetersvar_VSG]
ON [dbo].[MetersVar]
AFTER UPDATE -- Триггер срабатывает ПОСЛЕ операции обновления данных в таблице
AS
BEGIN
    SET NOCOUNT ON;

	-- Записываем в лог сам факт запуска триггера
    INSERT INTO dbo.TriggerLog_Metersvar (TriggerName, Info)
    VALUES ('trg_SyncMetersvar_VSG', 'Триггер запущен.');

    -- Объявляем переменные для хранения нового значения и ID сессии (caseid)
    -- ВАЖНО: Укажите здесь тот же тип данных, что и у ваших столбцов
    DECLARE @newValue FLOAT;
    DECLARE @caseId INT;
	DECLARE @logInfo VARCHAR(MAX);

    -- Проверяем, произошло ли обновление в столбце 'measured'
    -- и затронуло ли оно хотя бы одну из наших целевых строк (с id 48, 57, 94)
    IF UPDATE(measured) AND EXISTS (SELECT 1 FROM inserted WHERE id IN (48, 57, 94))
    BEGIN
        -- Если да, то извлекаем новое значение и caseid из виртуальной таблицы 'inserted'.
        -- В 'inserted' содержатся строки в их новом, обновленном виде.
        SELECT TOP 1
            @newValue = i.measured,
            @caseId = i.caseid
        FROM
            inserted i
        WHERE
            i.id IN (48, 57, 94);

        -- УСЛОВИЕ: если caseid меньше 2689, прерываем выполнение [будет работать со дня - создания триггера]
        IF @caseId < 2689
        BEGIN
            SET @logInfo = 'Триггер прерван, т.к. caseId (' + CAST(@caseId AS VARCHAR(50)) + ') < 2689.';
            INSERT INTO dbo.TriggerLog_Metersvar (TriggerName, Info) VALUES ('trg_SyncMetersvar_VSG', @logInfo);
            RETURN; -- Выход из триггера
        END

		SET @logInfo = 'Условие выполнено. Захвачены значения: @newValue = ' + CAST(@newValue AS VARCHAR(50)) + ', @caseId = ' + CAST(@caseId AS VARCHAR(50));
		INSERT INTO dbo.TriggerLog_Metersvar (TriggerName, Info) VALUES ('trg_SyncMetersvar_VSG', @logInfo);

        -- Теперь обновляем все три целевые строки, но только для того же caseid,
        -- чтобы не затронуть записи из других сессий.
        -- Дополнительно проверяем, что текущее значение не равно новому,
        -- чтобы избежать бесконечного вызова триггера (рекурсии).
        UPDATE dbo.metersvar
        SET
            measured = @newValue
        WHERE
            id IN (48, 57, 94)
            AND caseid = @caseId
            AND (measured IS NULL OR measured <> @newValue);
    END

    INSERT INTO dbo.TriggerLog_Metersvar (TriggerName, Info)
    VALUES ('trg_SyncMetersvar_VSG', 'Триггер завершил работу.');
END;
