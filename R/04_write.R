# Write the week: reviews/<week>.md, bib/<week>.bib, bib/all.bib, data/seen.csv
# and index.md. Only verified items get a bibliography entry. Running the script
# twice for the same week changes nothing the second time.
# Run from the repository root: Rscript R/04_write.R [YYYY-WW]
source("R/00_common.R")

cfg <- load_config()
week <- week_arg()
win <- week_window(week, cfg$overlap_days %||% 0)
d <- read_csv(file.path("data", "normalised", paste0(week, "-checked.csv")))
if (is.null(d)) stop("run R/03_check.R first: data/normalised/", week, "-checked.csv is missing")
d$verified <- d$verified == "TRUE"
fetch <- read_csv(file.path(raw_dir(week), "fetch.csv"))

SEEN_COLS <- c("uid", "doi", "arxiv_id", "title_norm", "key", "first_seen_week", "last_seen_week", "version", "published_doi", "preprint_of")
seen <- read_csv("data/seen.csv", SEEN_COLS)
all_keys <- unique(c(bib_keys_in("bib/all.bib"), seen$key[!is.na(seen$key)]))

# --- classify every item ---------------------------------------------------------------

seen_row <- function(r) {
  i <- which((!is.na(r$doi) & seen$doi == r$doi) | (!is.na(r$arxiv_id) & seen$arxiv_id == r$arxiv_id) | seen$uid == r$uid)
  if (length(i) == 0) i <- which(seen$title_norm == r$title_norm)
  if (length(i)) i[1] else NA_integer_
}
# a preprint seen earlier whose journal version this is
preprint_of <- function(r) {
  i <- integer()
  if (!is.na(r$published_doi)) i <- which(seen$doi == r$published_doi)
  if (length(i) == 0 && !is.na(r$doi)) i <- which(seen$published_doi == r$doi)
  if (length(i) == 0) { j <- which(seen$title_norm == r$title_norm & !is.na(seen$key) & grepl("^online", seen$preprint_of %||% "") == FALSE)
    i <- j[seen$doi[j] != r$doi | is.na(seen$doi[j])] }
  if (length(i)) i[1] else NA_integer_
}

d$status <- NA_character_; d$key <- NA_character_; d$note <- NA_character_; d$by_title <- FALSE
for (i in seq_len(nrow(d))) {
  r <- d[i, ]
  s <- seen_row(r)
  # an item first listed in this same week: rerunning the week regenerates its files identically
  if (!is.na(s) && identical(seen$first_seen_week[s], week)) {
    d$key[i] <- seen$key[s]
    if (!is.na(seen$preprint_of[s])) { d$status[i] <- "published"; d$note[i] <- paste0("Journal version of ", seen$preprint_of[s]) }
    else d$status[i] <- "new"
    next
  }
  if (!is.na(s) && !is.na(r$doi) && !is.na(seen$doi[s]) && seen$doi[s] == r$doi) {
    old_v <- suppressWarnings(as.integer(seen$version[s])); new_v <- suppressWarnings(as.integer(r$version))
    if (!is.na(new_v) && !is.na(old_v) && new_v > old_v) { d$status[i] <- "updated"; d$key[i] <- seen$key[s]; seen$version[s] <- r$version; seen$last_seen_week[s] <- week }
    else { d$status[i] <- "seen"; d$key[i] <- seen$key[s]; seen$last_seen_week[s] <- week }
    next
  }
  if (!is.na(s)) { d$status[i] <- "seen"; d$key[i] <- seen$key[s]; seen$last_seen_week[s] <- week; next }
  if (!r$verified) { d$status[i] <- "unverified"; next }
  p <- if (r$type == "article") preprint_of(r) else NA_integer_
  key <- bib_key(r$first_author, r$year, r$title, all_keys); all_keys <- c(all_keys, key)
  d$key[i] <- key
  if (!is.na(p)) {
    d$status[i] <- "published"; d$by_title[i] <- is.na(r$published_doi) && (is.na(seen$published_doi[p]) || seen$published_doi[p] != r$doi)
    d$note[i] <- paste0("Journal version of ", seen$key[p]); seen$published_doi[p] <- r$doi
  } else d$status[i] <- "new"
  seen <- rbind(seen, data.frame(uid = r$uid, doi = r$doi, arxiv_id = r$arxiv_id, title_norm = r$title_norm, key = key,
                                 first_seen_week = week, last_seen_week = week, version = r$version,
                                 published_doi = r$published_doi, preprint_of = if (!is.na(p)) seen$key[p] else NA,
                                 stringsAsFactors = FALSE))
}

