# Load UI content from a file
load_ui_content <- function(file) {
  source(file, local = TRUE)$value
}

# Capitalize first letter, lowercase next two, keep rest as is
capitalize_first <- function(x) {
  paste0(toupper(substr(x, 1, 1)), 
         tolower(substr(x, 2, 3)), 
         substr(x, 4, nchar(x)))
}


update_options <- function(assessors, pests, taxa, quaran, pathways, session) {
  updateSelectInput(session, "assessors", choices = setNames(c("", assessors$idAssessor), c("", assessors$fullName)))
  updateSelectInput(session, "pest", choices = setNames(c("", pests$idPest), c("", pests$scientificName)))
  updateSelectInput(session, "new_taxa", choices = setNames(taxa$idTaxa, taxa$name))
  updateSelectInput(session, "new_quaran", choices = setNames(quaran$idQuarantineStatus, quaran$name))
  updateCheckboxGroupInput(session, "pot_entry_path", choices = setNames(pathways$idPathway, pathways$name))
  updateSelectInput(session, "assessors", choices = setNames(c("", assessors$idAssessor), c("", assessors$fullName)))
  updateSelectInput(session, "filter_pest", choices = setNames(c("", pests$idPest), c("", pests$scientificName)))
  updateCheckboxGroupInput(session, "filter_entry_path", choices = setNames(pathways$idPathway, pathways$name))
}

# Helper to generate UI for a group
render_group_ui <- function(group_name, threat_groups) {
  group_threats <- threat_groups[[group_name]]
  tagList(
    h5(group_name),
    lapply(1:nrow(group_threats), function(i) {
      radioButtons(
        inputId = paste0("threat_", group_threats$idThrSect[i]),
        label = group_threats$name[i],
        choices = c("None", "Most Likely", "Possible"),
        inline = TRUE
      )
    })
  )
}

