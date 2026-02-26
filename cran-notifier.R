#!/usr/bin/env Rscript

# --- Dependencies -----------------------------------------------------------

required_pkgs <- c("foghorn", "jsonlite", "httr2", "rappdirs", "yaml")
missing <- required_pkgs[!vapply(required_pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) {
  if (!requireNamespace("pak", quietly = TRUE)) {
    install.packages("pak")
  }
  pak::pak(missing)
}

# --- Config -----------------------------------------------------------------

script_dir <- dirname(normalizePath(commandArgs(trailingOnly = FALSE)[
  grep("^--file=", commandArgs(trailingOnly = FALSE))
] |> sub("^--file=", "", x = _), mustWork = FALSE))

config_file <- file.path(script_dir, "config.yml")
if (!file.exists(config_file)) {
  stop("config.yml not found. Copy config.yml.example to config.yml and edit it.")
}

config <- yaml::read_yaml(config_file)

ntfy_topic <- config$ntfy_topic %||% stop("ntfy_topic not set in config.yml")
ntfy_token <- config$ntfy_token %||% ""
packages <- config$packages %||% stop("packages not set in config.yml")
if (length(packages) == 0) stop("packages list is empty in config.yml")

# --- State file paths -------------------------------------------------------

state_dir <- rappdirs::user_data_dir("cran-notifier")
state_file <- file.path(state_dir, "state.json")
dir.create(state_dir, recursive = TRUE, showWarnings = FALSE)

# --- Query CRAN incoming ----------------------------------------------------

current <- tryCatch(
  foghorn::cran_incoming(pkg = packages),
  error = function(e) {
    stop("Failed to query CRAN incoming: ", conditionMessage(e))
  }
)

current <- data.frame(
  package = current$package,
  version = as.character(current$version),
  cran_folder = current$cran_folder,
  stringsAsFactors = FALSE
)

# --- Load previous state ----------------------------------------------------

if (file.exists(state_file)) {
  previous <- jsonlite::fromJSON(state_file)
  if (length(previous) == 0) {
    previous <- data.frame(
      package = character(), version = character(),
      cran_folder = character(), stringsAsFactors = FALSE
    )
  }
} else {
  previous <- data.frame(
    package = character(), version = character(),
    cran_folder = character(), stringsAsFactors = FALSE
  )
}

# --- Compute changes --------------------------------------------------------

# key: package + version
current$key <- paste(current$package, current$version)
previous$key <- paste(previous$package, previous$version)

appeared <- current[!current$key %in% previous$key, , drop = FALSE]
disappeared <- previous[!previous$key %in% current$key, , drop = FALSE]

# Moved: same key, different folder
common <- merge(
  current, previous,
  by = "key", suffixes = c("", ".prev")
)
moved <- common[common$cran_folder != common$cran_folder.prev, , drop = FALSE]

# --- Send notifications -----------------------------------------------------

send_notification <- function(title, message, priority = "default", tags = "package") {
  req <- httr2::request(ntfy_topic) |>
    httr2::req_method("POST") |>
    httr2::req_headers(
      Title = title,
      Priority = priority,
      Tags = tags
    ) |>
    httr2::req_body_raw(message, type = "text/plain")

  if (nzchar(ntfy_token)) {
    req <- req |> httr2::req_auth_bearer_token(ntfy_token)
  }

  req |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
}

notify_failed <- FALSE

# Appeared
for (i in seq_len(nrow(appeared))) {
  row <- appeared[i, ]
  message(sprintf("New: %s %s appeared in %s", row$package, row$version, row$cran_folder))
  tryCatch(
    send_notification(
      title = sprintf("CRAN: %s %s", row$package, row$version),
      message = sprintf("Appeared in %s", row$cran_folder),
      tags = "package,new"
    ),
    error = function(e) {
      warning("Failed to send notification: ", conditionMessage(e))
      notify_failed <<- TRUE
    }
  )
}

# Moved
for (i in seq_len(nrow(moved))) {
  row <- moved[i, ]
  from <- row$cran_folder.prev
  to <- row$cran_folder
  message(sprintf("Moved: %s %s from %s to %s", row$package, row$version, from, to))

  if (to == "publish") {
    send_args <- list(
      title = sprintf("CRAN: %s %s", row$package, row$version),
      message = "Moved to publish (pending final publication)",
      priority = "high", tags = "tada"
    )
  } else if (to == "archive") {
    send_args <- list(
      title = sprintf("CRAN: %s %s", row$package, row$version),
      message = "Moved to archive (rejected/withdrawn)",
      priority = "high", tags = "warning"
    )
  } else {
    send_args <- list(
      title = sprintf("CRAN: %s %s", row$package, row$version),
      message = sprintf("Moved from %s to %s", from, to),
      tags = "arrow_right"
    )
  }
  tryCatch(
    do.call(send_notification, send_args),
    error = function(e) {
      warning("Failed to send notification: ", conditionMessage(e))
      notify_failed <<- TRUE
    }
  )
}

# Disappeared
for (i in seq_len(nrow(disappeared))) {
  row <- disappeared[i, ]
  message(sprintf("Gone: %s %s no longer in %s", row$package, row$version, row$cran_folder))

  if (row$cran_folder == "publish") {
    send_args <- list(
      title = sprintf("CRAN: %s %s", row$package, row$version),
      message = "Disappeared from publish \u2014 likely on CRAN now!",
      priority = "high", tags = "rocket"
    )
  } else {
    send_args <- list(
      title = sprintf("CRAN: %s %s", row$package, row$version),
      message = sprintf("No longer in CRAN incoming (was in %s)", row$cran_folder),
      tags = "eyes"
    )
  }
  tryCatch(
    do.call(send_notification, send_args),
    error = function(e) {
      warning("Failed to send notification: ", conditionMessage(e))
      notify_failed <<- TRUE
    }
  )
}

# --- Save state -------------------------------------------------------------

total_changes <- nrow(appeared) + nrow(moved) + nrow(disappeared)

if (notify_failed) {
  stop("State not updated due to notification failures \u2014 will retry next run.")
}

# Save without the key column
current$key <- NULL
jsonlite::write_json(current, state_file, auto_unbox = TRUE, pretty = TRUE)

if (total_changes == 0) {
  message("No changes detected.")
}
