/*
	В клиенте на вкладке "Присадки", в таблицу УПДЭЙТИМ значения по исходящим операциям в столбец "Приход в производство"

	Берутся согласованные значения, после согласования периода
*/

USE MB4;

DECLARE @caseID INT = {0};

WITH UpdateMap AS (
    SELECT *
    FROM (VALUES
            -- PRODUCTID1, PRODUCTID2, SOURCEID,  DESTID,   TargetId,  FlowIsInputParam
            (459,          0,          	10201,     0,        113385,    1), -- [Продукт 1]
            (342,          0,          	579,       470,      54555,     0), -- [Продукт 2]
            (342,          0,          	579,       452,      3549,      0), -- [Продукт 3]
            (229,          0,          	10188,     20209,    3554,      0), -- [Продукт 4]
            (229,          0,          	10188,     20208,    54554,     0), -- [Продукт 5]
            (457,          349,        	109117,    0,        109115,    0), -- [Продукт 6]
            (224,          347,        	3409,      10205,    3550,      0), -- [Продукт 7]
            (223,          347,        	3410,      10205,    3552,      0), -- [Продукт 8]
            (343,          0,			10189,     0,        3548,      0), -- [Продукт 9]
            (221,          0,			3411,      0,        3553,      0), -- [Продукт 10]
            (222,          349,        	3413,      10201,    3551,      0)	-- [Продукт 11]
			--, (0,				0,			0,			0,		307252,			0)	-- [Продукт  12]
    ) AS M (PRODUCTID1, PRODUCTID2, SOURCEID, DESTID, TargetId, FlowIsInputParam)
),
ReconciledSums AS (
    SELECT 
        M.TargetId,
        SUM(ISNULL(T.reconciled, 0)) AS SumReconciled
    FROM UpdateMap M
    CROSS APPLY (
        SELECT T.reconciled
        FROM [MB4].[dbo].[PNHZ_OBJECTS_FLOW_DETAILS_VIEW] T
        WHERE
            T.caseID = @caseID AND
            (T.productsourceid = M.PRODUCTID1 OR M.PRODUCTID1 = 0) AND
            (T.productdestid = M.PRODUCTID2 OR M.PRODUCTID2 = 0) AND
            (T.objectid = M.SOURCEID OR M.SOURCEID = 0) AND
            (T.Flowdestid = M.DESTID OR M.DESTID = 0) AND
            T.FlowIsInput = ISNULL(M.FlowIsInputParam, 0)
    ) T
    GROUP BY M.TargetId
)

UPDATE OT1
SET 
    OT1.ComingMix = RS.SumReconciled,
    OT1.EndMass = OT1.NachMass + RS.SumReconciled - 
        CASE 
            WHEN a.name = 'Накопительный' THEN ISNULL(OT1.MeasuredMassAccum, 0)
            ELSE ISNULL(OT1.MeasuredMassDay, 0)
        END
FROM OtherTable1 OT1
JOIN ReconciledSums RS ON OT1.Id = RS.TargetId
JOIN Cases c ON c.id = OT1.caseid
JOIN Analyses a ON a.SfId = c.AnalysisSfId
WHERE OT1.caseID = @caseID;

/*************************************/
/* Заявка SMAX 2686149 от 03.04.2026 */	

UPDATE OtherTable1
SET
	NachMass = 0,
	MeasuredMassDay = ComingMix,	
	MeasuredMassAccum = ComingMix,
	EndMass = 0
WHERE 1 = 1
	AND CaseID = @CaseID
	AND Name LIKE '%Продукт 1%'