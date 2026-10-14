# Agent prompts

The instructions under which this repository's scripts were written, kept
verbatim so that the work can be repeated or checked. The repository was built
on 14 October 2026 by Claude (Anthropic) in a Claude Code session on the
author's Mac, from a plan the author approved; see `AGENTS.md` for the
record. The prompts below are the ones the book's Chapter 11 prints; an agent
given them with the facts in `AGENTS.md` should produce equivalent scripts.

The author's request, verbatim:

> write a plan on how to create a personal weekly literature review using
> europepmc, bioarxiv, arxiv, openalex, Biodiversity PMC, consensus. Example of
> prompts needed to write on using R for fetching and storing in md files and
> bib the retreived literature, weekly. and then a simple github repo for
> reading it . Could this be a skill on claude code inspired by Kybele? could
> it be a cron job on the computer. The aim is reproducibility and
> transparence of the system. this will be added after chapter 10 as
> instruction but also as my personal assistant. For the example gather all my
> interests in this repo and others and also read
> https://github.com/savvas-paragkamian/trec-coastal-microbiome/tree/main

## Prompt 1, fetch

```
Read README.md and AGENTS.md. Write R/00_common.R and R/01_fetch.R in base R
plus httr2, jsonlite, yaml and xml2; no other packages. 01_fetch.R takes an
ISO week label such as 2026-W42, or defaults to the week that ended
yesterday, reads config/interests.yml, and for every topic queries Europe
PMC, OpenAlex, arXiv, bioRxiv and Biodiversity PMC for items first published
in that week plus the overlap days in the config. Save every response
unchanged under data/raw/<week>/<source>__<topic>__<page>.json, or .xml for
arXiv. Send a User-Agent with the contact address from the config. Wait
three seconds between arXiv calls and one second otherwise. Retry a failed
request four times with growing delays. Never stop the run because one
source failed: record the failure and continue. Print one line per source
and topic with query, pages, items and seconds. Done when
Rscript R/01_fetch.R 2026-W42 writes the files and the number of items
counted from the files with jsonlite equals the printed totals.
```

## Prompt 2, normalise

```
Write R/02_normalise.R. It reads every file under data/raw/<week>/ and
writes data/normalised/<week>.csv with one row per distinct item and the
columns listed in README.md. Merge duplicates first by DOI, lower case and
without the https://doi.org/ prefix, then by arXiv identifier, treating an
OpenAlex DOI of the form 10.48550/arXiv.ID as that identifier, then by
normalised title: lower case, ASCII, letters and digits only. When merging,
keep the union of topics and sources, the journal venue over the preprint
venue, and the longest abstract, cut to sixty words. Print rows read and
rows after each of the three merges. Done when
Rscript R/02_normalise.R 2026-W00 prints 6 read, 4 after DOI, 4 after
identifier, 3 after title, and the row for DOI 10.1234/fixture-1 lists two
sources.
```

## Prompt 3, check

```
Read scripts/verify_bib.py from the book repository, then write
R/03_check.R to do the same for data/normalised/<week>.csv. For each DOI
fetch https://api.crossref.org/works/<doi>, and if Crossref answers 404 fetch
https://api.datacite.org/dois/<doi>, where Zenodo and Figshare register.
Compare the returned title with ours after normalising, using 1 minus the
edit distance over the longer length, threshold 0.85; also accept the pair
when one title is the other without its subtitle. Set verified TRUE or
FALSE with a reason. Check arXiv identifiers through the arXiv API id_list,
at most 100 per request, three seconds apart. Save the responses under
data/raw/<week>/crossref.json and arxiv-ids.xml (one file per batch) and
read them instead of the network when --offline is given. Skip identifiers
already in data/seen.csv: they were verified when first seen. Write
data/normalised/<week>-checked.csv. Add --self-test with a good DOI, a DOI
that does not exist, a real DOI with a deliberately wrong title, a good
arXiv identifier and one that does not exist; it passes only if the three
bad cases fail and the two good ones pass. Done when
Rscript R/03_check.R --self-test prints SELF-TEST PASSED and names the three
failures.
```

## Prompt 4, write

