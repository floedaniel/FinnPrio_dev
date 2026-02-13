navbarPage("FinnPRIO-Assessor",
            tabPanel("Assessments",
                     tabsetPanel(id = "all_assessments",
                        tabPanel(id = "all", value = "all",
                                title = tagList(icon("laptop-file", class = "fas"), "Assessments"),
                                div(class = "card",
                                  fluidPage(
                                    column(10,
                                           h3(strong("All Assessments"), class = "page-heading"),
                                           DTOutput("assessments")
                                           ),
                                    column(2,
                                           # h4(strong("Edit Selected Assessment"), style = "color:#7C6A56"),
                                           # actionButton("edit_ass", "Edit Assessment"),
                                           # br(),
                                           # br(),
                                           h4(strong("Create New Assessment"), class = "page-heading"),
                                           actionButton("new_ass", "Create Assessment"),
                                           br(),
                                           br(),
                                           h4(strong("Export All Assessments"), class = "page-heading"),
                                           downloadButton("export_wide", "Export"),
                                           checkboxInput("exp_all",
                                                         p("Export all assessments",
                                                            tags$span("Otherwise, only valid assessments are exported.",
                                                                   class = "help-text-small"),
                                                         class = "bubble"),
                                                         value = FALSE)
                                           )
                                  )
                                )
                              ), 
                        tabPanel(id = "selected", value = "sel",
                                 title = uiOutput("selectedAssName"),
                                 br(),
                                 fluidRow(
                                   tags$script(
                                   HTML("
                                     $(document).ready(function() {
                                       // Hide button initially
                                       $('#save_answers').hide();

                                       // Function to check if Notes section or below is visible
                                       function checkScrollPosition() {
                                         var notesSection = $('#ass_notes');
                                         if (notesSection.length > 0) {
                                           var notesTop = notesSection.offset().top;
                                           var scrollTop = $(window).scrollTop();
                                           var windowHeight = $(window).height();

                                           // Add offset: show button only after scrolling 800px past Notes section
                                           var offset = 800;
                                           if (scrollTop + windowHeight > notesTop + offset) {
                                             $('#save_answers').fadeIn(300);
                                           } else {
                                             $('#save_answers').fadeOut(300);
                                           }
                                         } else {
                                           // If notes section doesn't exist, keep button hidden
                                           $('#save_answers').hide();
                                         }
                                       }

                                       // Check on scroll
                                       $(window).on('scroll', checkScrollPosition);

                                       // Check on page load
                                       setTimeout(checkScrollPosition, 500);

                                       // Debug: Log when button is clicked
                                       $('#save_answers').on('click', function() {
                                         console.log('Save Answers button clicked!');
                                         console.log('Button element:', this);
                                       });
                                     });
                                   ")
                                   ),
                                   actionButton("save_answers", "Save Answers") #,
                                 ),
                                 uiOutput("questionarie")
                        )
                      )
                    # )
            ),
            tabPanel("Pest-species data",
                    fluidPage(
                      h3(strong("Pest Information"), class = "page-heading"),
                      column(10,
                             DTOutput("pests")
                      ),
                      column(2,
                             actionButton("new_pest", "+ Add Pest"),
                             br(), br(),
                             actionButton("edit_pest", "Edit Selected Pest"),
                             br(), br(),
                             actionButton("delete_pest", "Delete Selected Pest")
                      )
                    )
            ),
            tabPanel("Assessors",
                    fluidPage(
                      h3(strong("Assessor Information"), class = "page-heading"),
                      column(10,
                             DTOutput("assessors_table")
                      ),
                      column(2,
                             actionButton("new_assessor", "+ Add Assessor"),
                             br(), br(),
                             actionButton("edit_assessor", "Edit Selected Assessor"),
                             br(), br(),
                             actionButton("delete_assessor", "Delete Selected Assessor")
                      )
                    )
            ),
            tabPanel("Instructions",
                     fluidPage(
                       includeHTML("www/instructions.html")
                     )
            ),
           header = tagList(
             useShinyjs(), # Initialize shinyjs
             tags$head(
               tags$link(rel = "shortcut icon", href = "./img/bug-slash-solid-full-gray.svg"),
               # Include our custom CSS with cache-busting version parameter
               tags$link(rel = "stylesheet", href = "styles.css?v=38.2")
             ),
             
             fluidRow(
               class = "m-lg",
               div(class = "flex-row",
                   uiOutput("file_input_ui"),
                   uiOutput("db_status")
               ),
                      # uiOutput("file_path_ui") ## in case we want to work with uploading the file
               uiOutput("unload_db_ui")
               # uiOutput("close_app_ui")
               
              )
             ),
           theme = NULL
)
