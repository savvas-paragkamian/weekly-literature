# weekly-literature

A personal weekly literature review that scripts build and a person reads.
Every Monday the week's new papers on a fixed list of topics are fetched from
Europe PMC, OpenAlex, arXiv, bioRxiv and Biodiversity PMC, merged, verified
and written to Markdown and BibTeX in this repository, with a log of every
query. An AI assistant may then add notes in a separate, labelled file; it
cannot add a reference that a script has not resolved.

Start at [index.md](index.md), newest week first.

## Two layers, never mixed

1. **Scripts (R).** `config/interests.yml` holds the topics and their queries,
   written by hand. `R/run_week.R` fetches the week, keeps every API response,
   merges duplicates, resolves every DOI on Crossref and every arXiv
   identifier on the arXiv API, and writes `reviews/<week>.md`,
   `bib/<week>.bib`, `bib/all.bib`, `data/seen.csv` and
   `provenance/<week>.log.md`. No model is involved.
2. **Assistant (a Claude Code skill).** `/weekly-literature <week>` reads the
   week's files, runs the Consensus queries listed in the config (Consensus
   has no public API; only its MCP server), and writes `notes/<week>.md`. Its
   rules are in [docs/assistant-rules.md](docs/assistant-rules.md): vocabulary
   from the config, scope enforced in code, saying no, and a citation check.
   A Consensus paper can enter a bibliography only through
   `R/skill_verify.R`, which resolves it on Crossref itself.

## Layout

| Path | Contents |
|---|---|
| `config/interests.yml` | topics, terms, per-source queries, people, Consensus queries |
| `R/00_common.R` | shared helpers: dates, HTTP, parsers for each source, BibTeX writer |
| `R/01_fetch.R` … `R/04_write.R` | fetch, normalise, check, write; each prints what it read and wrote |
| `R/run_week.R` | one week end to end, plus the provenance log |
| `R/skill_verify.R` | the assistant's only door into a bibliography |
| `R/freeze_week.R` | a teaching copy of a fetched week: chosen topics, abstracts cut and marked |
| `data/raw/<week>/` | API responses as received (not in git, except the fixture week `2026-W00`); `fetch.csv` per week |
| `data/normalised/<week>.csv`, `<week>-checked.csv` | one row per distinct item, then with the verification result |
| `data/seen.csv` | every item ever listed: identifiers, key, weeks seen, versions |
| `reviews/<week>.md` | the digest, script output only |
| `bib/<week>.bib`, `bib/<week>-consensus.bib`, `bib/all.bib` | verified entries, biblatex fields |
| `notes/<week>.md` | the assistant's notes, labelled |
| `provenance/<week>.log.md` | queries, URLs, counts, versions, failures of a run |
| `provenance/search-log.md` | every Consensus search the assistant ran |
| `provenance/agent-prompts.md` | the prompts under which the scripts were written |
| `tests/` | gold set and recall, grounding check, pushback test, results table |
| `docs/` | the assistant's rules; scheduling |
| `.claude/skills/weekly-literature/` | the skill |
| `.github/workflows/weekly.yml`, `launchd/` | the clocks |

Columns of `data/normalised/<week>.csv`: `doi, arxiv_id, pmid, pmcid, title,
title_norm, authors, first_author, year, date, venue, type, preprint_server,
url, abstract_excerpt, topics, sources, n_sources, version, published_doi,
oa, uid`.

## Running it

From the repository root, with R 4.5 and `renv`:

```bash
Rscript -e 'renv::restore()'             # the exact package versions in renv.lock
Rscript R/03_check.R --self-test         # a check that can fail: three planted errors must be caught
Rscript R/02_normalise.R --self-test     # surname-first author names must parse to the right key
Rscript R/run_week.R 2026-W00 --offline  # the fixture week, no network
Rscript R/run_week.R                     # the week that ended yesterday, live
Rscript R/run_week.R 2026-W41            # a given ISO week
```

The fixture week prints `6 records read; 7 kept (0 bioRxiv records matched no
topic); 4 after the DOI merge; 4 after the arXiv-identifier merge; 3 after
the title merge` (its one bioRxiv record matches two topics), verifies two of
the three and keeps the third out of the bibliography. Running a week twice
changes nothing the second time.

The assistant, after `claude mcp login` for Consensus once:

```bash
claude -p "/weekly-literature 2026-W41" --permission-mode dontAsk \
  --allowedTools "Read,Glob,Grep,ToolSearch,Bash(claude --version),Bash(Rscript R/skill_verify.R *),Bash(Rscript tests/check_notes.R *),Edit(notes/*),Edit(provenance/search-log.md),mcp__plugin_bio-research_consensus__search,mcp__claude_ai_Consensus__search" \
  --max-turns 60 --output-format json > provenance/runs/2026-W41-assistant.json
Rscript tests/check_notes.R notes/2026-W41.md
```

## Checks

- `Rscript R/03_check.R --self-test`: the verifier catches a fake DOI, a real
  DOI with a wrong title and a fake arXiv identifier, and passes two good ones.
  A DOI is resolved on Crossref, then on DataCite (Zenodo, Figshare and most
  data repositories register there). Title similarity is 1 minus the edit
  distance over the longer normalised title, threshold 0.85; a title that is
  the other without its subtitle also passes. Identifiers verified in an
  earlier week are not resolved again.
- `Rscript R/02_normalise.R --self-test`: a planted Biodiversity PMC record
  whose authors are written surname first, as in MEDLINE, must give
  `Taskaeva, Anastasia A`, keep particles with the surname and produce the key
  `taskaeva2026wastewater`.
- `Rscript tests/check_notes.R --self-test` and
  `Rscript tests/check_notes.R notes/<week>.md`: every `[key]` in the notes is
  in the week's bibliography, every URL was logged or is a verified DOI.
- `Rscript tests/recall.R`: how many of the papers in `tests/gold.csv` the
  review found. Add papers you learn of elsewhere; this is the coverage test.
- `tests/pushback.md`: three false claims the assistant must refuse.
- `tests/results.csv`: one row per assistant run (model, recall, grounding,
  pushback, cost). A change of model or prompt is accepted only if these hold.

## Limits

- The raw responses are not in git (full abstracts are publisher text); the
  Action keeps them as a 90-day artifact and the log lists their MD5 sums.
  The normalised table with sixty-word excerpts is the durable record.
- bioRxiv and arXiv return whole categories; the terms in the config decide
  what is kept, so they are part of the method.
- Preprints and their journal versions arrive weeks apart; links by DOI are
  reliable, links by title are marked as such.
- The same queries run later will not return identical results: indexes
  change.
- OpenAlex meters requests without an API key against a free daily budget
  shared by every machine behind one IP address (1,000 credits a day, 10 per
  request, reset at midnight UTC, on 14 October 2026). One weekly run fits;
  repeated runs or a shared runner do not. Set `OPENALEX_API_KEY` in the
  environment; the scripts never print it. A rate-limited OpenAlex query is
  recorded as failed, with the reason, and the week goes on without it.
- Biodiversity PMC's `medline` collection is all of MEDLINE and is current;
  its full-text `pmc` collection ran about two months behind on 14 October
  2026; its `plazi` collection has no publication date and cannot be
  searched by week.
- A source that failed can be fetched again on its own:
  `Rscript R/01_fetch.R <week> --sources=biodivpmc`, then
  `Rscript R/run_week.R <week> --no-fetch` verifies and writes from the saved
  responses; the log records that no fetch happened in that run.

## Licence

Code: MIT. Reviews, notes and bibliography: CC BY 4.0. Abstract excerpts
remain their authors' and publishers'.
