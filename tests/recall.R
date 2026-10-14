# How many of the papers the author knows should have been found were found.
# tests/gold.csv: doi (or arxiv:ID), title, topic, first_pub_date, how_learned.
# Only papers first published on or after the first recorded week are scored;
# add first_pub_date when you learn of a paper, and add the paper itself when
# you hear of it elsewhere: the gold set is the honest coverage test.
# Run from the repository root: Rscript tests/recall.R
source("R/00_common.R")

gold <- read_csv("tests/gold.csv")
seen <- read_csv("data/seen.csv", c("uid", "doi", "arxiv_id", "first_seen_week"))
if (is.null(gold) || nrow(gold) == 0) { say("tests/gold.csv is empty: add the papers you know should be found"); quit(status = 0) }
is_ax <- grepl("^arxiv:", gold$doi)
gold$doi[!is_ax] <- norm_doi(gold$doi[!is_ax])
found <- ifelse(is_ax, sub("^arxiv:", "", gold$doi) %in% seen$arxiv_id, gold$doi %in% seen$doi)
start <- if (nrow(seen) && any(!is.na(seen$first_seen_week))) week_monday(min(seen$first_seen_week, na.rm = TRUE)) else Sys.Date()
d <- as.Date(gold$first_pub_date, optional = TRUE)
scored <- !is.na(d) & d >= start
say("gold set: ", nrow(gold), " papers; ", sum(scored), " first published since the review started (", format(start), "); ",
    sum(found & scored), " of those found; ", sum(found & !scored), " older or undated ones are in seen.csv; ",
    sum(is.na(d)), " without a first_pub_date (not scored)")
if (any(scored & !found)) { say("missed:"); say(paste0("- ", gold$title[scored & !found], " (", gold$doi[scored & !found], ")", collapse = "\n")) }