render_quest_tab <- function(tag, qid, question, 
                             options, texts, 
                             answers = NULL,
                             type = "minmax"){
  input_names <- glue("{tag}{qid}_{options}")
  input_text <- glue("{tag}{qid}_{texts}")
  values <- c("Minimum", "Likely", "Maximum")
  table_data = matrix(
    values, nrow = length(options), ncol = length(values), byrow = TRUE,
    dimnames = list(input_names, values)
  )
  
  for (i in seq_len(nrow(table_data))) {
    if (!is.null(answers)) {
      is_checked <- answers |> 
        filter(ques_tag_opt == rownames(table_data)[i]) |> 
        select(Minimum, Likely, Maximum) |> 
        as.logical() #new
    } else {
      is_checked <- c(FALSE, FALSE, FALSE)
    }
    
    table_data[i, ] = sprintf(
      '<input type="checkbox" name="%s" value="%s" %s/>', # the last s if for adding 'checked'
      input_names[i], table_data[i, ], ifelse(is_checked, ' checked="checked"', ""))
      # input_names[i], colnames(table_data), ifelse(is_checked, ' checked="checked"', ""))
  }
  
  # Build data frame for DT: group_id (hidden), visible text, then checkboxes
  dt_data <- cbind(group_id = input_names, texts = texts, table_data)
  
  
  # colnames <- if (type == "minmax") {
  #   c("Options", "Minimum", "Likely", "Maximum")
  # } else {
  #   c("Sub-questions, check the box if the answer is Yes", "Minimum", "Likely", "Maximum")
  # }
  
  colnames <- if (type == "minmax") {
    c("group_id", "Options", "Minimum", "Likely", "Maximum")
  } else {
    c("group_id", "Sub-questions, check the box if the answer is Yes", "Minimum", "Likely", "Maximum")
  }
  
  # JavaScript callback: conditional based on type
  # js_callback <- if (type == "minmax") {
  #   JS("
  #     table.rows().every(function(i, tab, row) {
  #       var $this = $(this.node());
  #       $this.attr('id', this.data()[0]);
  #       $this.addClass('shiny-input-checkboxgroup');
  #     });
  # 
  #     Shiny.unbindAll(table.table().node());
  #     Shiny.bindAll(table.table().node());
  # 
  #     var tableId = table.table().node().id || 'table_' + Math.random().toString(36).substr(2, 9);
  #     var limits = { Minimum: 1, Likely: 1, Maximum: 1 };
  # 
  #     $('#' + tableId + ' input[type=checkbox]').off('change').on('change', function() {
  #       var checkbox = this;
  #       var value = checkbox.value;
  # 
  #       var totalChecked = $('#' + tableId + ' input[type=checkbox][value=' + value + ']:checked').length;
  # 
  #       if (totalChecked > limits[value]) {
  #         console.warn('Limit reached for ' + value);
  #         $(checkbox).prop('checked', false);
  #       }
  #     });
  #   ")
  # } else {
  #   JS("
  #     table.rows().every(function(i, tab, row) {
  #       var $this = $(this.node());
  #       $this.attr('id', this.data()[0]);
  #       $this.addClass('shiny-input-checkboxgroup');
  #     });
  # 
  #     Shiny.unbindAll(table.table().node());
  #     Shiny.bindAll(table.table().node());
  #   ")
  # }
  
  
  # JS: set row id = hidden group_id (this makes id == name)
  js_base <- "
    table.rows().every(function() {
      var $row = $(this.node());
      var data = this.data();
      var groupId = data[0]; // hidden first column
      $row.attr('id', groupId);
      $row.addClass('shiny-input-checkboxgroup shiny-input-container');
      // Ensure inner checkboxes have the correct name (if not already)
      $row.find('input[type=checkbox]').attr('name', groupId);
    });

    Shiny.unbindAll(table.table().node());
    Shiny.bindAll(table.table().node());
  "
  
  # Optional: your min/max per column limit logic
  js_limit <- "
    var tableId = table.table().node().id || 'table_' + Math.random().toString(36).substr(2, 9);
    var limits = { Minimum: 1, Likely: 1, Maximum: 1 };
    $('#' + tableId + ' input[type=checkbox]').off('change').on('change', function() {
      var checkbox = this;
      var value = checkbox.value;
      var totalChecked = $('#' + tableId + ' input[type=checkbox][value=' + value + ']:checked').length;
      if (totalChecked > limits[value]) {
        console.warn('Limit reached for ' + value);
        $(checkbox).prop('checked', false).trigger('change');
      }
    });
  "
  
  js_callback <- if (type == "minmax") JS(paste0(js_base, js_limit)) else JS(js_base)
  
  tagList(
    datatable(
      dt_data, #cbind(texts, table_data), #table_data,
      colnames = colnames,
      editable = TRUE,
      escape = FALSE,   # allow HTML rendering
      width = "600px",
      selection = "none", 
      # server = FALSE,
      # rownames = TRUE,
      rownames = FALSE,
      options = list(dom = 't', 
                     paging = FALSE, 
                     autoWidth = FALSE,
                     ordering = FALSE,
                     columnDefs = list(
                       list(width = '50px', targets = c(2,3,4)),
                       list(visible = FALSE, targets = c(0))
                     )
      ),
      callback = js_callback
    ),
    uiOutput(glue("{tag}{qid}_warning"))
  )
}

render_severity_warning <- function(groupTag, answers) {
  severity_map <- c(a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, i = 9,
                    j = 10, k = 11, l = 12, m = 13, n = 14, o = 15, p = 16, q = 17)
  focal_ans <- answers |> 
    filter(question == groupTag) |> 
    select(minimum, likely, maximum) |> 
    unlist()
  
  renderUI({
    req(focal_ans)
    # Ensure names are "min", "likely", "max"
    sev_values <- severity_map[focal_ans]
    names(sev_values) <- c("minimum", "likely", "maximum")

    if (any(is.na(sev_values))) {
      return(
        tags$div(
          class = "error-message",
          "Please ensure that there is one answer for each severity and that 'Minimum' < 'Likely' < 'Maximum'."
        )
      )
    }

    if (length(sev_values) == 3 &&
        sev_values["minimum"] <= sev_values["likely"] &&
        sev_values["likely"] <= sev_values["maximum"]) {
      return(NULL)
    } else {
      return(
        tags$div(
          class = "error-message",
          "Please ensure that 'Minimum' <= 'Likely' <= 'Maximum' in severity."
        )
      )
    }
  })
}

