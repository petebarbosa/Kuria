# General agents rules

- Remember to check if it's needed to update `READEME.md`, `compose.yml`, `compose.example` and `.env.example`
- Make sure that `compose.example.yml` and `.env.example` does not contain any sensitive data
- Make sure to not run all the frontend test, just the newly added ones
- This is a public repository, ALWAYS make sure no sensitive information goes into commits

## Agent skills

### Issue tracker

Issues live in GitHub Issues (uses `gh` CLI). See `docs/agents/issue-tracker.md`.

- ALWAYS close the issue related to the PR

### Triage labels

Five canonical roles: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
