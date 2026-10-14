# Fetch one week of new items from five sources and keep every response as it came.
# Run from the repository root: Rscript R/01_fetch.R [YYYY-WW]
# Writes data/raw/<week>/<source>__<topic>__<page>.json (.xml for arXiv) and
# data/raw/<week>/fetch.csv, one row per source and topic with query, pages,
# items, seconds and status. A failed source is recorded, not fatal.
source("R/00_common.R")

cfg <- load_config()
week <- week_arg()
win <- week_window(week, cfg$overlap_days %||% 0)
delay <- function(src) (cfg$delay_seconds[[src]] %||% cfg$delay_seconds$default %||% 1)

# --sources a,b   fetch only these sources into the existing folder (to repeat a
#                 source that failed); their rows in fetch.csv are replaced.
args <- commandArgs(trailingOnly = TRUE)
only <- NULL
if (any(grepl("^--sources=", args))) only <- strsplit(sub("^--sources=", "", args[grepl("^--sources=", args)][1]), ",")[[1]]
want <- function(src) is.null(only) || src %in% only

# A full rerun starts from an empty folder; the earlier attempt is kept beside it, not deleted.
old <- file.path("data", "raw", week)
if (is.null(only) && dir.exists(old)) {
  aside <- paste0(old, ".previous-", format(Sys.time(), "%Y%m%d%H%M%S"))
  file.rename(old, aside)
  say("earlier raw files moved to ", aside)
}
if (!is.null(only)) {
  say("fetching only: ", paste(only, collapse = ", "), " (other sources' files and rows kept)")
  stale <- list.files(raw_dir(week), pattern = paste0("^(", paste(only, collapse = "|"), ")__.*\\.(json|xml)$"), full.names = TRUE)
  if (length(stale)) { file.remove(stale); say(length(stale), " earlier files of these sources removed") }
}
say("week ", week, ": items first published ", format(win$from), " to ", format(win$to),
    " (ISO week ", format(win$monday), " to ", format(win$monday + 6), ", plus ", cfg$overlap_days %||% 0, " overlap days)")

rows <- list()
note <- function(source, topic, query, url, pages, items, seconds, status) {
  rows[[length(rows) + 1]] <<- data.frame(source = source, topic = topic, query = query, url = url,
                                          pages = pages, items = items, seconds = round(seconds, 1),
                                          status = status, stringsAsFactors = FALSE)
  say(sprintf("%-10s %-26s pages %2d  items %4d  %6.1fs  %s", source, topic, pages, items, seconds, status))
}

# Count the records a raw file holds, with the same parser normalise will use.
count_file <- function(path) tryCatch(nrow(parse_raw(path)), error = function(e) NA_integer_)

# --- Europe PMC ---------------------------------------------------------------------

fetch_europepmc <- function(topic) {
  if (is.null(topic$europepmc)) return(invisible())
  q <- sprintf("(%s) AND FIRST_PDATE:[%s TO %s]", topic$europepmc, win$from, win$to)
  t0 <- Sys.time(); cursor <- "*"; page <- 0; items <- 0; status <- "ok"; url <- NA
  repeat {
    page <- page + 1
    req <- client("https://www.ebi.ac.uk/europepmc/webservices/rest/search", cfg) |>
      httr2::req_url_query(query = q, format = "json", resultType = "core", pageSize = 100, cursorMark = cursor)
    r <- perform(req); if (is.na(url)) url <- r$url
    if (is.na(r$status) || r$status != 200) { status <- paste0("failed: ", r$status %||% r$error); break }
    path <- save_raw(r$text, raw_path(week, "europepmc", topic$id, page, "json"))
    j <- jsonlite::fromJSON(r$text, simplifyVector = FALSE)
    n <- length(j$resultList$result); items <- items + n
    nxt <- j$nextCursorMark
    if (n == 0 || is.null(nxt) || identical(nxt, cursor) || page >= 10) break
    cursor <- nxt; Sys.sleep(delay("europepmc"))
  }
  note("europepmc", topic$id, q, url, page, items, as.numeric(Sys.time() - t0, units = "secs"), status)
  Sys.sleep(delay("europepmc"))
}

# --- OpenAlex -------------------------------------------------------------------------