render_severity_boolean_warning <- function(groupTag, answers) {
  focal_ans <- answers |>
    filter(question == groupTag) |>
    select(minimum, likely, maximum) |>
    unlist()

  if(length(focal_ans) == 0){
    return(NULL)
  }

  renderUI({
    # Ensure names are "min", "likely", "max"
    sev_values <- focal_ans
    names(sev_values) <- c("minimum", "likely", "maximum")
    # Conditional dependency checks
    if (all(is.na(sev_values))) {
      return(NULL)
    }

    if (!is.na(sev_values["minimum"]) &&
        (is.na(sev_values["likely"]) || is.na(sev_values["maximum"]))) {
      return(
        tags$div(
          class = "error-message",
          "If 'Minimum' is checked, both 'Likely' and 'Maximum' must also be checked"
        )
      )
    }
    
    if (!is.na(sev_values["likely"]) && is.na(sev_values["maximum"])) {
      return(
        tags$div(
          class = "error-message",
          "If 'Likely' is checked, 'Maximum' must also be checked"
        )
      )
    }
    
  })
}

extract_answers <- function(questions, groupTag, input){
  quesExt <- questions |> filter(group == groupTag)
  id <- quesExt$number
  input_names <- character(0)
  
  for (i in seq(id)) {
    options <- fromJSON(quesExt$list[i])$opt
    input_names <- c(input_names, glue("{groupTag}{id[i]}_{options}"))
  }
  resp <- sapply(input_names, function(i) input[[i]])
  return(resp)
}

extract_answers_entry <- function(questions, groupTag, path, input){
  quesExt <- questions |> filter(group == groupTag)
  id <- quesExt$number
  input_names <- character(0)
  for (i in seq(id)) {
    options <- fromJSON(quesExt$list[i])$opt
    id_p <- paste0(id[i], "_", path)
    for (p in id_p) {
      input_names <- c(input_names, glue("{groupTag}{p}_{options}"))  
    }
  }
  resp <- sapply(input_names, function(i) input[[i]])
  return(resp)
}

get_points_as_table <- function(questions){
  groups <- unique(questions$group)
  # Loop over each group and parse its list column
  points_all <- lapply(groups, function(grp) {
    points <- questions |> 
      filter(group == grp) 

    lapply(seq(1,nrow(points)), function(i) {
      df <- fromJSON(points$list[i])
      df$question <- paste0(grp, points$number[i])
      df$points <- as.character(df$points)
      df
    }) |> bind_rows()
  }) |> bind_rows()
  
  # Final formatting
  points_all <- points_all |> 
    rename(Question = question, 
           Option = opt, 
           Text = text, 
           Points = points)
  
  return(points_all)
}

get_table2_points <- function(ent2_answer, ent3_answer, table2) {
  table2 |> 
    filter(ENT2 == tolower(ent2_answer),
           ENT3 == tolower(ent3_answer)) |> 
    pull(Points)
}

get_table3_points <- function(est2_answer, est3_answer, table3) {
  table3 |> 
    filter(EST2 == tolower(est2_answer),
           EST3 == tolower(est3_answer)) |> 
    pull(Points)
}

