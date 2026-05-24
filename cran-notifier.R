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

script_dir <- commandArgs(trailingOnly = FALSE) |>
  grep("^--file=", x = _, value = TRUE) |>
  sub("^--file=", "", x = _) |>
  normalizePath(mustWork = FALSE) |>
  dirname()

config_file <- file.path(script_dir, "config.yml")
if (!file.exists(config_file)) {
  stop("config.yml not found. Copy config.yml.example to config.yml and edit it.")
}

config <- yaml::read_yaml(config_file)

pushover_token <- config$pushover_token %||% stop("pushover_token not set in config.yml")
pushover_user  <- config$pushover_user  %||% stop("pushover_user not set in config.yml")
packages       <- config$packages       %||% stop("packages not set in config.yml")
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

cran_url <- function(pkg) {
  sprintf("https://cran.r-project.org/package=%s", pkg)
}

# Map ntfy-style priority strings to Pushover integer priorities so the
# call sites below can keep their human-readable labels.
pushover_priority <- function(label) {
  switch(label,
         min     = -2L,
         low     = -1L,
         default =  0L,
         high    =  1L,
         max     =  2L,
         0L)
}

# Map the old ntfy emoji-tag names to literal emoji we prefix on the title,
# since Pushover has no tags/emoji-rendering layer.
emoji_for_tag <- function(tag) {
  switch(tag,
         "package,new"  = "\U0001F4E6",  # package
         "arrow_right"  = "➡",      # rightwards arrow
         "tada"         = "\U0001F389",  # party popper
         "warning"      = "⚠",      # warning sign
         "rocket"       = "\U0001F680",  # rocket
         "eyes"         = "\U0001F440",  # eyes
         "")
}

send_notification <- function(title, message, priority = "default", tags = "",
                              click = NULL) {
  emoji <- emoji_for_tag(tags)
  if (nzchar(emoji)) {
    title <- paste(emoji, title)
  }

  fields <- list(
    token    = pushover_token,
    user     = pushover_user,
    title    = title,
    message  = message,
    priority = as.integer(pushover_priority(priority))
  )
  if (!is.null(click)) {
    fields$url <- click
    fields$url_title <- "Open on CRAN"
  }

  httr2::request("https://api.pushover.net/1/messages.json") |>
    httr2::req_method("POST") |>
    httr2::req_body_form(!!!fields) |>
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
      tags = "package,new",
      click = cran_url(row$package)
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
      priority = "high", tags = "tada",
      click = cran_url(row$package)
    )
  } else if (to == "archive") {
    send_args <- list(
      title = sprintf("CRAN: %s %s", row$package, row$version),
      message = "Moved to archive (rejected/withdrawn)",
      priority = "high", tags = "warning",
      click = cran_url(row$package)
    )
  } else {
    send_args <- list(
      title = sprintf("CRAN: %s %s", row$package, row$version),
      message = sprintf("Moved from %s to %s", from, to),
      tags = "arrow_right",
      click = cran_url(row$package)
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
      message = "Disappeared from publish — likely on CRAN now!",
      priority = "high", tags = "rocket",
      click = cran_url(row$package)
    )
  } else {
    send_args <- list(
      title = sprintf("CRAN: %s %s", row$package, row$version),
      message = sprintf("No longer in CRAN incoming (was in %s)", row$cran_folder),
      tags = "eyes",
      click = cran_url(row$package)
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
  stop("State not updated due to notification failures — will retry next run.")
}

# Save without the key column
current$key <- NULL
jsonlite::write_json(current, state_file, auto_unbox = TRUE, pretty = TRUE)

if (total_changes == 0) {
  message("No changes detected.")
}
