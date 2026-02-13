# Description: Functions to perform Monte Carlo simulations for risk assessment.
#' @param answers Data frame containing assessment answers.
#' @param tag Question tag to extract PERT distribution parameters.
#' @param iterations Number of Monte Carlo simulation iterations.
#' @param lambda Shape parameter for the PERT distribution.
#' @return A vector of simulated values from the PERT distribution.
rpert_from_tag <- function(answers, tag, iterations = 5000, lambda = 1) {
  points <- answers[answers$question == tag, c("min_points", "likely_points", "max_points")] |> 
    as.numeric()
  res <- rpert(iterations, points[1], points[2], points[3], lambda)
  return(res)
}


# Inclusion-Exclusion Principle Score Calculation
#' @param score_matrix A matrix where each column represents scores from different pathways.
#' @return A vector of combined scores using the inclusion-exclusion principle.

generate_inclusion_exclusion_score <- function(score_matrix) {
  if( is.vector(score_matrix)){
    n <- 1
    iterations <- length(score_matrix)
    result <- score_matrix
  } else {
    if( is.matrix(score_matrix)){
      n <- ncol(score_matrix)
      iterations <- nrow(score_matrix)
      result <- numeric(iterations)
      for (k in 1:n) {
        combos <- combn(n, k, simplify = FALSE)
        for (combo in combos) {
          sign <- ifelse(k %% 2 == 1, 1, -1)
          term <- apply(score_matrix[, combo, drop = FALSE], 1, prod)
          result <- result + sign * term
        }
      }
    }else {
      simpleError("too many dimensions")
      return(NULL)
    }
  }
  
  return(result)
}

# Main simulation function
#' @param answers Data frame containing general assessment answers.
#' @param answers_entry Data frame containing entry pathway specific answers.
#' @param iterations Number of Monte Carlo simulation iterations.
#' @param lambda Shape parameter for the PERT distribution.
#' @param w1 Weight for the first set of impact questions.
#' @param w2 Weight for the second set of impact questions.
#' @return A matrix with simulation results for various risk components.