get_inputs_as_df <- function(answers, input){ ##, points_main
  df <- tibble(
    name = names(answers),
    question = sub("_.*", "", names(answers)),
    option = sub(".*_", "", names(answers)),
    answer = answers
  ) |>
    unnest(cols = c(answer))  # This expands each vector into separate rows
  
  if (nrow(df) == 0) {
    final_opt <- data.frame(question = NA, 
                            minimum = NA, 
                            likely = NA, 
                            maximum = NA)
  } else {
    final_opt <- df |> 
      select(question, answer, option) |> 
      pivot_wider(names_from = answer, values_from = option) |> 
      rename_with(tolower) |> 
      as.data.frame()
    
      # Ensure "min", "lik", and "max" columns exist
      required_cols <- c("minimum", "likely", "maximum")
      missing_cols <- setdiff(required_cols, names(final_opt))
      if (length(missing_cols) > 0) {
        for (col in missing_cols) {
          final_opt[[col]] <- NA  # Add missing columns with NA
        }
      }
  }
    
  # Extract justifications
  input_names_just <- names(input)[grepl("^just", names(input))]
  # Remove justifications for ENT Paths as they are not collected here
  # Use grepl (logical) instead of grep (integer) to avoid empty vector issue
  input_names_just <- input_names_just[!grepl("_", input_names_just)]
  respJust <- sapply(input_names_just, function(i) input[[i]])


  # Create a full justification dataframe
  just_df <- tibble(
    question = toupper(sub("^just", "", input_names_just)),
    justification = unname(respJust)
  )

  if(nrow(just_df) > 0){
  # Merge with final_opt to include all justifications
  final_opt <- full_join(final_opt, just_df, by = "question")
  } else {
    final_opt$justification <- NA
  }

  final_opt <- final_opt |>
    filter(!is.na(question)) |>
    filter(
      # Keep if ANY checkbox is ticked
      !is.na(minimum) | !is.na(likely) | !is.na(maximum) |
      # OR keep if justification has meaningful content (not just whitespace)
      (!is.na(justification) & trimws(justification) != "")
    )
  return(final_opt)
}


get_inputs_path_as_df <- function(answers, input){ ## , points_path
  df <- tibble(
    name = names(answers),
    question = sub("_.*", "", names(answers)),
    path = lapply(str_split(names(answers), "_"), function(x) x[2]) |> unlist(),
    option = sub(".*_", "", names(answers)) |> tolower(),
    answer = answers
  ) |>
    unnest(cols = c(answer))  # This expands each vector into separate rows

  if (nrow(df) == 0) {
    final_opt <- data.frame(question = NA, 
                            path = NA,
                            minimum = NA, 
                            likely = NA, 
                            maximum = NA)
  } else {
    final_opt <- df |> 
      select(path, question, answer, option) |> 
      pivot_wider(names_from = answer, values_from = option) |> 
      rename_with(tolower) |> 
      as.data.frame()
    
    # Ensure "min", "lik", and "max" columns exist
    required_cols <- c("minimum", "likely", "maximum")
    missing_cols <- setdiff(required_cols, names(final_opt))
    if (length(missing_cols) > 0) {
      for (col in missing_cols) {
        final_opt[[col]] <- NA  # Add missing columns with NA
      }
    }
  }

  input_names_just <- names(input)[grepl("^justENT", names(input))]
  # Remove justifications for ENT1 as they are not collected
  input_names_just <- input_names_just[-grep("ENT1",input_names_just)]  
  respJust <- sapply(input_names_just, function(i) input[[i]])
  
  # Create a full justification dataframe
  questions <- lapply(str_split(input_names_just, "_"), function(x) x[1]) |> 
    unlist()
  questions <- sub("^just", "", questions) |> 
    toupper()

  just_df <- tibble(
    question = questions,
    path = lapply(str_split(input_names_just, "_"), function(x) x[2]) |> unlist(),
    justification = unname(respJust)
  )
  
  # Merge with final_opt to include all justifications
  final_opt <- full_join(final_opt, just_df, by = c("question","path"))
  
  # remove path = na, keep rows with checkbox answers OR justification content
  final_opt <- final_opt |>
    filter(!is.na(path)) |>
    filter(
      # Keep if ANY checkbox is ticked
      !is.na(minimum) | !is.na(likely) | !is.na(maximum) |
      # OR keep if justification has meaningful content
      (!is.na(justification) & trimws(justification) != "")
    )

  return(final_opt)
}


