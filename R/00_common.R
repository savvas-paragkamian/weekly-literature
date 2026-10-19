# Shared helpers for the weekly literature review: config, week windows, HTTP,
# parsers for the raw files of each source, normalisers and a BibTeX writer.
# Sourced by every script. Run the scripts from the repository root.
suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(yaml)
  library(xml2)
})

VERSION <- "0.1"

`%||%` <- function(a, b) {
  if (is.null(a) || length(a) == 0) return(b)
  if (length(a) == 1 && (is.na(a) || identical(a, ""))) return(b)
  a
}

# --- config and dates -------------------------------------------------------

load_config <- function(path = "config/interests.yml") yaml::read_yaml(path)

week_label <- function(date = Sys.Date() - 1) format(as.Date(date), "%G-W%V")

# Monday of an ISO week, computed by hand: %G and %V are output-only in strptime.
week_monday <- function(label) {
  y <- as.integer(substr(label, 1, 4))
  w <- as.integer(substr(label, 7, 8))
  jan4 <- as.Date(sprintf("%d-01-04", y))
  wday <- as.integer(format(jan4, "%u"))          # 1 = Monday
  jan4 - (wday - 1) + (w - 1) * 7
}

week_window <- function(label, overlap_days = 0) {
  mon <- week_monday(label)
  list(label = label, monday = mon, from = mon - overlap_days, to = mon + 6)
}

# The week argument of a script: the first non-flag argument, else last week.
week_arg <- function(args = commandArgs(trailingOnly = TRUE)) {
  a <- args[!startsWith(args, "--")]
  if (length(a) == 0) return(week_label())
  if (!grepl("^[0-9]{4}-W[0-9]{2}$", a[1])) stop("week must look like 2026-W42, got: ", a[1])
  a[1]
}

has_flag <- function(flag, args = commandArgs(trailingOnly = TRUE)) flag %in% args

# --- HTTP --------------------------------------------------------------------

user_agent <- function(cfg) sprintf("weekly-literature/%s (mailto:%s)", VERSION, cfg$contact)

client <- function(url, cfg) {
  httr2::request(url) |>
    httr2::req_user_agent(user_agent(cfg)) |>
    httr2::req_timeout(90) |>
    # a Retry-After of more than a minute (OpenAlex sends hours when a daily
    # budget is spent) is not waited for: back off three times, then give up
    httr2::req_retry(max_tries = 4, max_seconds = 240, backoff = function(i) 10 * i,
                     after = function(resp) { ra <- httr2::resp_retry_after(resp); if (is.na(ra) || ra > 60) NA else ra },
                     is_transient = function(resp) httr2::resp_status(resp) %in% c(408, 429, 500, 502, 503, 504)) |>
    httr2::req_error(is_error = function(resp) FALSE)
}

# Perform a request; return list(status, text, url). Never throws.
perform <- function(req) {
  resp <- tryCatch(httr2::req_perform(req), error = function(e) e)
  if (inherits(resp, "error")) {
    return(list(status = NA_integer_, text = NA_character_, url = req$url, error = conditionMessage(resp)))
  }
  list(status = httr2::resp_status(resp), text = httr2::resp_body_string(resp), url = req$url, error = NA_character_)
}

# A raw file name: <source>__<topic>__<page>.<ext>; "__" so hyphens in topics survive.
raw_dir <- function(week) {
  d <- file.path("data", "raw", week)
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  d
}

raw_path <- function(week, source, topic, page, ext) {
  file.path(raw_dir(week), sprintf("%s__%s__%02d.%s", source, topic, page, ext))
}

save_raw <- function(text, path) {
  writeLines(text, path, useBytes = TRUE)
  path
}

parse_raw_name <- function(path) {
  b <- sub("\\.[a-z]+$", "", basename(path))
  p <- strsplit(b, "__", fixed = TRUE)[[1]]
  list(source = p[1], topic = p[2], page = as.integer(p[3]), ext = sub("^.*\\.", "", basename(path)))
}

# --- normalisers ---------------------------------------------------------------

to_ascii <- function(x) {
  y <- iconv(x, from = "UTF-8", to = "ASCII//TRANSLIT", sub = "")
  y[is.na(y)] <- iconv(x[is.na(y)], to = "ASCII", sub = "")
  y
}

