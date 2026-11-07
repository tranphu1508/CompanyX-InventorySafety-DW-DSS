SELECT COUNT(*) n FROM dss.Fact_PolicySimulation p LEFT JOIN
        (SELECT PlanningRunKey,ProductKey,SUM(OTUDemandQty) demand,SUM(OTUOnTimeQty) ont,
          SUM(CASE WHEN EvaluationCohort<>'FUTURE_DUE' THEN FilledQty ELSE 0 END) filled,
          SUM(CASE WHEN EvaluationCohort<>'FUTURE_DUE' THEN LostQty ELSE 0 END) lost,
          SUM(OverdueUnfilledQtyAtEnd) backlog,SUM(LateUnitDays) late
         FROM dss.v_SimulationOrderLine WHERE PlanningRunKey=@pk GROUP BY PlanningRunKey,ProductKey) v
        ON p.PlanningRunKey=v.PlanningRunKey AND p.ProductKey=v.ProductKey WHERE p.PlanningRunKey=@pk AND
        (ABS(p.TotalDemandQty-COALESCE(v.demand,0))>0.00001 OR ABS(p.OnTimeDeliveredQty-COALESCE(v.ont,0))>0.00001 OR
         ABS(p.FilledQty-COALESCE(v.filled,0))>0.00001 OR ABS(p.LostQty-COALESCE(v.lost,0))>0.00001 OR
         ABS(p.EndingBacklogQty-COALESCE(v.backlog,0))>0.00001 OR ABS(p.LateUnitDays-COALESCE(v.late,0))>0.00001)