```
Write R/04_write.R. From data/normalised/<week>-checked.csv and data/seen.csv
it writes reviews/<week>.md and bib/<week>.bib, appends new entries to
bib/all.bib and new rows to data/seen.csv, and regenerates index.md. Only
verified items get a bib entry; the others are listed at the end of the
Markdown under "Not verified" with the reason and never enter a .bib file.
Keys are authorYEARkeyword: first author's surname in ASCII, year, first
title word longer than three letters that is not a stop word, made unique
against all.bib with a letter suffix. Preprints are @online entries with
eprint and eprinttype for arXiv or the bioRxiv DOI, and the Markdown marks
them preprint. Items already in seen.csv are not listed again. A preprint
with a higher version is listed once under "Updated preprints". An article
whose DOI or normalised title matches a seen preprint is listed once under
"Now published" and the seen row gets published_doi. Record every source
and topic that returned nothing under "Searches that returned nothing".
Escape ampersand, percent, underscore, hash and braces. Print items in,
new, seen before and bib entries written. Done when running the script
twice for 2026-W00 leaves all.bib and seen.csv unchanged the second time,
shown by git diff --stat, and biber --tool bib/2026-W00.bib reports no
errors.
```

## Prompt 5, orchestrator, log and renv

```
Write R/run_week.R. It runs R/01_fetch.R to R/04_write.R in order for one
week, given as an argument or defaulting to the week that ended yesterday,
passes --offline through, and writes provenance/<week>.log.md with: run
time in UTC, the git commit of the config, R and package versions, the md5
sum of every raw file, every query with its URL without any key, pages,
items and seconds, the normalise counts, DOIs checked, passed and failed by
key, files written, every failure and retry, and the total time. Set up
renv with httr2, jsonlite, yaml and xml2 only, and snapshot. Done when
Rscript R/run_week.R 2026-W00 --offline finishes without error, the log
contains every section above, and renv::status() reports the project is
synchronised.
```

## Prompt 6, the Action

```
Write .github/workflows/weekly.yml: on a schedule every Monday at 06:00 UTC
and on workflow_dispatch with an optional week input. On ubuntu-latest:
check out, install R 4.5.1 with r-lib/actions/setup-r using public RSPM
binaries, install libxml2-dev and libcurl4-openssl-dev, restore the renv
library, run Rscript R/03_check.R --self-test, run Rscript R/run_week.R
with the week input if given, upload data/raw/ as an artifact, and commit
reviews/, bib/, data/normalised/, data/seen.csv, provenance/ and index.md
with the message "Week <week>: <n> new items" when there is anything to
commit. OPENALEX_API_KEY comes from a repository secret; the scripts read
it from the environment and never print it.
Store no other secret. Done when a workflow_dispatch run for 2026-W41 is
green, its commit is on main, and the job log shows the self-test passed
before the fetch.
```

## Prompt 7, the skill

```
Read docs/assistant-rules.md; its rules are not to be weakened. Write
.claude/skills/weekly-literature/SKILL.md in the Claude Code skill format
with name, description, argument-hint, allowed-tools and
disable-model-invocation. The skill takes a week label, reads
config/interests.yml, reviews/<week>.md and bib/<week>.bib, runs the
Consensus queries listed in the config for each topic through the Consensus
MCP tool, three at a time, and appends every query with UTC time, result
count and the returned URLs to provenance/search-log.md. A Consensus result
may be cited only if it is in the week's bib, or if
Rscript R/skill_verify.R <doi> "<title>" prints OK; that script writes the
entry to bib/<week>-consensus.bib itself. The skill then writes
notes/<week>.md: per topic, a few sentences from the abstracts, every
sentence tied to a bib key in square brackets or a verified DOI, preprints
marked, and "Searches found no new items on ... this week" when there is
nothing. It edits no other file and never commits. Also write
R/skill_verify.R, with the same Crossref title check as R/03_check.R, and
tests/check_notes.R, which exits with an error if the notes cite anything
not in the week's bib files or the search log, and has a --self-test that
plants one bad key and one unlogged URL. Done when /weekly-literature
2026-W42 produces notes that pass tests/check_notes.R, and the number of
queries added to search-log.md equals the number of Consensus calls in the
session.
```

The interests file, `config/interests.yml`, is deliberately not a prompt:
the author writes it.