# --- bibliography -------------------------------------------------------------------------

new_bib <- d[d$status %in% c("new", "published"), , drop = FALSE]
entries <- vapply(seq_len(nrow(new_bib)), function(i) bib_entry(new_bib$key[i], as.list(new_bib[i, ])), character(1))
dir.create("bib", showWarnings = FALSE)
week_bib <- file.path("bib", paste0(week, ".bib"))
header <- sprintf("%% Weekly literature review, %s: %d verified new items, written by R/04_write.R on %s.\n%% Every DOI resolved on Crossref and every arXiv identifier on the arXiv API with a matching title.\n\n",
                  week, nrow(new_bib), utc_now())
writeLines(paste0(header, paste(entries, collapse = "\n")), week_bib, useBytes = TRUE)
existing_all <- bib_keys_in("bib/all.bib")
add <- entries[!new_bib$key %in% existing_all]
if (!file.exists("bib/all.bib")) writeLines("% All verified items of the weekly literature review, appended week by week by R/04_write.R.\n", "bib/all.bib")
if (length(add)) cat(paste0("\n", paste(add, collapse = "\n")), file = "bib/all.bib", append = TRUE)
write_csv(seen[SEEN_COLS], "data/seen.csv")

# --- the review ----------------------------------------------------------------------------------

topic_label <- setNames(vapply(cfg$topics, function(t) t$label, character(1)), vapply(cfg$topics, function(t) t$id, character(1)))
topic_label["people"] <- "People followed"
label_of <- function(id) topic_label[id] %||% id

item_md <- function(r) {
  auth <- if (is.na(r$authors)) "" else {
    a <- strsplit(r$authors, " and ", fixed = TRUE)[[1]]
    paste0(paste(head(a, 6), collapse = "; "), if (length(a) > 6) " and others" else "")
  }
  link <- if (!is.na(r$doi)) sprintf("[doi:%s](https://doi.org/%s)", r$doi, r$doi)
          else if (!is.na(r$arxiv_id)) sprintf("[arXiv:%s](https://arxiv.org/abs/%s)", r$arxiv_id, r$arxiv_id)
          else sprintf("<%s>", r$url)
  pre <- if (r$type == "preprint") sprintf(" **Preprint** (%s%s).", r$preprint_server %||% "", if (!is.na(r$version)) paste0(" v", r$version) else "") else ""
  paste0("- **", r$title, "**  \n  ", auth, if (auth == "") "" else if (grepl("\\.$", auth)) " " else ". ",
         if (!is.na(r$venue)) paste0("*", r$venue, "*, ") else "", r$date, ". ", link, ".", pre,
         if (!is.na(r$note)) paste0(" ", r$note, ".") else "",
         "  \n  Found by: ", gsub(";", ", ", r$sources), ". Bib: `", r$key, "`.",
         if (!is.na(r$abstract_excerpt) && r$abstract_excerpt != "") paste0("  \n  > ", r$abstract_excerpt) else "")
}

lines <- c(sprintf("# Weekly literature review, %s", week),
           "",
           sprintf("Items first published %s to %s (ISO week %s to %s plus %d overlap days), fetched and written by scripts on %s. No model was involved in this file. Queries, counts and versions: [provenance/%s.log.md](../provenance/%s.log.md).",
                   win$from, win$to, win$monday, win$monday + 6, cfg$overlap_days %||% 0, utc_now(), week, week),
           "")