norm_title <- function(x) {
  x <- to_ascii(x)
  x <- tolower(x)
  x <- gsub("[^a-z0-9]+", " ", x)
  trimws(x)
}

norm_doi <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- sub("^https?://(dx\\.)?doi\\.org/", "", x)
  x <- sub("^doi:\\s*", "", x)
  x[is.na(x) | x == ""] <- NA_character_
  x
}

arxiv_from_doi <- function(doi) {
  ifelse(!is.na(doi) & grepl("^10\\.48550/arxiv\\.", doi), sub("^10\\.48550/arxiv\\.", "", doi), NA_character_)
}

strip_version <- function(id) sub("v[0-9]+$", "", id)

excerpt <- function(x, words = 60) {
  x <- gsub("<[^>]+>", " ", x %||% "")
  x <- gsub("\\s+", " ", trimws(x))
  w <- strsplit(x, " ")[[1]]
  if (length(w) <= words) return(x)
  paste0(paste(w[seq_len(words)], collapse = " "), " ...")
}

# "Given Surname" -> "Surname, Given"; "Surname I." stays. Returns one string.
author_bib <- function(names) {
  names <- names[!is.na(names) & names != ""]
  if (length(names) == 0) return(NA_character_)
  out <- vapply(names, function(n) {
    n <- trimws(n)
    if (grepl(",", n)) return(n)
    p <- strsplit(n, "\\s+")[[1]]
    if (length(p) == 1) return(n)
    paste0(p[length(p)], ", ", paste(p[-length(p)], collapse = " "))
  }, character(1))
  paste(out, collapse = " and ")
}

# An author field biber can parse. Affiliation digits and marks are removed; a
# single "name" that is really a comma-separated list of names written given-first
# (seen in one bioRxiv record, with the affiliations appended) is split, cut at the
# first affiliation word, and each part braced so biber takes it as one name.
tidy_authors <- function(a) {
  if (is.null(a) || is.na(a) || a == "") return(a)
  parts <- strsplit(a, " and ", fixed = TRUE)[[1]]
  parts <- gsub("\\s+", " ", trimws(gsub("[0-9*]+", "", parts)))
  out <- unlist(lapply(parts, function(p) {
    if (lengths(regmatches(p, gregexpr(",", p))) <= 1) return(p)
    toks <- trimws(strsplit(p, ",")[[1]])
    toks <- sub("\\s+(Faculty|Department|Dept|University|Institute|College|School|Laboratory|Centre|Center|Division|Hospital|Unit)\\b.*$", "", toks, ignore.case = TRUE)
    toks <- toks[nzchar(toks)]
    paste0("{", toks, "}")
  }))
  paste(out, collapse = " and ")
}

first_surname <- function(authors_bib) {
  if (is.na(authors_bib)) return("anon")
  trimws(strsplit(strsplit(authors_bib, " and ", fixed = TRUE)[[1]][1], ",")[[1]][1])
}

# Europe PMC authorString: "Wang Y, Cai C, Huang D." -> "Wang, Y and Cai, C and Huang, D"
authors_from_epmc <- function(s) {
  if (is.null(s) || is.na(s) || s == "") return(NA_character_)
  parts <- trimws(strsplit(sub("\\.$", "", s), ",")[[1]])
  parts <- parts[parts != ""]
  out <- vapply(parts, function(p) {
    t <- strsplit(p, "\\s+")[[1]]
    if (length(t) < 2) return(p)
    paste0(paste(t[-length(t)], collapse = " "), ", ", t[length(t)])
  }, character(1))
  paste(out, collapse = " and ")
}

# bioRxiv authors: "Bauknecht, R.; Fletcher, R. J." -> " and "-joined
authors_from_biorxiv <- function(s) {
  if (is.null(s) || is.na(s) || s == "") return(NA_character_)
  paste(trimws(strsplit(s, ";", fixed = TRUE)[[1]]), collapse = " and ")
}

