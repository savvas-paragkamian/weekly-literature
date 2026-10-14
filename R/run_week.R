# Run one week end to end and write its provenance log.
# Run from the repository root: Rscript R/run_week.R [YYYY-WW] [--offline]
#   --offline   skip the fetch and read cached verification answers (fixtures, tests)
# Steps: R/01_fetch.R, R/02_normalise.R, R/03_check.R, R/04_write.R, each as its
# own process so that its printed counts are captured verbatim.
source("R/00_common.R")

args <- commandArgs(trailingOnly = TRUE)
week <- week_arg(args)
offline <- has_flag("--offline", args)
# --no-fetch: verify live and write, from raw files an earlier fetch saved
nofetch <- has_flag("--no-fetch", args)
t_start <- Sys.time()

run <- function(script, extra = character()) {
  t0 <- Sys.time()
  out <- suppressWarnings(system2("Rscript", c(script, week, extra), stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status") %||% 0
  list(script = script, output = out, status = status, seconds = round(as.numeric(Sys.time() - t0, units = "secs"), 1))
}

steps <- list()
if (!offline && !nofetch) steps$fetch <- run("R/01_fetch.R")
steps$normalise <- run("R/02_normalise.R")
steps$check <- run("R/03_check.R", if (offline) "--offline")
steps$write <- run("R/04_write.R")

for (s in steps) { say("--- ", s$script, " (", s$seconds, " s, exit ", s$status, ")"); cat(s$output, sep = "\n") }

# --- the log -------------------------------------------------------------------------

# the short commit of the repository, or "none" before the first commit or outside git
git <- function(...) {
  out <- tryCatch(suppressWarnings(system2("git", c(...), stdout = TRUE, stderr = TRUE)), error = function(e) NULL)
  if (is.null(out) || length(out) == 0 || (!is.null(attr(out, "status")) && attr(out, "status") != 0)) "none (no commit)" else out[1]
}
pkgs <- c("httr2", "jsonlite", "yaml", "xml2")
versions <- vapply(pkgs, function(p) as.character(packageVersion(p)), character(1))
fetch <- read_csv(file.path(raw_dir(week), "fetch.csv"))
files <- list.files(raw_dir(week), pattern = "\\.(json|xml)$", full.names = TRUE)
checked <- read_csv(file.path("data", "normalised", paste0(week, "-checked.csv")))

log <- c(sprintf("# Run %s, %s", week, utc_now()), "",
         sprintf("- Host: %s; R %s; %s; renv.lock md5 %s", Sys.info()[["nodename"]], paste(R.version$major, R.version$minor, sep = "."),
                 paste(sprintf("%s %s", pkgs, versions), collapse = ", "), if (file.exists("renv.lock")) md5("renv.lock") else "none"),
         sprintf("- Config: config/interests.yml md5 %s; repository commit %s", md5("config/interests.yml"), git("rev-parse", "--short", "HEAD") %||% "none"),
         sprintf("- Mode: %s", if (offline) "offline (cached verification answers, no fetch)"
                               else if (nofetch) "no fetch this run: raw files from an earlier fetch (times in the table below are that fetch's); identifiers verified live now"
                               else "live"),
         "", "## Fetch", "")
if (!is.null(fetch)) {
  log <- c(log, "| Source | Topic | Query | Pages | Items | Seconds | Status |", "|---|---|---|---|---|---|---|",
           sprintf("| %s | %s | `%s` | %s | %s | %s | %s |", fetch$source, fetch$topic, gsub("\\|", "\\\\|", fetch$query), fetch$pages, fetch$items, fetch$seconds, fetch$status),
           "", "URLs as requested (keys removed):", "", sprintf("- %s", unique(fetch$url)), "")
} else log <- c(log, "No fetch this run.", "")
log <- c(log, "## Raw files", "", "| File | MD5 |", "|---|---|", sprintf("| %s | %s |", basename(files), vapply(files, md5, character(1))), "",
         "## Normalise", "", paste0("    ", steps$normalise$output), "",
         "## Check", "")
if (!is.null(checked)) {
  v <- checked$verified == "TRUE"
  log <- c(log, sprintf("%d items: %d verified, %d not.", nrow(checked), sum(v), sum(!v)), "",
           if (any(!v)) c("Not verified:", "", sprintf("- %s: %s", ifelse(is.na(checked$doi[!v]), checked$arxiv_id[!v] %||% checked$title[!v], checked$doi[!v]), checked$verify_reason[!v]), "") else character())
}
log <- c(log, "## Write", "", paste0("    ", steps$write$output), "",
         "## Failures and retries", "",
         if (!is.null(fetch) && any(grepl("^failed", fetch$status))) sprintf("- %s %s: %s", fetch$source, fetch$topic, fetch$status)[grepl("^failed", fetch$status)] else "- none recorded",
         "", sprintf("Wall time: %.1f s.", as.numeric(Sys.time() - t_start, units = "secs")))
dir.create("provenance", showWarnings = FALSE)
writeLines(log, file.path("provenance", paste0(week, ".log.md")), useBytes = TRUE)
say("\nwrote provenance/", week, ".log.md")
if (any(vapply(steps, function(s) s$status != 0, logical(1)))) { say("a step failed; see above"); quit(status = 1) }
