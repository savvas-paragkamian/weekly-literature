# Assistant run transcripts

One JSON file per headless run of the assistant skill, written by the
command in `docs/scheduling.md`:

```
claude -p "/weekly-literature <week>" ... --output-format json > provenance/runs/<week>-assistant.json
```

Each file holds the session identifier, the model, the number of turns and
the usage, which go into `tests/results.csv`. The notes themselves are in
`notes/<week>.md`; the searches in `provenance/search-log.md`.
