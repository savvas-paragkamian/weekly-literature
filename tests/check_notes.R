# Grounding check for an assistant's notes file: every [key] must be in the
# week's bibliography files, every URL must appear in provenance/search-log.md
# or be the doi.org address of a key in those files, and "et al." must not
# stand without a key. Exit status 1 on any failure.
# Run from the repository root: Rscript tests/check_notes.R notes/<week>.md
# Self-test (checks that the check can fail): Rscript tests/check_notes.R --self-test

check_notes <- function(notes_path, root = ".") {
  week <- sub("\\.md$", "", basename(notes_path))
  bibs <- file.path(root, "bib", paste0(week, c(".bib", "-consensus.bib")))
  keys <- unlist(lapply(bibs[file.exists(bibs)], function(p) {
    l <- readLines(p, warn = FALSE); sub("^@\\w+\\{([^,]+),", "\\1", grep("^@\\w+\\{", l, value = TRUE)) }))
  dois <- unlist(lapply(bibs[file.exists(bibs)], function(p) {
    l <- readLines(p, warn = FALSE); tolower(sub("^\\s*doi\\s*=\\s*\\{([^}]*)\\},?", "\\1", grep("^\\s*doi\\s*=", l, value = TRUE))) }))
  URL_RE <- "https?://[^[:space:])>|\\]]+"
  find_urls <- function(lines) unique(unlist(regmatches(lines, gregexpr(URL_RE, lines, perl = TRUE))))
  logp <- file.path(root, "provenance", "search-log.md")
  logged <- if (file.exists(logp)) find_urls(readLines(logp, warn = FALSE)) else character()
  body <- readLines(notes_path, warn = FALSE)
  cited <- unique(unlist(regmatches(body, gregexpr("\\[([a-z][a-z0-9]*[0-9]{4}[a-z0-9]+)\\](?!\\()", body, perl = TRUE))))
  cited <- gsub("^\\[|\\]$", "", cited)
  urls <- find_urls(body)
  urls <- sub("[.,;:]+$", "", urls)
  bad_keys <- setdiff(cited, keys)
  doi_urls <- paste0("https://doi.org/", dois)
  bad_urls <- urls[!(urls %in% logged | tolower(urls) %in% doi_urls)]
  etal <- grep("et al\\.", body, value = TRUE)
  etal_bad <- etal[!grepl("\\[[a-z][a-z0-9]*[0-9]{4}[a-z0-9]+\\]", etal, perl = TRUE)]
  problems <- c(if (length(bad_keys)) paste0("key not in the week's bibliography: ", bad_keys),
                if (length(bad_urls)) paste0("URL neither logged nor a verified DOI: ", bad_urls),
                if (length(etal_bad)) paste0("\"et al.\" without a key: ", substr(etal_bad, 1, 80)))
  list(keys = cited, urls = urls, problems = problems)
}

self_test <- function() {
  root <- tempfile("notes-selftest"); dir.create(file.path(root, "bib"), recursive = TRUE); dir.create(file.path(root, "provenance")); dir.create(file.path(root, "notes"))
  writeLines(c("@article{good2026paper,", "  title = {Good},", "  doi = {10.1234/good},", "}"), file.path(root, "bib", "2026-W99.bib"))
  writeLines(c("| 2026-01-01 | topic | query | 1 | https://consensus.app/papers/logged |"), file.path(root, "provenance", "search-log.md"))
  notes <- file.path(root, "notes", "2026-W99.md")
  writeLines(c("A grounded sentence [good2026paper].", "A sentence with a planted bad key [fake2026missing].",
               "A logged link https://consensus.app/papers/logged and a verified DOI https://doi.org/10.1234/good.",
               "A planted unlogged link https://example.org/not-logged.", "Something et al. said this without a key."), notes)
  r <- check_notes(notes, root)
  want <- c("fake2026missing", "https://example.org/not-logged", "et al.")
  caught <- vapply(want, function(w) any(grepl(w, r$problems, fixed = TRUE)), logical(1))
  false_alarm <- any(grepl("good2026paper|consensus.app/papers/logged|doi.org/10.1234/good", r$problems))
  if (all(caught) && !false_alarm && length(r$problems) == 3) { cat("SELF-TEST PASSED: the planted bad key, the unlogged URL and the bare \"et al.\" were caught; the good key, the logged URL and the DOI were not\n"); quit(status = 0) }
  cat("SELF-TEST FAILED\n"); print(r$problems); quit(status = 1)
}

if (!interactive() && sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  if ("--self-test" %in% args) self_test()
  if (length(args) < 1) { cat("usage: Rscript tests/check_notes.R notes/<week>.md\n"); quit(status = 2) }
  r <- check_notes(args[1])
  cat(length(r$keys), "keys cited,", length(r$urls), "URLs,", length(r$problems), "problems\n")
  if (length(r$problems)) { cat(paste0("- ", r$problems), sep = "\n"); quit(status = 1) }
  cat("GROUNDING OK\n")
}
