launch_app <- function(preferred_port = 3838) {
  
  port_in_use <- function(port) {
    tryCatch({
      con <- socketConnection("127.0.0.1", port = port, open = "r+b",
                              blocking = FALSE, timeout = 1)
      close(con)
      TRUE
    }, error = function(e) FALSE)
  }
  
  find_port <- function(start_port) {
    for (port in start_port:(start_port + 100)) {
      if (!port_in_use(port)) {
        message("Using port: ", port)
        return(port)
      } else {
        message("Port ", port, " in use, trying next...")
      }
    }
    stop("No available port found in range ", start_port, " to ", start_port + 100)
  }
  
  port <- tryCatch(
    find_port(preferred_port),
    error = function(e) {
      message("Could not find available port: ", conditionMessage(e))
      stop(e)
    }
  )
  
  message("Starting app on port ", port, "...")
  
  tryCatch({
    
    # Load app exactly as Shiny would — preserves all appearance/theming
    app <- shiny::shinyAppDir('.')
    
    # Extract the server and wrap it to add stop-on-close
    original_server <- app$serverFuncSource()
    
    app$serverFuncSource <- function() {
      function(input, output, session) {
        original_server(input, output, session)
        session$onSessionEnded(function() {
          message("Browser closed — stopping app.")
          shiny::stopApp()
        })
      }
    }
    
    browser_opener <- function(url) {
      sysname <- Sys.info()[["sysname"]]
      tryCatch({
        if (sysname == "Windows") {
          shell(paste0("start \"\" \"", url, "\""), wait = FALSE)
        } else if (sysname == "Darwin") {
          system(paste0("open '", url, "'"), wait = FALSE)
        } else {
          system(paste0("xdg-open '", url, "'"), wait = FALSE)
        }
      }, error = function(e) {
        message("Could not open browser automatically. Navigate to: ", url)
      })
    }
    
    shiny::runApp(
      app,
      port           = port,
      launch.browser = browser_opener,
      host           = "127.0.0.1"
    )
    
  }, error = function(e) {
    message("Failed to start Shiny app: ", conditionMessage(e))
    message("Working directory: ", getwd())
  })
}

launch_app(preferred_port = 3838)