openalex_pages <- function(label, filter_value, search = NULL) {
  t0 <- Sys.time(); page <- 0; items <- 0; status <- "ok"; url <- NA
  key <- Sys.getenv("OPENALEX_API_KEY")
  repeat {
    page <- page + 1
    req <- client("https://api.openalex.org/works", cfg) |>
      httr2::req_url_query(filter = filter_value, `per-page` = 200, page = page,
                           select = "id,doi,title,display_name,publication_date,type,primary_location,authorships,abstract_inverted_index,open_access")
    if (!is.null(search)) req <- httr2::req_url_query(req, search = search)
    if (nzchar(key)) req <- httr2::req_url_query(req, api_key = key)
    r <- perform(req)
    if (is.na(url)) url <- sub("[&?]api_key=[^&]*", "", r$url)
    if (!is.na(r$status) && r$status == 429) {
      # since 2026 OpenAlex meters requests without a key against a free daily
      # budget shared by every machine behind one IP address; a key has its own
      status <- paste0("failed: 429 rate limit (", if (nzchar(key)) "key's" else "free per-IP daily", " budget used up; set OPENALEX_API_KEY)")
      break
    }
    if (is.na(r$status) || r$status != 200) { status <- paste0("failed: ", r$status %||% r$error); break }
    save_raw(r$text, raw_path(week, "openalex", label, page, "json"))
    j <- jsonlite::fromJSON(r$text, simplifyVector = FALSE)
    n <- length(j$results); items <- items + n
    if (n < 200 || page >= 10) break
    Sys.sleep(delay("openalex"))
  }
  note("openalex", label, filter_value %||% search, url, page, items, as.numeric(Sys.time() - t0, units = "secs"), status)
  Sys.sleep(delay("openalex"))
}

fetch_openalex <- function(topic) {
  if (is.null(topic$openalex)) return(invisible())
  # title_and_abstract.search as a filter (narrower than the full-text search= parameter);
  # quoted phrases and AND/OR/NOT work, but words are stemmed, so acronyms that are
  # English words (MIxS, FAIR, CARE) must be given as phrases in the config.
  # Only articles, preprints and reviews: no datasets, errata or paratext.
  f <- sprintf("title_and_abstract.search:%s,type:article|preprint|review,from_publication_date:%s,to_publication_date:%s",
               topic$openalex, win$from, win$to)
  openalex_pages(topic$id, f)
}

fetch_openalex_people <- function() {
  ids <- cfg$people$openalex_author_ids
  if (is.null(ids) || length(ids) == 0) return(invisible())
  for (nm in names(ids)) {
    id <- ids[[nm]]
    if (is.null(id) || !grepl("^A[0-9]+$", id)) { say("openalex   people: no id for ", nm, ", skipped"); next }
    f <- sprintf("authorships.author.id:%s,type:article|preprint|review,from_publication_date:%s,to_publication_date:%s", id, win$from, win$to)
    openalex_pages(paste0("people_", id), f)
  }
}

# --- arXiv ------------------------------------------------------------------------------

arxiv_query <- function(label, q) {
  q <- sprintf("(%s) AND submittedDate:[%s0000 TO %s2359]", q, format(win$from, "%Y%m%d"), format(win$to, "%Y%m%d"))
  t0 <- Sys.time(); page <- 0; start <- 0; items <- 0; status <- "ok"; url <- NA; total <- NA
  repeat {
    page <- page + 1
    req <- client("https://export.arxiv.org/api/query", cfg) |>
      httr2::req_url_query(search_query = q, start = start, max_results = 200)
    r <- perform(req); if (is.na(url)) url <- r$url
    if (is.na(r$status) || r$status != 200) { status <- paste0("failed: ", r$status %||% r$error); break }
    path <- save_raw(r$text, raw_path(week, "arxiv", label, page, "xml"))
    x <- xml2::read_xml(path)
    ns <- c(a = "http://www.w3.org/2005/Atom", os = "http://a9.com/-/spec/opensearch/1.1/")
    total <- as.integer(xml2::xml_text(xml2::xml_find_first(x, ".//os:totalResults", ns)))
    n <- length(xml2::xml_find_all(x, ".//a:entry", ns)); items <- items + n
    start <- start + 200
    if (n == 0 || is.na(total) || start >= total || page >= 5) break
    Sys.sleep(delay("arxiv"))
  }
  note("arxiv", label, q, url, page, items, as.numeric(Sys.time() - t0, units = "secs"), status)
  Sys.sleep(delay("arxiv"))
}

fetch_arxiv <- function(topic) {
  if (is.null(topic$arxiv)) return(invisible())
  arxiv_query(topic$id, topic$arxiv)
}

fetch_arxiv_people <- function() {
  au <- cfg$people$arxiv_au
  if (is.null(au) || length(au) == 0) return(invisible())
  cats <- paste(sprintf("cat:%s", cfg$people$arxiv_cats %||% "cs.AI"), collapse = " OR ")
  for (a in au) arxiv_query(paste0("people_", a), sprintf("au:%s AND (%s)", a, cats))
}

# --- bioRxiv ------------------------------------------------------------------------------