# Biodiversity PMC authors are written surname first, as in MEDLINE:
# "Taskaeva Anastasia A", "Rebez E B", "Van Berkel Derek B" -> "Taskaeva, Anastasia A",
# "Rebez, E B", "Van Berkel, Derek B". author_bib() expects "Given Surname" and made
# the first given name or the last initial the surname. Particles stay with the
# surname: leading ones ("de la Cruz Maria") and lowercase ones after the first word
# ("Gomes da Silva Juliane"; "Nguyen Van Anh T" keeps "Van" as a given name).
# Separate surname and given_names fields are taken as they are.
SURNAME_PARTICLES <- c("van", "von", "der", "den", "de", "del", "della", "di", "da", "dos", "das", "du", "ten", "ter")
authors_from_biodivpmc <- function(a) {
  if (is.null(a) || length(a) == 0) return(NA_character_)
  out <- vapply(a, function(x) {
    if (is.list(x)) {
      if (!is.null(x$surname)) return(trimws(paste0(x$surname, ", ", x$given_names %||% "")))
      x <- x$name
    }
    x <- trimws(as.character(x %||% ""))
    if (x == "" || grepl(",", x)) return(x)
    p <- strsplit(x, "\\s+")[[1]]
    if (length(p) < 2) return(x)
    k <- 1
    repeat {
      if (k < length(p) - 1 && (tolower(p[k]) %in% SURNAME_PARTICLES ||
                                (k > 1 && tolower(p[k]) %in% c("la", "le", "los", "las")))) k <- k + 1
      else if (k < length(p) - 2 && p[k + 1] %in% c(SURNAME_PARTICLES, "la", "le", "los", "las")) k <- k + 2
      else break
    }
    paste0(paste(p[1:k], collapse = " "), ", ", paste(p[-(1:k)], collapse = " "))
  }, character(1), USE.NAMES = FALSE)
  out <- out[out != ""]
  if (length(out) == 0) return(NA_character_)
  paste(out, collapse = " and ")
}

# OpenAlex abstract_inverted_index -> text
abstract_from_inverted <- function(idx) {
  if (is.null(idx) || length(idx) == 0) return(NA_character_)
  pos <- unlist(idx, use.names = FALSE)
  words <- rep(names(idx), lengths(idx))
  paste(words[order(pos)], collapse = " ")
}

# --- parsers: one per source; each returns a data frame of raw records -----------

REC_COLS <- c("source", "topic", "src_id", "doi", "arxiv_id", "pmid", "pmcid", "title",
              "authors", "venue", "date", "type", "preprint_server", "url", "abstract",
              "version", "published_doi", "oa")

empty_records <- function() {
  as.data.frame(setNames(replicate(length(REC_COLS), character(0), simplify = FALSE), REC_COLS),
                stringsAsFactors = FALSE)
}

rec <- function(...) {
  x <- list(...)
  for (c in REC_COLS) if (is.null(x[[c]])) x[[c]] <- NA_character_
  x <- lapply(x[REC_COLS], function(v) { v <- as.character(v %||% NA_character_); if (length(v) == 0) NA_character_ else v[1] })
  as.data.frame(x, stringsAsFactors = FALSE)
}

bind <- function(lst) {
  lst <- lst[vapply(lst, function(d) !is.null(d) && nrow(d) > 0, logical(1))]
  if (length(lst) == 0) return(empty_records())
  do.call(rbind, lst)
}

parse_europepmc <- function(path, topic) {
  j <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  res <- j$resultList$result
  if (length(res) == 0) return(empty_records())
  bind(lapply(res, function(r) {
    pp <- identical(r$source, "PPR")
    doi <- norm_doi(r$doi %||% NA)
    rec(source = "europepmc", topic = topic, src_id = paste0(r$source, ":", r$id),
        doi = doi, pmid = r$pmid %||% NA, pmcid = r$pmcid %||% NA,
        title = r$title, authors = authors_from_epmc(r$authorString %||% NA),
        venue = if (pp) "Europe PMC preprint" else (r$journalTitle %||% r$journalInfo$journal$title %||% NA),
        date = r$firstPublicationDate %||% NA,
        type = if (pp) "preprint" else "article",
        preprint_server = if (pp) "Europe PMC (PPR)" else NA,
        url = if (!is.na(doi)) paste0("https://doi.org/", doi) else paste0("https://europepmc.org/abstract/", r$source, "/", r$id),
        abstract = r$abstractText %||% NA, oa = r$isOpenAccess %||% NA)
  }))
}

