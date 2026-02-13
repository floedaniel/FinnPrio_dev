# Test chromote configuration with Edge
library(chromote)

# Set Edge as the browser
Sys.setenv(CHROMOTE_CHROME = "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe")

# Test if chromote can find the browser
cat("Looking for browser...\n")
browser_path <- find_chrome()
cat("Found browser at:", browser_path, "\n")

# Try to start a session
cat("Starting chromote session...\n")
b <- Chromote$new()
cat("Chromote session started successfully!\n")

# Clean up
b$close()
cat("Session closed.\n")
cat("\nChromote is configured correctly. You can now run app tests.\n")
