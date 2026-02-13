assessments_wide_sql <- "
SELECT apt.*,
       GROUP_CONCAT(epa.idPathway || ':' || epa.name, ', ') AS entryPathways
  FROM (
           SELECT a.idAssessment,
                  a.idAssessor,
                  asr.firstName,
                  asr.lastName,
                  asr.email,-- a.idPest,
                  p.scientificName,
                  p.eppoCode,
                  p.vernacularName,
                  p.synonyms,-- p.taxonomicName,
                  /* p.idQuarantineStatus, */qs.name AS quarantineStatus,
                  tg.name AS taxonomicGroup,
                  GROUP_CONCAT(tsa.name, ', ') AS threatenedSectors,
                  a.endDate,
                  a.valid,
                  a.finished,
                  a.notes,
                  a.version,
                  a.reference
             FROM assessments a
                  LEFT JOIN
                  assessors asr ON a.idAssessor = asr.idAssessor
                  LEFT JOIN
                  pests p ON a.idPest = p.idPest
                  LEFT JOIN
                  quarantineStatus qs ON p.idQuarantineStatus = qs.idQuarantineStatus
                  LEFT JOIN
                  taxonomicGroups tg ON p.idTaxa = tg.idTaxa
                  LEFT JOIN
                  (
                      SELECT ta.idAssessment,
                             ts.name
                        FROM threatXassessment ta
                             LEFT JOIN
                             threatenedSectors ts ON ta.idThrSect = ts.idThrSect
                  )
                  AS tsa ON a.idAssessment = tsa.idAssessment
            GROUP BY a.idAssessment
       )
       AS apt
       LEFT JOIN
       (
           SELECT ep.idAssessment,
                  ep.idPathway,
                  p.name
             FROM entryPathways ep
                  LEFT JOIN
                  pathways p ON ep.idPathway = p.idPathway
       )
       AS epa ON apt.idAssessment = epa.idAssessment
 GROUP BY epa.idAssessment;"

answers_sql <- "SELECT 
       a.*,
       q.'group',
       q.number, 
       q.question, 
       q.list 
FROM answers a
LEFT JOIN questions q ON a.idQuestion = q.idQuestion"

answers_entry_sql <- "SELECT 
       a.*,
       e.idAssessment, 
       q.'group',
       q.number, 
       q.question, 
       q.list
FROM pathwayAnswers a
LEFT JOIN pathwayQuestions q ON a.idPathQuestion = q.idPathQuestion
LEFT JOIN entryPathways e ON a.idEntryPathway = e.idEntryPathway"


simulations_sql <- "SELECT
       s.*,
       ss.variable, 
       ss.min,
       ss.q5,
       ss.q25,
       ss.median,
       ss.mean,
       ss.q75,
       ss.q95,
       ss.max
FROM simulations s
JOIN assessments a ON s.idAssessment = a.idAssessment
LEFT JOIN simulationSummaries ss ON s.idSimulation = ss.idSimulation
WHERE a.valid = 1
AND s.date = (
    SELECT MAX(date)
    FROM simulations
    WHERE idAssessment = s.idAssessment );"