answers_2_logical <- function(df, questions) {
  
    if (nrow(df) > 0) {
    result <- data.frame()
    
    for (i in seq_len(nrow(df))) {
      wQues <- questions |> 
        filter(idQuestion == df$idQuestion[i])
      question_tag <- paste0(wQues$group, wQues$number)
      df$question_tag[i] <- question_tag
      
      row <- df[i, ]
      options <- unique(c(row$min, row$likely, row$max)) |> 
        na.omit()
      
      for (opt in options) {
        result <- rbind(result, data.frame(
          question_tag = row$question_tag,
          option = opt,
          ques_tag_opt = paste0(row$question_tag, "_", opt),
          Minimum = opt == row$min,
          Likely = opt == row$likely,
          Maximum = opt == row$max,
          stringsAsFactors = FALSE
        ))
      }
    }
  } else {
    result <- NULL
  }
  
  return(result)
}

answers_path_2_logical <- function(df, questions) {
  if (nrow(df) > 0) {
    result <- data.frame()
    
    for (i in seq_len(nrow(df))) {
      wQues <- questions |> 
        filter(idPathQuestion == df$idPathQuestion[i])
      question_tag <- paste0(wQues$group, wQues$number, "_", df$idPathway[i])
      df$question_tag[i] <- question_tag
      
      row <- df[i, ]
      options <- unique(c(row$min, row$likely, row$max))
      
      for (opt in options) {
        result <- rbind(result, data.frame(
          question_tag = row$question_tag,
          option = opt,
          ques_tag_opt = paste0(row$question_tag, "_", opt),
          Minimum = opt == row$min,
          Likely = opt == row$likely,
          Maximum = opt == row$max,
          stringsAsFactors = FALSE
        ))
      }
    }
  } else {
    result <- NULL
  }
  
  return(result)
}

check_minmax_completeness <- function(df, all = FALSE) {
  
  if (!all) {
    # Filter rows where type is 'minmax'
    minmax_rows <- df[df$type == "minmax", ]
  } else {
    minmax_rows <- df
  }
  # Check for missing values in min, likely, or max
  incomplete <- minmax_rows[is.na(minmax_rows$min) | is.na(minmax_rows$likely) | is.na(minmax_rows$max), ]

  # Return result
  if (nrow(incomplete) == 0) {
    # message("✅ All 'minmax' rows are complete.")
    return(TRUE)
  } else {
    # message("❌ Incomplete 'minmax' rows found:")
    shinyalert("title" = "Incomplete assessment rows found",
               "text" = paste("Please complete the following questions:", 
                              paste(incomplete$question, collapse = ", "), sep = "<br>"),
               type = "error", html = TRUE)
    # print(incomplete)
    return(FALSE)
  }
}


export_wide_table <- function(connection, only_one = TRUE) {
  
  assessments <- dbGetQuery(connection, assessments_wide_sql)
  if (only_one) {
    assessments <- assessments |> 
      group_by(scientificName) |>
      arrange(desc(valid), desc(endDate)) |>   # valid first, then latest date
      slice(1) |>                              # pick the top row per group
      ungroup()
  }
  
  # Make answers wide
  answers <- dbGetQuery(connection, answers_sql) |> 
    mutate(question_tag = paste0(group, number)) |> 
    select(idAssessment, question_tag, min, likely, max, justification) |> 
    pivot_wider(names_from = question_tag, 
                values_from = c(min, likely, max, justification),
                names_glue = "{question_tag}_{.value}")
  
  # Make answers_entry wide
  answers_entry <- dbGetQuery(connection, answers_entry_sql) |> 
    mutate(question_tag = paste0(group, number)) |> 
    select(idAssessment, idEntryPathway, question_tag, min, likely, max, justification) |> 
    pivot_wider(names_from = question_tag, 
                values_from = c(min, likely, max, justification),
                names_glue = "{question_tag}_{.value}")
  answers_entry_uw <- answers_entry |> 
    group_by(idAssessment) |>
    mutate(PW_count = row_number()) |> 
    filter(PW_count <= 5) |> 
    # as.data.frame() |> 
    select(-idEntryPathway) |> 
    pivot_wider(names_from = PW_count,
                values_from = starts_with("ENT"),
                names_glue = "{.value}_PW{PW_count}")

  # Make Simulations wide
  simulations <- dbGetQuery(connection, simulations_sql) |> 
    select(-idSimulation) |> 
    mutate(date = as.Date(date)) |>
    pivot_wider(names_from = variable, 
                values_from = c(min, q5, q25, median, mean, q75, q95, max),
                names_glue = "SIM_{variable}_{.value}") |> 
    rename("SIM_iterations" = iterations,
           "SIM_lambda" = lambda,
           "SIM_weight1" = weight1,
           "SIM_weight2" = weight2,
           "SIM_date" = date)

  wide_data <- assessments |> 
    left_join(answers, by = "idAssessment") |>
    left_join(answers_entry_uw, by = "idAssessment") |>
    left_join(simulations, by = "idAssessment")
  
  return(wide_data)
}

