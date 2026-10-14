# The assistant's only door into a bibliography. Given a DOI and the title the
# assistant saw, resolve the DOI (Crossref, then DataCite), compare the titles,
# and, if they match, append an entry built from the registrar's own metadata to
# bib/<week>-consensus.bib and a row to data/seen.csv. Prints OK <key> or FAIL <reason>.
# Run from the repository root: Rscript R/skill_verify.R <doi> "<title>" [YYYY-WW]
source("R/00_common.R")
source("R/03_check.R")

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) { say("usage: Rscript R/skill_verify.R <doi> \"<title>\" [YYYY-WW]"); quit(status = 2) }
doi <- norm_doi(args[1]); title <- args[2]
week <- if (length(args) >= 3) args[3] else week_label()
cfg <- load_config()

c <- resolve_doi(doi)
if (c$status != "ok") { say("FAIL ", doi, ": ", if (c$status == "unresolved") "DOI does not resolve on Crossref or DataCite" else paste0("registrar unreachable: ", c$error %||% "")); quit(status = 1) }
m <- title_match(title, c$title)
if (!m$ok) { say(sprintf("FAIL %s: %s %s: %s", doi, c$registrar, m$how, c$title)); quit(status = 1) }

SEEN_COLS <- c("uid", "doi", "arxiv_id", "title_norm", "key", "first_seen_week", "last_seen_week", "version", "published_doi", "preprint_of")
seen <- read_csv("data/seen.csv", SEEN_COLS)
i <- which(seen$doi == doi)
if (length(i)) { say("OK ", seen$key[i[1]], " (already in the bibliography, first seen ", seen$first_seen_week[i[1]], ")"); quit(status = 0) }

# build the entry from the registrar's metadata, not from the assistant's text
to_bib_names <- function(v) {
  v <- v[!is.na(v) & nzchar(trimws(v))]
  if (!length(v)) return(NA_character_)
  paste(vapply(v, function(x) {
    x <- trimws(x)
    if (grepl(",", x, fixed = TRUE)) x                          # already "Family, Given"
    else { p <- strsplit(x, " ")[[1]]; if (length(p) > 1) paste0(p[length(p)], ", ", paste(p[-length(p)], collapse = " ")) else x }
  }, character(1)), collapse = " and ")
}
if (c$registrar == "Crossref") {
  rec <- c$record
  authors <- to_bib_names(vapply(rec$author %||% list(), function(a) trimws(paste(a$given %||% "", a$family %||% "")), character(1)))
  parts <- (rec$issued$`date-parts` %||% list(list(NA)))[[1]]
  date <- paste(sprintf("%02d", as.integer(unlist(parts))), collapse = "-"); date <- sub("^0*", "", date)
  venue <- (rec$`container-title` %||% list(NA))[[1]]
  type <- if (identical(rec$type, "posted-content")) "preprint" else "article"
  server <- if (type == "preprint") (venue %||% "preprint server") else NA
  note <- NA
} else {
  a <- c$record
  authors <- to_bib_names(vapply(a$creators %||% list(), function(x) x$name %||% "", character(1)))
  date <- as.character(a$publicationYear %||% NA)
  venue <- a$publisher %||% NA
  type <- "preprint"; server <- venue %||% "DataCite"
  note <- paste0("DataCite record", if (!is.null(a$types$resourceTypeGeneral)) paste0(" (", a$types$resourceTypeGeneral, ")") else "")
}
year <- substr(date, 1, 4)
all_keys <- unique(c(bib_keys_in("bib/all.bib"), bib_keys_in(file.path("bib", paste0(week, "-consensus.bib"))), seen$key[!is.na(seen$key)]))
key <- bib_key(first_surname(authors), year, c$title, all_keys)
r <- list(authors = authors, title = c$title, venue = venue, date = date, doi = doi, arxiv_id = NA, type = type,
          preprint_server = server, url = paste0("https://doi.org/", doi), topics = "consensus", sources = "consensus", note = note)
path <- file.path("bib", paste0(week, "-consensus.bib"))
dir.create("bib", showWarnings = FALSE)
if (!file.exists(path)) writeLines(sprintf("%% Items the assistant found through Consensus in %s, resolved on Crossref or DataCite by R/skill_verify.R.\n", week), path)
cat(paste0("\n", bib_entry(key, r)), file = path, append = TRUE)
seen <- rbind(seen, data.frame(uid = paste0("doi:", doi), doi = doi, arxiv_id = NA, title_norm = norm_title(c$title), key = key,
                               first_seen_week = week, last_seen_week = week, version = NA, published_doi = NA, preprint_of = NA, stringsAsFactors = FALSE))
write_csv(seen[SEEN_COLS], "data/seen.csv")
say(sprintf("OK %s (%s %s; entry appended to %s)", key, c$registrar, m$how, path))
