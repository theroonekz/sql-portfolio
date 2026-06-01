USE [iomsdb]
GO
/****** Object:  StoredProcedure [dbo].[CopyTagValues]    Script Date: 28.05.2026 19:23:13 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER   PROCEDURE [dbo].[CopyTagValues]
AS
BEGIN
	DELETE FROM [dbo].[ExternalTagValues]
	DECLARE @tagName VARCHAR(256)
	DECLARE @TS datetime
	DECLARE @ModuleType int
	DECLARE @Value float
	DECLARE @startPeriod datetime = (SELECT TOP 1 DATEADD(HOUR, StartHour, DATEADD(dd, 0, DATEDIFF(dd, 0, GETDATE()))) FROM OMSPeriods ORDER BY StartHour)
	IF @startPeriod > GETDATE()
		SET @startPeriod = DATEADD(DAY, -2, @startPeriod)
	ELSE
		SET @startPeriod = DATEADD(DAY, -1, @startPeriod)
	DECLARE @TagValuesTable TABLE(
		TagPath nvarchar(256),
		IntValue int,
		FloatValue float,
		StringValue nvarchar(128),
		DateValue datetime,
		TagState int,
		TStampInMillis bigint,
		TStamp datetime
		);
	DECLARE @TagAccTable TABLE(
		Accumulation float
		);
	DECLARE db_cursor CURSOR FOR 
	WITH params as (SELECT 
			startPeriod = @startPeriod,
			weightTankName = (SELECT TOP 1 PreferenceValue FROM UserPreferences WHERE PreferenceName = 'ObjectRequiredAliases|MassTotal')		
		),
		params2 AS (SELECT 
			endPeriod = (SELECT TOP 1 DATEADD(HOUR, Duration, params.startPeriod) FROM OMSPeriods, params)),
		transfersOnPeriod AS (SELECT * 
			FROM oms.Transfer t1, params p1, params2 p2
			WHERE (t1.StartTime >= p1.startPeriod AND t1.StartTime <= p2.endPeriod)
				OR (t1.EndTime >= p1.startPeriod AND t1.EndTime <= p2.endPeriod)
				OR (t1.StartTime <= p2.endPeriod AND (t1.EndTime is null OR t1.EndTime >= p2.endPeriod))),
		times as (SELECT DISTINCT 
			StartTime AS timespan FROM transfersOnPeriod
			UNION SELECT ISNULL(EndTime, params2.endPeriod) AS timespan FROM transfersOnPeriod, params2
			UNION SELECT startPeriod AS timespan FROM params
			UNION SELECT endPeriod AS timespan FROM params2),
		tagNames as (SELECT DISTINCT
			tagName = ea.[DataReferenceProperties].value('(/Properties/@TagName)[1]', 'nvarchar(128)'),
			objectType = o.ObjectType,
			a.AliasId
			FROM transfersOnPeriod t
				INNER JOIN oms.[Object] o ON (o.ObjectUID = t.SourceUID OR o.ObjectUID = t.DestinationUID)
				INNER JOIN Aliases a ON CASE
					WHEN o.ObjectType = 'Unit'
						AND (CAST(a.NodeId AS nvarchar(256)) = t.SourceNode OR CAST(a.NodeId AS nvarchar(256)) = t.DestNode) THEN 1
					WHEN o.ObjectType = 'Tank'
						AND a.AliasName = weightTankName 
						AND (a.ModuleId = t.SourceUID OR a.ModuleId = t.DestinationUID) THEN 1
					ELSE 0 END = 1
				INNER JOIN [I-DS-P-Legacy].dbo.ElementAttribute ea ON ea.ObjectId = a.AliasId
			)
		SELECT 
			tagName as Name,
			(CASE tn.objectType
				WHEN 'Unit' THEN 2
				WHEN 'Tank' THEN 1
			END
			) as moduleType, 
			t.timespan as TS
		FROM tagNames tn, params
			CROSS JOIN times t
		WHERE t.timespan IS NOT NULL 
			AND tagName <> '' 
			AND tagName IS NOT NULL
		
	OPEN db_cursor
	FETCH NEXT FROM db_cursor INTO @tagName, @ModuleType, @TS
	WHILE @@FETCH_STATUS = 0  
	BEGIN
		IF @ModuleType = 1 BEGIN 
			INSERT INTO @TagValuesTable(
				TagPath,
				IntValue ,
				FloatValue  ,
				StringValue,
				DateValue,
				TagState,
				TStampInMillis,
				TStamp
			) EXEC [0.0.0.0].[mesdb].[dbo].[EncryptedFuncNameToGetLastTagValue]  @tagPath=@tagName, @periodEnd=@TS;

			SELECT TOP 1 @Value = ISNULL(FloatValue, 0) FROM @TagValuesTable

			DELETE FROM @TagValuesTable;
		END	ELSE 
		BEGIN
			INSERT INTO @TagAccTable(
				Accumulation
			) EXEC [0.0.0.0].[mesdb].[dbo].[EncryptedFuncNameToGetTagAccumulation] @tagPath=@tagName, @PeriodStart=@startPeriod, @periodEnd=@TS;

			SELECT TOP 1 @Value = ISNULL(Accumulation, 0) FROM @TagAccTable

			DELETE FROM @TagAccTable;
		END;

		INSERT INTO [dbo].[ExternalTagValues] ([TagName], [Value], [TS])
		VALUES (@tagName, @Value, @TS); 	
 		FETCH NEXT FROM db_cursor INTO @tagName, @ModuleType, @TS
	END 
	CLOSE db_cursor
	DEALLOCATE db_cursor 

	DELETE FROM [dbo].[ExternalTagValuesBackUP]
	WHERE YEAR([TS]) = YEAR(@startPeriod) 
	  AND MONTH([TS]) = MONTH(@startPeriod) 
	  AND DAY([TS]) = DAY(@startPeriod);

	INSERT INTO [dbo].[ExternalTagValuesBackUP] ([TagName], [Value], [TS])
    SELECT [TagName], [Value], [TS]
    FROM [dbo].[ExternalTagValues];
END