fetch_biorxiv <- function() {
  cats <- unique(unlist(lapply(cfg$topics, function(t) t$biorxiv_categories)))
  cats <- cats[!is.na(cats) & cats != ""]
  server <- cfg$biorxiv_server %||% "biorxiv"
  for (cat in cats) {
    t0 <- Sys.time(); cursor <- 0; page <- 0; items <- 0; status <- "ok"; url <- NA
    repeat {
      page <- page + 1
      u <- sprintf("https://api.biorxiv.org/details/%s/%s/%s/%d/json", server, win$from, win$to, cursor)
      req <- client(u, cfg) |> httr2::req_url_query(category = cat)
      r <- perform(req); if (is.na(url)) url <- r$url
      if (is.na(r$status) || r$status != 200) { status <- paste0("failed: ", r$status %||% r$error); break }
      save_raw(r$text, raw_path(week, "biorxiv", cat, page, "json"))
      j <- jsonlite::fromJSON(r$text, simplifyVector = FALSE)
      n <- length(j$collection); items <- items + n
      cnt <- as.integer(j$messages[[1]]$count %||% n)
      if (n == 0 || cnt < 30 || page >= 40) break
      cursor <- cursor + 30; Sys.sleep(delay("biorxiv"))
    }
    note("biorxiv", cat, paste0("category=", cat), url, page, items, as.numeric(Sys.time() - t0, units = "secs"), status)
    Sys.sleep(delay("biorxiv"))
  }
}

# --- Biodiversity PMC (SIBiLS) ----------------------------------------------------------------

fetch_biodivpmc <- function(topic) {
  if (is.null(topic$biodivpmc)) return(invisible())
  cols <- topic$biodivpmc_cols %||% "pmc"
  for (col in cols) {
    jq <- jsonlite::toJSON(list(
      query = list(bool = list(must = list(
        list(query_string = list(query = topic$biodivpmc, fields = c("title", "abstract", "keywords"), default_operator = "OR")),
        list(range = list(publication_date = list(gte = as.character(win$from), lte = as.character(win$to)))))))),
      auto_unbox = TRUE)
    t0 <- Sys.time(); status <- "ok"
    # the page size is the n parameter; a size inside the JSON query is refused as a duplicate
    req <- client("https://biodiversitypmc.sibils.org/api/search", cfg) |>
      httr2::req_body_form(jq = as.character(jq), col = col, n = 500)
    r <- perform(req)
    items <- 0
    if (is.na(r$status) || r$status != 200) {
      status <- paste0("failed: ", r$status %||% r$error)
    } else {
      path <- save_raw(r$text, raw_path(week, "biodivpmc", paste0(topic$id, "_", col), 1, "json"))
      j <- jsonlite::fromJSON(r$text, simplifyVector = FALSE)
      if (!isTRUE(j$success)) status <- paste0("failed: ", j$error %||% "no success flag")
      items <- length(j$elastic_output$hits$hits)
    }
    note("biodivpmc", paste0(topic$id, "_", col), paste0(topic$biodivpmc, " [", col, "]"), "https://biodiversitypmc.sibils.org/api/search (POST jq)", 1, items,
         as.numeric(Sys.time() - t0, units = "secs"), status)
    Sys.sleep(delay("biodivpmc"))
  }
}

# --- run ------------------------------------------------------------------------------------------

for (topic in cfg$topics) {
  if (want("europepmc")) fetch_europepmc(topic)
  if (want("openalex")) fetch_openalex(topic)
  if (want("arxiv")) fetch_arxiv(topic)
  if (want("biodivpmc")) fetch_biodivpmc(topic)
}
if (want("biorxiv")) fetch_biorxiv()
if (want("openalex")) fetch_openalex_people()
if (want("arxiv")) fetch_arxiv_people()

log <- do.call(rbind, rows)
if (!is.null(only)) {
  earlier <- read_csv(file.path(raw_dir(week), "fetch.csv"))
  if (!is.null(earlier)) {
    kept <- earlier[!earlier$source %in% only, , drop = FALSE]
    kept$pages <- as.integer(kept$pages); kept$items <- as.integer(kept$items); kept$seconds <- as.numeric(kept$seconds)
    log <- rbind(kept[names(log)], log)
  }
}
write_csv(log, file.path(raw_dir(week), "fetch.csv"))
files <- list.files(raw_dir(week), pattern = "^[a-z]+__.*\\.(json|xml)$", full.names = TRUE)
counted <- sum(vapply(files, count_file, integer(1)), na.rm = TRUE)
say("\n", nrow(log), " queries, ", sum(log$items), " items reported by the APIs, ",
    counted, " records parsed from ", length(files), " raw files; ",
    sum(grepl("^failed", log$status)), " failed")
