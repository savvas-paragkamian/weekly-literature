# One row per distinct item: parse every raw file of the week, assign bioRxiv
# records to topics by their terms, and merge duplicates by DOI, then by arXiv
# identifier, then by normalised title.
# Run from the repository root: Rscript R/02_normalise.R [YYYY-WW]
# Writes data/normalised/<week>.csv and prints the counts after each merge.
#   --self-test  parse a planted Biodiversity PMC record whose authors are written
#                surname first; passes only if every name and the key come out right
source("R/00_common.R")

self_test <- function() {
  path <- tempfile(fileext = ".json")
  writeLines(jsonlite::toJSON(list(collection = "medline", elastic_output = list(hits = list(hits = list(
    list(`_id` = "1", `_source` = list(title = "Wastewater as a driver of lineage replacement", publication_date = "2026-10-13",
         authors = c("Taskaeva Anastasia A", "Rebez E B", "Van Berkel Derek B", "de la Cruz Maria",
                     "Gomes da Silva Juliane", "Nguyen Van Anh T", "Le Minh"))),
    list(`_id` = "2", `_source` = list(title = "A record with author fields", publication_date = "2026-10-13",
         authors = list(list(surname = "Dickschat", given_names = "Jeroen S")))))))), auto_unbox = TRUE), path)
  r <- parse_biodivpmc(path, "selftest")
  want <- c("Taskaeva, Anastasia A and Rebez, E B and Van Berkel, Derek B and de la Cruz, Maria and Gomes da Silva, Juliane and Nguyen, Van Anh T and Le, Minh",
            "Dickschat, Jeroen S")
  key <- bib_key(first_surname(r$authors[1]), "2026", r$title[1])
  for (i in seq_along(want)) say(if (identical(r$authors[i], want[i])) "ok    " else "WRONG ", r$authors[i])
  say(if (key == "taskaeva2026wastewater") "ok    " else "WRONG ", "key ", key)
  if (identical(r$authors, want) && key == "taskaeva2026wastewater") {
    say("SELF-TEST PASSED: Biodiversity PMC authors parsed surname first; key taskaeva2026wastewater"); quit(status = 0)
  }
  say("SELF-TEST FAILED"); quit(status = 1)
}
if (has_flag("--self-test")) self_test()

cfg <- load_config()
week <- week_arg()
win <- week_window(week, cfg$overlap_days %||% 0)
files <- list.files(raw_dir(week), pattern = "^[a-z]+__.*\\.(json|xml)$", full.names = TRUE)
if (length(files) == 0) stop("no raw files under data/raw/", week)

recs <- bind(lapply(files, parse_raw))
n_read <- nrow(recs)

# bioRxiv files are per category: keep a record for every topic whose terms match.
term_regex <- function(terms) paste0("\\b(", paste(gsub("([.|()\\\\^$*+?{}\\[\\]])", "\\\\\\1", terms), collapse = "|"), ")\\b")
assign_biorxiv <- function(d) {
  if (nrow(d) == 0) return(d)
  cat_of <- d$topic
  out <- list()
  for (t in cfg$topics) {
    if (length(t$biorxiv_categories) == 0) next
    cand <- d[cat_of %in% t$biorxiv_categories, , drop = FALSE]
    if (nrow(cand) == 0) next
    hit <- grepl(term_regex(t$terms), paste(cand$title, cand$abstract), ignore.case = TRUE, perl = TRUE)
    if (any(hit)) { m <- cand[hit, , drop = FALSE]; m$topic <- t$id; out[[t$id]] <- m }
  }
  bind(out)
}
is_bx <- recs$source == "biorxiv"
bx_in <- sum(is_bx)
bx_assigned <- assign_biorxiv(recs[is_bx, , drop = FALSE])
bx_kept <- length(unique(bx_assigned$doi))
recs <- bind(list(recs[!is_bx, , drop = FALSE], bx_assigned))
say("bioRxiv: ", bx_in, " records in the fetched categories; ", bx_kept, " matched a topic's terms (",
    nrow(bx_assigned), " topic assignments); ", bx_in - bx_kept, " set aside")

# People files are topic "people_<id>": keep them under the topic "people".
recs$topic[grepl("^people_", recs$topic)] <- "people"
# Biodiversity PMC files carry "<topic>_<col>".
recs$topic <- sub("_(medline|pmc|plazi|suppdata)$", "", recs$topic)