parse_openalex <- function(path, topic) {
  j <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  res <- j$results
  if (length(res) == 0) return(empty_records())
  bind(lapply(res, function(r) {
    doi <- norm_doi(r$doi %||% NA)
    ax <- arxiv_from_doi(doi)
    src <- r$primary_location$source$display_name %||% NA
    pp <- identical(r$type, "preprint") || (!is.na(ax)) || (!is.na(src) && grepl("rxiv|preprint|ssrn|research square", tolower(src)))
    rec(source = "openalex", topic = topic, src_id = sub("^https://openalex.org/", "", r$id %||% NA),
        doi = if (!is.na(ax)) NA else doi, arxiv_id = ax,
        title = r$title %||% r$display_name %||% NA,
        authors = author_bib(vapply(r$authorships, function(a) a$author$display_name %||% NA_character_, character(1))),
        venue = src, date = r$publication_date %||% NA,
        type = if (pp) "preprint" else "article",
        preprint_server = if (pp) (src %||% "preprint") else NA,
        url = if (!is.na(doi)) paste0("https://doi.org/", doi) else (r$primary_location$landing_page_url %||% r$id %||% NA),
        abstract = abstract_from_inverted(r$abstract_inverted_index),
        oa = if (isTRUE(r$open_access$is_oa)) "Y" else NA)
  }))
}

parse_arxiv <- function(path, topic) {
  x <- xml2::read_xml(path)
  ns <- c(a = "http://www.w3.org/2005/Atom", arxiv = "http://arxiv.org/schemas/atom")
  entries <- xml2::xml_find_all(x, ".//a:entry", ns)
  if (length(entries) == 0) return(empty_records())
  txt <- function(e, p) { n <- xml2::xml_find_first(e, p, ns); if (inherits(n, "xml_missing")) NA_character_ else trimws(gsub("\\s+", " ", xml2::xml_text(n))) }
  bind(lapply(entries, function(e) {
    id <- strip_version(sub("^.*/abs/", "", txt(e, "a:id")))
    doi <- norm_doi(txt(e, "arxiv:doi"))
    rec(source = "arxiv", topic = topic, src_id = id, arxiv_id = id,
        doi = doi,
        title = txt(e, "a:title"),
        authors = author_bib(xml2::xml_text(xml2::xml_find_all(e, "a:author/a:name", ns))),
        venue = "arXiv", date = substr(txt(e, "a:published"), 1, 10),
        type = "preprint", preprint_server = "arXiv",
        url = paste0("https://arxiv.org/abs/", id),
        abstract = txt(e, "a:summary"),
        version = sub("^.*v([0-9]+)$", "\\1", sub("^.*/abs/", "", txt(e, "a:id"))))
  }))
}

parse_biorxiv <- function(path, topic) {
  j <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  res <- j$collection
  if (length(res) == 0) return(empty_records())
  bind(lapply(res, function(r) {
    doi <- norm_doi(r$doi)
    pub <- norm_doi(r$published %||% NA)
    if (!is.na(pub) && pub %in% c("na", "")) pub <- NA
    rec(source = "biorxiv", topic = topic, src_id = paste0(doi, "v", r$version %||% "1"),
        doi = doi, title = r$title, authors = authors_from_biorxiv(r$authors %||% NA),
        venue = "bioRxiv", date = r$date %||% NA, type = "preprint",
        preprint_server = paste0("bioRxiv (", r$category %||% "", ")"),
        url = paste0("https://www.biorxiv.org/content/", doi, "v", r$version %||% "1"),
        abstract = r$abstract %||% NA, version = r$version %||% "1", published_doi = pub,
        oa = "Y")
  }))
}

parse_biodivpmc <- function(path, topic) {
  j <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  hits <- j$elastic_output$hits$hits
  if (length(hits) == 0) return(empty_records())
  bind(lapply(hits, function(h) {
    s <- h$`_source`
    doi <- norm_doi(s$doi %||% NA)
    rec(source = "biodivpmc", topic = topic, src_id = paste0(j$collection %||% "col", ":", h$`_id`),
        doi = doi, pmid = s$pmid %||% NA, pmcid = s$pmcid %||% NA,
        title = s$title, authors = authors_from_biodivpmc(s$authors),
        venue = s$journal %||% s$medline_ta %||% NA, date = s$publication_date %||% NA,
        type = "article",
        url = if (!is.na(doi)) paste0("https://doi.org/", doi) else paste0("https://biodiversitypmc.sibils.org/"),
        abstract = s$abstract %||% NA, oa = NA)
  }))
}

