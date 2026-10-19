# Scheduling

Three ways to run the week on a clock. The fetch runs on GitHub Actions; the
assistant runs on the author's Mac, by hand at first, then under launchd.

| | GitHub Actions | launchd on the Mac | Claude cloud routine |
|---|---|---|---|
| Needs the laptop | no | yes, awake | no |
| Public log | yes: run logs and artifacts | no | the pull request |
| Secrets | `OPENALEX_API_KEY` (needed: a runner's shared address has no free OpenAlex budget to rely on) | none, if the Mac's address has budget left; otherwise the key in the job's environment | connector authentication |
| Runs R | yes | yes | not confirmed |
| Consensus (MCP, OAuth) | no | yes, after `claude mcp login` | only if Consensus can be a connector; not confirmed |
| Known limits | GitHub pauses schedules after 60 days without repository activity; a scheduled run can start late | missed slots run at the next wake | one hour minimum; a fresh clone, no local files |

## GitHub Actions

`.github/workflows/weekly.yml`: Mondays 06:00 UTC and on demand
(`workflow_dispatch`, optional `week` input). It installs R 4.5.1, restores
the `renv` library, runs the self-test of the verifier (a check that can
fail, before anything else), runs the week, uploads `data/raw/` as a 90-day
artifact, and commits `reviews/`, `bib/`, `data/normalised/`,
`data/seen.csv`, `provenance/` and `index.md` as `weekly-literature`. If a
run fails, nothing is committed; rerun it from the Actions tab with the week
as input.

To add the OpenAlex key: repository Settings → Secrets → Actions →
`OPENALEX_API_KEY`. The scripts never print it. Since 2026 a request
without a key counts against a free daily budget shared by every machine
behind one IP address (1,000 credits a day, 10 per request, on 14 October
2026); five full fetches from one laptop spent it in an afternoon, and a
shared runner's address will have spent it before the job starts.

## launchd (the Mac)

`launchd/org.paragkamian.weekly-literature.plist` runs the same scripts on
Mondays at 08:00 local time after `git pull --ff-only`. Installation and
removal commands are in the file's comment. For the assistant, copy the file
to a second label (`…weekly-literature-notes`) at 09:00 with this program
line, after a one-time interactive `claude mcp login` for Consensus:

```
cd "$HOME/projects/weekly-literature" && git pull --ff-only && \
week=$(date -v-1d +%G-W%V) && \
claude -p "/weekly-literature $week" --permission-mode dontAsk \
  --allowedTools "Read,Glob,Grep,ToolSearch,Bash(claude --version),Bash(Rscript R/skill_verify.R *),Bash(Rscript tests/check_notes.R *),Edit(notes/*),Edit(provenance/search-log.md),mcp__plugin_bio-research_consensus__search,mcp__claude_ai_Consensus__search" \
  --max-turns 60 --output-format json > "provenance/runs/$week-assistant.json" 2>> provenance/launchd.err
```

Leave `ANTHROPIC_API_KEY` unset in the job's environment, so the run uses
the subscription rather than the API. Never use
`--dangerously-skip-permissions` on a laptop.

## Claude cloud routine

If Consensus can be attached as a connector and R is available in the routine
environment, a routine created with `/schedule` (Mondays 07:00 UTC) can run
the assistant and open a pull request. Prompt:

> In savvas-paragkamian/weekly-literature on main, run `/weekly-literature
> <ISO week that ended yesterday>` exactly as the skill says. Use the
> Consensus connector only for searches. Write only `notes/<week>.md`,
> `bib/<week>-consensus.bib` through the verifier, and
> `provenance/search-log.md`. Run `Rscript tests/check_notes.R
> notes/<week>.md` and put its output in the PR description. Open a pull
> request titled "Notes <week>"; do not merge.

Both conditions were unconfirmed on 14 October 2026; test before relying on
it.