# Keep only items inside the window (sources sometimes return neighbours).
d <- as.Date(recs$date, optional = TRUE)
inside <- is.na(d) | (d >= win$from & d <= win$to)
say("outside the window and dropped: ", sum(!inside))
recs <- recs[inside, , drop = FALSE]

recs$doi <- norm_doi(recs$doi)
ax <- arxiv_from_doi(recs$doi)
recs$arxiv_id <- ifelse(is.na(recs$arxiv_id) & !is.na(ax), ax, recs$arxiv_id)
recs$doi[!is.na(ax)] <- NA
recs$arxiv_id <- ifelse(is.na(recs$arxiv_id), NA, strip_version(recs$arxiv_id))
recs$title_norm <- norm_title(recs$title)

# --- merging: group ids, three passes ---------------------------------------------------

gid <- seq_len(nrow(recs))
merge_on <- function(gid, key) {
  ok <- !is.na(key) & key != ""
  for (k in unique(key[ok])) {
    members <- unique(gid[ok & key == k])
    if (length(members) > 1) gid[gid %in% members] <- min(members)
  }
  gid
}
gid <- merge_on(gid, recs$doi);        n_doi <- length(unique(gid))
gid <- merge_on(gid, recs$arxiv_id);   n_ax <- length(unique(gid))
gid <- merge_on(gid, recs$title_norm); n_title <- length(unique(gid))

pick <- function(v) { v <- v[!is.na(v) & v != ""]; if (length(v)) v[1] else NA_character_ }
longest <- function(v) { v <- v[!is.na(v)]; if (length(v)) v[which.max(nchar(v))] else NA_character_ }
join <- function(v) paste(sort(unique(v[!is.na(v) & v != ""])), collapse = ";")

merged <- lapply(split(recs, gid), function(g) {
  art <- g[g$type == "article", , drop = FALSE]
  pre <- g[g$type == "preprint", , drop = FALSE]
  type <- if (nrow(art) > 0) "article" else "preprint"
  # a preprint found on its server and in Europe PMC's preprint index: name the server
  pre_venues <- c(pre$venue[pre$venue != "Europe PMC preprint"], pre$venue)
  venue <- if (nrow(art) > 0) pick(art$venue) else pick(pre_venues)
  data.frame(
    doi = pick(g$doi), arxiv_id = pick(g$arxiv_id), pmid = pick(g$pmid), pmcid = pick(g$pmcid),
    title = longest(g$title), title_norm = pick(g$title_norm),
    authors = longest(g$authors), first_author = first_surname(longest(g$authors)),
    year = substr(pick(g$date), 1, 4), date = pick(sort(g$date)),
    venue = venue, type = type,
    preprint_server = if (type == "preprint") pick(c(pre$preprint_server[!grepl("^Europe PMC", pre$preprint_server)], pre$preprint_server)) else NA_character_,
    url = pick(c(if (!is.na(pick(g$doi))) paste0("https://doi.org/", pick(g$doi)), g$url)),
    abstract_excerpt = excerpt(longest(g$abstract)),
    topics = join(g$topic), sources = join(g$source),
    n_sources = length(unique(g$source)),
    version = pick(g$version), published_doi = pick(g$published_doi), oa = pick(g$oa),
    stringsAsFactors = FALSE)
})
out <- do.call(rbind, merged)
if (is.null(out) || nrow(out) == 0) {
  write_csv(data.frame(uid = character(0)), file.path("data", "normalised", paste0(week, ".csv")))
  say(n_read, " records read; none inside the window; wrote an empty data/normalised/", week, ".csv")
  quit(status = 0)
}
out$uid <- ifelse(!is.na(out$doi), paste0("doi:", out$doi),
                  ifelse(!is.na(out$arxiv_id), paste0("arxiv:", out$arxiv_id),
                         paste0("title:", substr(out$title_norm, 1, 80))))
out <- out[order(out$topics, -out$n_sources, out$date), , drop = FALSE]
rownames(out) <- NULL

write_csv(out, file.path("data", "normalised", paste0(week, ".csv")))
say(n_read, " records read; ", nrow(recs), " kept (", bx_in - bx_kept, " bioRxiv records matched no topic); ",
    n_doi, " after the DOI merge; ", n_ax, " after the arXiv-identifier merge; ",
    n_title, " after the title merge; wrote data/normalised/", week, ".csv")
