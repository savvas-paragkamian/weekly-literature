# Freeze a fetched week for teaching: copy data/raw/<week> to <dest>/data/raw/<week>
# keeping only the raw files of the named topics (plus the bioRxiv category files,
# the cached verification answers and the matching fetch.csv rows), with every
# abstract cut to a fixed number of words and marked as cut. The copy stays
# parseable by R/02_normalise.R, so the week can be rerun offline from a clone.
# Run from the repository root:
#   Rscript R/freeze_week.R <week> <dest> <topic1,topic2,...> [words]
source("R/00_common.R")

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3) { say("usage: Rscript R/freeze_week.R <week> <dest> <topic1,topic2,...> [words]"); quit(status = 2) }
week <- args[1]; dest <- args[2]; topics <- strsplit(args[3], ",", fixed = TRUE)[[1]]
words <- if (length(args) >= 4) as.integer(args[4]) else 40L
MARK <- "[cut to %d words for the workshop copy]"

src <- raw_dir(week)
out <- file.path(dest, "data", "raw", week)
dir.create(out, recursive = TRUE, showWarnings = FALSE)

cut_words <- function(s, n = words) {
  if (is.null(s) || length(s) != 1 || is.na(s) || !nzchar(s)) return(s)
  w <- strsplit(trimws(s), "[[:space:]]+")[[1]]
  if (length(w) <= n) return(s)
  paste(c(w[seq_len(n)], sprintf(MARK, n)), collapse = " ")
}
to_json <- function(x) jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
read_json <- function(p) jsonlite::fromJSON(p, simplifyVector = FALSE)

keep <- function(f) {
  b <- basename(f)
  src_name <- sub("__.*$", "", b)
  topic <- sub("^[a-z]+__(.*)__[0-9]+\\.(json|xml)$", "\\1", b)
  src_name == "biorxiv" || sub("_(pmc|medline|plazi|suppdata)$", "", topic) %in% topics
}

files <- list.files(src, pattern = "^[a-z]+__.*\\.(json|xml)$", full.names = TRUE)
files <- files[vapply(files, keep, logical(1))]
n_cut <- 0L
for (f in files) {
  b <- basename(f); s <- sub("__.*$", "", b); target <- file.path(out, b)
  if (s == "arxiv") {
    x <- xml2::read_xml(f)
    ns <- c(a = "http://www.w3.org/2005/Atom")
    for (node in xml2::xml_find_all(x, ".//a:summary", ns)) {
      t <- xml2::xml_text(node); c2 <- cut_words(t)
      if (!identical(t, c2)) { xml2::xml_text(node) <- c2; n_cut <- n_cut + 1L }
    }
    xml2::write_xml(x, target)
    next
  }
  j <- read_json(f)
  if (s == "europepmc") {
    j$resultList$result <- lapply(j$resultList$result, function(r) {
      c2 <- cut_words(r$abstractText); if (!identical(c2, r$abstractText)) n_cut <<- n_cut + 1L
      r$abstractText <- c2; r })
  } else if (s == "openalex") {
    j$results <- lapply(j$results, function(r) {
      ii <- r$abstract_inverted_index
      if (!is.null(ii) && length(ii)) {
        pos <- lapply(ii, function(p) Filter(function(v) v < words, p))
        pos <- pos[vapply(pos, length, integer(1)) > 0]
        if (length(pos) < length(ii)) { pos[[sprintf(MARK, words)]] <- list(words); n_cut <<- n_cut + 1L }
        r$abstract_inverted_index <- pos
      }
      r })
  } else if (s == "biorxiv") {
    j$collection <- lapply(j$collection, function(r) {
      c2 <- cut_words(r$abstract); if (!identical(c2, r$abstract)) n_cut <<- n_cut + 1L
      r$abstract <- c2; r$jatsxml <- NULL; r })
  } else if (s == "biodivpmc") {
    j$elastic_output$hits$hits <- lapply(j$elastic_output$hits$hits, function(h) {
      c2 <- cut_words(h$`_source`$abstract); if (!identical(c2, h$`_source`$abstract)) n_cut <<- n_cut + 1L
      h$`_source`$abstract <- c2; h$`_source`$annotations <- NULL; h })
  }
  writeLines(to_json(j), target, useBytes = TRUE)
}

# cached verification answers: the arXiv id_list answer carries summaries too
for (extra in c("crossref.json", list.files(src, pattern = "^arxiv-ids(-[0-9]+)?\\.xml$"))) {
  p <- file.path(src, extra)
  if (!file.exists(p)) next
  if (grepl("^arxiv-ids", extra)) {
    x <- xml2::read_xml(p)
    for (node in xml2::xml_find_all(x, ".//a:summary", c(a = "http://www.w3.org/2005/Atom"))) xml2::xml_text(node) <- cut_words(xml2::xml_text(node))
    xml2::write_xml(x, file.path(out, extra))
  } else file.copy(p, file.path(out, extra), overwrite = TRUE)
}
fetch <- read_csv(file.path(src, "fetch.csv"))
if (!is.null(fetch)) {
  base <- sub("_(pmc|medline|plazi|suppdata)$", "", fetch$topic)
  write_csv(fetch[fetch$source == "biorxiv" | base %in% topics, ], file.path(out, "fetch.csv"))
}
writeLines(c(sprintf("# Frozen copy of data/raw/%s, made %s by R/freeze_week.R", week, utc_now()),
             sprintf("Topics kept: %s. Abstracts cut to %d words (%d were cut); bioRxiv JATS and SIBiLS annotations removed.", paste(topics, collapse = ", "), words, n_cut),
             "For teaching: the records are real, the abstracts are excerpts. The full responses are in the source repository's run artifact."),
           file.path(out, "FROZEN.md"))
say(length(files), " raw files copied to ", out, "; ", n_cut, " abstracts cut to ", words, " words")