parse_raw <- function(path) {
  m <- parse_raw_name(path)
  switch(m$source,
         europepmc = parse_europepmc(path, m$topic),
         openalex = parse_openalex(path, m$topic),
         arxiv = parse_arxiv(path, m$topic),
         biorxiv = parse_biorxiv(path, m$topic),
         biodivpmc = parse_biodivpmc(path, m$topic),
         stop("unknown source in file name: ", path))
}

# --- BibTeX --------------------------------------------------------------------

STOP_WORDS <- c("the", "with", "from", "into", "their", "using", "towards", "toward",
                "between", "across", "under", "over", "versus", "does", "what", "when",
                "where", "this", "that", "these", "those", "which", "there", "here",
                "than", "then", "also", "more", "most", "very", "some", "study", "studies",
                "analysis", "role", "effect", "effects", "novel", "first", "based", "approach")

bib_key <- function(surname, year, title, existing = character()) {
  s <- tolower(gsub("[^a-z]", "", tolower(to_ascii(surname %||% "anon"))))
  if (is.na(s) || s == "") s <- "anon"
  w <- strsplit(norm_title(title %||% ""), " ")[[1]]
  w <- w[nchar(w) > 3 & !w %in% STOP_WORDS & !grepl("^[0-9]+$", w)]
  kw <- if (length(w)) w[1] else "paper"
  base <- paste0(s, year %||% "nd", kw)
  key <- base
  i <- 1
  while (key %in% existing) {
    i <- i + 1
    key <- paste0(base, letters[i])
  }
  key
}

bib_escape <- function(x) {
  x <- gsub("([{}])", "\\\\\\1", x)
  x <- gsub("([&%_#$])", "\\\\\\1", x)
  x
}

bib_fields <- function(f) {
  f <- f[!vapply(f, function(v) is.null(v) || length(v) == 0 || is.na(v) || v == "", logical(1))]
  w <- max(nchar(names(f)))
  paste0(sprintf("  %-*s = {%s},", w, names(f), unlist(f)), collapse = "\n")
}

bib_entry <- function(key, r) {
  preprint <- identical(r$type, "preprint")
  f <- list(author = tidy_authors(r$authors), title = paste0("{", bib_escape(r$title), "}"))
  if (!preprint) f$journaltitle <- bib_escape(r$venue)
  f$date <- r$date
  if (!is.na(r$doi %||% NA)) f$doi <- r$doi
  if (preprint) {
    if (!is.na(r$arxiv_id %||% NA)) { f$eprint <- r$arxiv_id; f$eprinttype <- "arxiv" }
    f$pubstate <- "prepublished"
    f$note <- paste0("Preprint, ", r$preprint_server %||% "preprint server")
  }
  if (!is.na(r$note %||% NA)) f$note <- paste0(f$note %||% "", if (!is.null(f$note)) "; " else "", r$note)
  f$url <- r$url
  f$keywords <- paste0("topic:", gsub(";", ",", r$topics %||% ""), "; src:", gsub(";", ",", r$sources %||% ""))
  paste0("@", if (preprint) "online" else "article", "{", key, ",\n", bib_fields(f), "\n}\n")
}

bib_keys_in <- function(path) {
  if (!file.exists(path)) return(character())
  m <- regmatches(readLines(path, warn = FALSE), regexpr("^@\\w+\\{([^,]+),", readLines(path, warn = FALSE)))
  sub("^@\\w+\\{([^,]+),", "\\1", m)
}

# --- small utilities ------------------------------------------------------------

read_csv <- function(path, cols = NULL) {
  if (!file.exists(path)) {
    if (is.null(cols)) return(NULL)
    return(as.data.frame(setNames(replicate(length(cols), character(0), simplify = FALSE), cols), stringsAsFactors = FALSE))
  }
  read.csv(path, colClasses = "character", na.strings = "", check.names = FALSE, stringsAsFactors = FALSE)
}

write_csv <- function(df, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  write.csv(df, path, row.names = FALSE, na = "")
}

md5 <- function(path) unname(tools::md5sum(path))

utc_now <- function() format(Sys.time(), "%Y-%m-%d %H:%M:%S UTC", tz = "UTC")

say <- function(...) cat(..., "\n", sep = "")