if (!is.null(fetch)) {
  by_src <- tapply(as.integer(fetch$items), fetch$source, sum)
  lines <- c(lines, paste0("Returned by the APIs: ", paste(sprintf("%s %d", names(by_src), by_src), collapse = ", "),
                           sprintf(". After merging duplicates: %d distinct items, %d new this week, %d seen in earlier weeks, %d not verified.",
                                   nrow(d), sum(d$status == "new"), sum(d$status == "seen"), sum(d$status == "unverified"))), "")
}
newd <- d[d$status == "new", , drop = FALSE]
for (tid in c(vapply(cfg$topics, function(t) t$id, character(1)), "people")) {
  items <- newd[vapply(strsplit(newd$topics, ";"), function(ts) tid %in% ts, logical(1)), , drop = FALSE]
  if (nrow(items) == 0) next
  items <- items[order(-as.integer(items$n_sources), items$date), , drop = FALSE]
  shown <- head(items, cfg$max_per_topic %||% 25)
  lines <- c(lines, sprintf("## %s (%d)", label_of(tid), nrow(items)), "",
             vapply(seq_len(nrow(shown)), function(i) item_md(shown[i, ]), character(1)), "")
  if (nrow(items) > nrow(shown)) lines <- c(lines, sprintf("%d more items in [bib/%s.bib](../bib/%s.bib).", nrow(items) - nrow(shown), week, week), "")
}
for (st in c("published", "updated", "unverified")) {
  sub <- d[d$status == st, , drop = FALSE]
  if (nrow(sub) == 0) next
  title <- c(published = "Now published", updated = "Updated preprints", unverified = "Not verified (no bibliography entry)")[st]
  lines <- c(lines, sprintf("## %s (%d)", title, nrow(sub)), "")
  for (i in seq_len(nrow(sub))) {
    r <- sub[i, ]
    lines <- c(lines, switch(st,
      published = sprintf("- **%s**. %s, %s. [doi:%s](https://doi.org/%s). %s%s. Bib: `%s`.", r$title, r$venue %||% "", r$date, r$doi, r$doi, r$note, if (r$by_title) " (matched by title)" else "", r$key),
      updated = sprintf("- **%s**: now version %s (%s). Bib: `%s`.", r$title, r$version, r$date, r$key),
      unverified = sprintf("- **%s** (%s, %s). %s. Found by: %s. <%s>", r$title, r$venue %||% r$preprint_server %||% "", r$date, r$verify_reason, gsub(";", ", ", r$sources), r$url)))
  }
  lines <- c(lines, "")
}
if (!is.null(fetch)) {
  zero <- fetch[as.integer(fetch$items) == 0 | grepl("^failed", fetch$status), , drop = FALSE]
  if (nrow(zero)) lines <- c(lines, sprintf("## Searches that returned nothing (%d)", nrow(zero)), "",
                             sprintf("- %s, %s: %s", zero$source, zero$topic, ifelse(grepl("^failed", zero$status), zero$status, "0 items")), "")
}
dir.create("reviews", showWarnings = FALSE)
writeLines(lines, file.path("reviews", paste0(week, ".md")), useBytes = TRUE)

# --- the index ---------------------------------------------------------------------------------

weeks <- sort(sub("\\.md$", "", list.files("reviews", pattern = "^[0-9]{4}-W[0-9]{2}\\.md$")), decreasing = TRUE)
idx <- c("# Weekly literature review: index", "", "Newest first. Each review is script output; a notes file, when present, was written by an AI assistant and is labelled as such.", "",
         "| Week | New items | Review | Bibliography | Log | Notes |", "|---|---|---|---|---|---|")
for (w in weeks) {
  n <- length(bib_keys_in(file.path("bib", paste0(w, ".bib"))))
  notes <- if (file.exists(file.path("notes", paste0(w, ".md")))) sprintf("[notes](notes/%s.md)", w) else ""
  idx <- c(idx, sprintf("| %s | %d | [review](reviews/%s.md) | [bib](bib/%s.bib) | [log](provenance/%s.log.md) | %s |", w, n, w, w, w, notes))
}
writeLines(idx, "index.md")

say(nrow(d), " items in; ", sum(d$status == "new"), " new; ", sum(d$status == "published"), " now published; ",
    sum(d$status == "updated"), " updated preprints; ", sum(d$status == "seen"), " seen before; ",
    sum(d$status == "unverified"), " not verified; ", nrow(new_bib), " bibliography entries written to bib/", week, ".bib (",
    length(add), " appended to bib/all.bib)")
