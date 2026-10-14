# Search log of the assistant

Every Consensus search the assistant skill runs, one row per call, appended
during the run (rule 3 in `docs/assistant-rules.md`). The scripts' own
queries are not here: they are in each week's `provenance/<week>.log.md`.

Columns: UTC time | topic | query | papers returned | URLs exactly as returned | what was done with the result.

## Format

```
## 2026-W42

| Time (UTC) | Topic | Query | Papers | URLs | Used |
|---|---|---|---|---|---|
| 2026-10-19 09:02:11 | collembola | Collembola responses to soil disturbance | 20 | https://consensus.app/papers/... ; ... | 2 cited (keys ...), 18 not used: already seen or unverified |
```