report_assessment <- function(connection, assessments_selected, questions_main, answers_main, 
                              assessments_entry, questions_entry, answers_entry, simulations) {
  
  answers_logical <- answers_2_logical(answers_main, questions_main)
  
  quaran <- dbGetQuery(connection, glue("SELECT name FROM quarantineStatus
                                     WHERE idQuarantineStatus = {as.integer(assessments_selected$idQuarantineStatus)}"))
  taxa <- dbGetQuery(connection, glue("SELECT name FROM taxonomicGroups
                                     WHERE idTaxa = {as.integer(assessments_selected$idTaxa)}"))
  threatsXassessment <- dbGetQuery(connection, glue("SELECT name 
                                              FROM threatXassessment
                                              LEFT JOIN threatenedSectors
                                                  ON threatXassessment.idThrSect = threatenedSectors.idThrSect
                                              WHERE idAssessment = {assessments_selected$idAssessment}"))

  ids_ent <- as.integer(names(assessments_entry)) |> unique() |> na.omit()
  entries <- dbGetQuery(connection, glue_sql("SELECT idPathway, name FROM pathways WHERE idPathway IN ({ids*})", 
                                             ids = ids_ent, .con = connection))
  
  simulations <- simulations |> 
    filter(idAssessment == assessments_selected$idAssessment)
  
  # Document parts

  # Create Word document
  doc <- read_docx(path = "www/template.docx")
  doc <- doc |>
    body_add_fpar(
      fpar( "FinnPRIO assessment for ",
            ftext(assessments_selected$scientificName, fp_text_lite(italic = TRUE))
            ), style = "heading 1") |>
    body_add_fpar(
      fpar( ftext("Datum: ", fp_text_lite(bold = TRUE)),
            ftext(assessments_selected$endDate)) ) |>
    body_add_par("") |>
    body_add_fpar(
      fpar( ftext("Pest: ", fp_text_lite(bold = TRUE)),
            ftext(assessments_selected$scientificName, fp_text_lite(italic = TRUE))) ) |>
    body_add_fpar(
      fpar( ftext("EPPO Code: ", fp_text_lite(bold = TRUE)),
            assessments_selected$eppoCode) ) |>
    body_add_fpar(
      fpar( ftext("Common name: ", fp_text_lite(bold = TRUE)),
            assessments_selected$vernacularName) ) |>
    body_add_fpar(
      fpar( ftext("Synonyms: ", fp_text_lite(bold = TRUE)),
            assessments_selected$synonyms) ) |>
    body_add_par("") |> 
    body_add_fpar(
      fpar( ftext("Name of Assessors: ", fp_text_lite(bold = TRUE)),
            assessments_selected$fullName)
    ) |>
    body_add_par("") |>
    body_add_fpar(
      fpar( ftext("Taxonomic Group: ", fp_text_lite(bold = TRUE)),
            taxa$name)
    ) |>
    body_add_par("") |>
    body_add_fpar(
      fpar( ftext("Quarantine status in the PRA area: ", fp_text_lite(bold = TRUE)),
            quaran$name)
    ) |>
    body_add_par("") |>
    body_add_fpar(
      fpar( ftext("Notes: ", fp_text_lite(bold = TRUE)),
            assessments_selected$notes)
    ) |>  
    body_add_par("") |>
    body_add_fpar(
      fpar( ftext("Host plants: ", fp_text_lite(bold = TRUE)),
            assessments_selected$hosts)
    ) |> 
    body_add_par("") |>
    body_add_fpar(
      fpar( ftext("Threathened sectors: ", fp_text_lite(bold = TRUE)),
            paste0(threatsXassessment$name, collapse = ", "))
    ) |>
    body_add_par("") |>
    body_add_fpar(
      fpar( ftext("Entry pathways: ", fp_text_lite(bold = TRUE)),
            paste0(entries$name, collapse = ", ") )
    ) |>
    body_add_fpar(
      fpar( ftext(assessments_selected$potentialEntryPathways) )
    ) |>
    body_add_break() |> 
    body_add_par("Assessments", style = "heading 2") |>
    body_add_par("")
    # body_add_fpar(intro_text) |> 

  ## entry
  doc <- body_add_par(doc, "Entry", style = "heading 3")
  doc <- add_answers_to_report(doc, "ENT", questions_main, answers_main, answers_logical)
  ## entrypathways
  for (path in ids_ent) {
    name <- entries$name[entries$idPathway == as.integer(path)]
    answers_path <- answers_entry |> filter(idPathway == as.integer(path))
    answers_path_logical <- answers_path_2_logical(answers_path, questions_entry)
    doc <- doc |> 
      body_add_par(paste0("Entry Pathway: ", name), style = "heading 4")
    doc <- add_answers_path_to_report(doc, "ENT", questions_entry, 
                                      answers_path, answers_path_logical)
  }
  
  ## establishment
  doc <- doc |> 
    body_add_break() |> 
    body_add_par("Establishment and Spread", style = "heading 3")
  doc <- add_answers_to_report(doc, "EST", questions_main, answers_main, answers_logical)

  ## impact
  doc <- doc |> 
    body_add_break() |> 
    body_add_par("Impact", style = "heading 3")
  doc <- add_answers_to_report(doc, "IMP", questions_main, answers_main, answers_logical)
  
  ## Management
  doc <- doc |> 
    body_add_break() |> 
    body_add_par("Management", style = "heading 3")
  doc <- add_answers_to_report(doc, "MAN", questions_main, answers_main, answers_logical)
  
  # reference
  doc <- doc |>
    body_add_break() |> 
    body_add_par("References", style = "heading 3") |>
    body_add_par(assessments_selected$reference)
  
  # Save file
  file_path <- tempfile(fileext = ".docx")
  print(doc, target = file_path)
  return(file_path)
}

add_answers_to_report <- function(doc, tag, questions_main, answers_main, answers_logical) {
  quest <- questions_main |> 
    filter(group == tag) |> 
    arrange(number)
  
  for(x in 1:nrow(quest)) {

    question <- quest$question[x]
    options <- quest$list[x]
    id <- quest$number[x]
    q_tag <- paste0(tag, quest$number[x])
    just <- answers_main |> 
      filter(idQuestion == quest$idQuestion[x]) |> 
      pull(justification) 

    opt <- fromJSON(options)$opt
    text <- fromJSON(options)$text
    answers_quest <- answers_logical |> 
      filter(question_tag == q_tag)
    
    missing_opts <- setdiff(opt, answers_quest$option)
    
    if(length(missing_opts) > 0) {
      # Create rows for missing options
      new_rows <- data.frame(
        question_tag = q_tag,
        option = missing_opts,
        ques_tag_opt = paste0(q_tag, "_", missing_opts),
        Minimum = FALSE,
        Likely = FALSE,
        Maximum = FALSE
      )
      answers_quest <- bind_rows(answers_quest, new_rows) |> 
        arrange(option)
    }
    
    # Create lookup table to match option codes with their text descriptions
    option_lookup <- data.frame(option = opt, option_text = text, stringsAsFactors = FALSE)
    answers_quest <- answers_quest |>
      left_join(option_lookup, by = "option")

    if (quest$type[x] == "minmax") {
      answers_quest <- answers_quest |>
        mutate(Option = paste0(option, ": ", option_text),
               Minimum = ifelse(Minimum, "X", ""),
               Likely = ifelse(Likely, "X", ""),
               Maximum = ifelse(Maximum, "X", "")) |>
        select(Option, Minimum, Likely, Maximum)
    } else {
      answers_quest <- answers_quest |>
        mutate(Option = option_text,
               Minimum = ifelse(!is.na(Minimum),
                                ifelse(Minimum, "YES", "NO"),
                                "NO"),
               Likely = ifelse(!is.na(Likely),
                               ifelse(Likely, "YES", "NO"),
                               "NO"),
               Maximum = ifelse(!is.na(Maximum),
                                ifelse(Maximum, "YES", "NO"),
                                "NO")) |>
        select(Option, Minimum, Likely, Maximum)
    }

    doc <- doc |> 
      body_add_fpar(
        fpar(
          ftext(paste0(q_tag, ": "), prop = fp_text(bold = TRUE, font.size = 12)),
          ftext(question, prop = fp_text(font.size = 12))
        )) |> 
      body_add_flextable(
        flextable(answers_quest,
                  cwidth = 1.5) |> 
          align(j = c("Minimum", "Likely", "Maximum"), 
                align = "center", part = "body")
      ) |>
      body_add_par(paste0("Justification: ", just), style = "Normal") |> 
      body_add_par("")
  } 

  return(doc)
}

add_answers_path_to_report <- function(doc, tag, questions_entry, 
                                       answers_entry, answers_logical) {
  quest <- questions_entry |> 
    filter(group == tag) |> 
    arrange(number)

  id_path <- unique(answers_entry$idPathway)
  
  for(x in 1:nrow(quest)) {
    question <- quest$question[x]
    options <- quest$list[x]
    id <- quest$number[x]
    q_tag <- paste0(tag, id, "_", id_path)
    just <- answers_entry |> 
      filter(idPathQuestion  == quest$idPathQuestion[x]) |> 
      pull(justification)
    opt <- fromJSON(options)$opt
    text <- fromJSON(options)$text
    answers_quest <- answers_logical |> 
      filter(question_tag == q_tag)
    
    missing_opts <- setdiff(opt, answers_quest$option)

    if(length(missing_opts) > 0) {
      # Create rows for missing options
      new_rows <- data.frame(
        question_tag = q_tag,
        option = missing_opts,
        ques_tag_opt = paste0(q_tag, "_", id_path, "_",  missing_opts),
        Minimum = FALSE,
        Likely = FALSE,
        Maximum = FALSE
      )
      answers_quest <- bind_rows(answers_quest, new_rows) |>
        arrange(option)
    }

    # Create lookup table to match option codes with their text descriptions
    option_lookup <- data.frame(option = opt, option_text = text, stringsAsFactors = FALSE)
    answers_quest <- answers_quest |>
      left_join(option_lookup, by = "option") |>
      mutate(Option = paste0(option, ": ", option_text),
             Minimum = ifelse(Minimum, "X", ""),
             Likely = ifelse(Likely, "X", ""),
             Maximum = ifelse(Maximum, "X", "")) |>
      select(Option, Minimum, Likely, Maximum)  
    
    doc <- doc |> 
      body_add_fpar(
        fpar(
          ftext(paste0(tag, id, ": "), prop = fp_text(bold = TRUE, font.size = 12)),
          ftext(question, prop = fp_text(font.size = 12))
        )) |> 
      body_add_flextable(
        flextable(answers_quest,
                  cwidth = 1.5) |> 
          align(j = c("Minimum", "Likely", "Maximum"), 
                align = "center", part = "body")
      ) |>
      body_add_par(paste0("Justification: ", just), style = "Normal") |> 
      body_add_par("")
  } 
  
  return(doc)
}


## Remove all inputs for a given prefix
remove_inputs_by_prefix <- function(input, prefix, session) {
  input_names <- names(input)
  to_remove <- input_names[grepl(prefix, input_names)]
  for (name in to_remove) {
    removeUI(glue("div:has(> #{name}"), immediate = TRUE, session = session)
  }
}
