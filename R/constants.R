if (.Platform$OS.type == "windows") {
  named_paths <- tryCatch({
    sysdrive <- system("wmic logicaldisk get name", intern = TRUE)
    drives <- substr(sysdrive[-c(1, length(sysdrive))], 1, 1)
    drives <- drives[nchar(drives) > 0]  # Remove empty strings
    setNames(paste0(drives, ":/"), paste0(drives, ":"))
  }, error = function(e) {
    # Fallback if wmic fails (deprecated in Windows 11+)
    c("C:" = "C:/")
  })
} else {
  named_paths <- c(Root = "/")
}

volumes <- c("Working Directory" = getwd(),
             Home = fs::path_home(),
             named_paths,
             "My Computer" = "/")

limits <- list(Minimum = 1, Likely = 1, Maximum = 1)
default_sim <- list(n_sim = 50000, seed = 1234, lambda = 1, w1 = 0.5, w2 = 0.5)