simulation <- function(answers, answers_entry, pathways, 
                       iterations = 5000, lambda = 1, 
                       w1 = 0.5, w2 = 0.5){
  
  used_pathways <- unique(answers_entry$idpathway)
  # scores <- array(0, dim = c(iterations, length(used_pathways), 2, 3)) #A, B
  # rownames(scores) <- paste0("sim", 1:iterations)
  # colnames(scores) <- paste0("path",used_pathways)
  # dimnames(scores)[[3]] <- c("A", "B")
  # dimnames(scores)[[4]] <- c("1", "2", "3")
  
  scorePathway <- array(0, dim = c(iterations, length(used_pathways), 2)) #A, B
  rownames(scorePathway) <- paste0("sim", 1:iterations)
  colnames(scorePathway) <- paste0("path", used_pathways)
  dimnames(scorePathway)[[3]] <- c("A", "B")

  ENT1 <- rpert_from_tag(answers, tag = "ENT1", iterations, lambda)
  
  # for (p in used_pathways){
  for (up in 1:length(used_pathways)) {
    p <- used_pathways[up]
    g <- pathways |> filter(idPathway == p) |> pull(group)
    ENT2A <- rpert_from_tag(answers_entry |> filter(idpathway == p), tag = "ENT2A", iterations, lambda)
    ENT2B <- rpert_from_tag(answers_entry |> filter(idpathway == p), tag = "ENT2B", iterations, lambda)
    ENT3 <- rpert_from_tag(answers_entry |> filter(idpathway == p), tag = "ENT3", iterations, lambda)
    ENT4 <- rpert_from_tag(answers_entry |> filter(idpathway == p), tag = "ENT4", iterations, lambda)
    
    ENT3A <- ENT3
    
    ## OBS equal is not consider 
    ENT3A <- case_when(
      ENT2A > 2.5 & ENT3 > 0.5 ~ 3,
      ENT2A < 2.5 & ENT2A > 1.5 & ENT3 > 1.5 ~ 3,
      ENT2A < 0.25 ~ 0,
      TRUE ~ ENT3A  # keep original value if no condition is met
    )
    
    # scores[, paste0("path",p), "A", 1] <- ((ENT1 * ENT2A * ENT4) / 27)
    # scores[, paste0("path",p), "A", 2] <- ((ENT2A * ENT4) / 9)
    # scores[, paste0("path",p), "A", 3] <- ((ENT1 * ENT2A * ENT3A * ENT4) / 81)
    # 
    # ## Note make it dependant on pathways "group". Could be simplified 
    # scorePathway[,paste0("path",p), "A"] <- case_when(
    #   g == 1 ~ scores[, paste0("path",p), "A", 3], #((ENT1*ENT2A*ENT3A*ENT4)/81)
    #   g == 2 ~ scores[, paste0("path",p), "A", 1], #((ENT1*ENT2A*ENT4)/27)
    #   g == 3 ~ scores[, paste0("path",p), "A", 2], #((ENT2A*ENT4)/9)
    #   .default = NA # Default case
    # )
    
    ## Dependant on pathways "group" and simplified 
    scorePathway[,paste0("path",p), "A"] <- case_when(
      g == 1 ~ ((ENT1 * ENT2A * ENT3A * ENT4) / 81),
      g == 2 ~ ((ENT1 * ENT2A * ENT4) / 27),
      g == 3 ~ ((ENT2A * ENT4) / 9),
      .default = NA # Default case
    )

    ENT3B <- ENT3
    ENT3B <- case_when(
      ENT2B > 2.5 & ENT3 > 0.5 ~ 3,
      ENT2B < 2.5 & ENT2B > 1.5 & ENT3 > 1.5 ~ 3,
      ENT2B < 0.25 ~ 0,
      TRUE ~ ENT3B  # keep original value if no condition is met
    )
    
    # scores[, paste0("path",p), "B", 1] <- ((ENT1 * ENT2B * ENT4) / 27)
    # scores[, paste0("path",p), "B", 2] <- ((ENT2B * ENT4) / 9)
    # scores[, paste0("path",p), "B", 3] <- ((ENT1 * ENT2B * ENT3B * ENT4) / 81)
    # 
    # ## OBS equal is not consider 
    # scorePathway[,paste0("path",p), "B"] <- case_when(
    #   g == 1 ~ scores[, paste0("path",p), "B", 3], #((ENT1*ENT2A*ENT3A*ENT4)/81)
    #   g == 2 ~ scores[, paste0("path",p), "B", 1], #((ENT1*ENT2A*ENT4)/27)
    #   g == 3 ~ scores[, paste0("path",p), "B", 2], #((ENT2A*ENT4)/9)
    #   .default = NA # Default case
    # )
    
    ## Dependant on pathways "group" and simplified 
    scorePathway[,paste0("path",p), "B"] <- case_when(
      g == 1 ~ ((ENT1 * ENT2B * ENT3B * ENT4) / 81),
      g == 2 ~ ((ENT1 * ENT2B * ENT4) / 27),
      g == 3 ~ ((ENT2B * ENT4) / 9),
      .default = NA # Default case
    )
    
  } # end for pathways

  ENTRYA <- generate_inclusion_exclusion_score(scorePathway[,,"A"])
  ENTRYB <- generate_inclusion_exclusion_score(scorePathway[,,"B"])

  EST1 <- rpert_from_tag(answers, tag = "EST1", iterations, lambda)
  EST2 <- rpert_from_tag(answers, tag = "EST2", iterations, lambda)
  EST3 <- rpert_from_tag(answers, tag = "EST3", iterations, lambda)
  EST4 <- rpert_from_tag(answers, tag = "EST4", iterations, lambda)
  
  
  SPR1 <- case_when(
    EST3 > 2.5 & EST2 > 3.5 ~ 6,
    EST3 > 2.5 & EST2 > 2.5 & EST2 < 3.5 ~ 7,
    EST3 > 2.5 & EST2 > 1.5 & EST2 < 2.5 ~ 8,
    EST3 > 2.5 & EST2 > 0.5 & EST2 < 1.5 ~ 9,
    
    EST3 < 2.5 & EST3 > 1.5 & EST2 > 3.5 ~ 4,
    EST3 < 2.5 & EST3 > 1.5 & EST2 > 2.5 & EST2 < 3.5 ~ 5,
    EST3 < 2.5 & EST3 > 1.5 & EST2 > 1.5 & EST2 < 2.5 ~ 6,
    EST3 < 2.5 & EST3 > 1.5 & EST2 > 0.5 & EST2 < 1.5 ~ 7,
    
    EST3 < 1.5 & EST3 > 0.5 & EST2 > 3.5 ~ 2,
    EST3 < 1.5 & EST3 > 0.5 & EST2 > 2.5 & EST2 < 3.5 ~ 3,
    EST3 < 1.5 & EST3 > 0.5 & EST2 > 1.5 & EST2 < 2.5 ~ 4,
    EST3 < 1.5 & EST3 > 0.5 & EST2 > 0.5 & EST2 < 1.5 ~ 5,
    
    EST3 < 0.5 & EST2 > 2.5 ~ 1,
    EST3 < 0.5 & EST2 > 1.5 & EST2 < 2.5 ~ 2,
    EST3 < 0.5 & EST2 > 0.5 & EST2 < 1.5 ~ 3,
    
    EST2 < 0.5 ~ 0,
    
    TRUE ~ NA_real_  # default case if none match
  )
  
  ESTABLISHMENT <- case_when(
    EST1 < 0.75 ~ 0,
    EST2 < 0.5 ~ 0,
    TRUE ~ (EST1 + SPR1 + EST4) / 21
  )
  
  INVASIONA <- ENTRYA * ESTABLISHMENT
  INVASIONB <- ENTRYB * ESTABLISHMENT
  
  IMP1 <- rpert_from_tag(answers, tag = "IMP1", iterations, lambda)
  IMP2 <- rpert_from_tag(answers, tag = "IMP2", iterations, lambda)
  IMP3 <- rpert_from_tag(answers, tag = "IMP3", iterations, lambda)
  IMP4 <- rpert_from_tag(answers, tag = "IMP4", iterations, lambda)
  
  IMPACT <- ((w1 * (IMP1 + IMP2)) + 
               (w2 * (IMP3 + IMP4))) / 9
  
  RISKA <- IMPACT * INVASIONA
  RISKB <- IMPACT * INVASIONB
  
  MAN1 <- rpert_from_tag(answers, tag = "MAN1", iterations, lambda)
  MAN2 <- rpert_from_tag(answers, tag = "MAN2", iterations, lambda)
  MAN3 <- rpert_from_tag(answers, tag = "MAN3", iterations, lambda)
  MAN4 <- rpert_from_tag(answers, tag = "MAN4", iterations, lambda)
  MAN5 <- rpert_from_tag(answers, tag = "MAN5", iterations, lambda)
  
  # PREVENTABILITY <- pmax(MAN1, MAN2, MAN3)
  # CONTROLLABILITY <- pmax(MAN4, MAN5)
  PREVENTABILITY <- (pmax(MAN1,MAN2,MAN3)/4)
  CONTROLLABILITY <- (pmax(MAN4,MAN5)/4)
  
  
  MANAGEABILITY <- pmin(PREVENTABILITY, CONTROLLABILITY)
  
  SCORE <- cbind(ENTRYA, ENTRYB, ESTABLISHMENT, INVASIONA, INVASIONB, IMPACT, 
                 RISKA, RISKB, PREVENTABILITY, CONTROLLABILITY, MANAGEABILITY)
  return(SCORE)
}
