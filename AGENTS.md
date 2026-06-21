# General agents rules

- Refer to `/docs/specs/opencode_server.md` for AI related connections 
- Remember to check if it's needed to update `READEME.md`, `compose.yml`, `compose.example` and `.env.example`
- Make sure that `compose.example.yml` and `.env.example` does not contain any sensitive data

## Agent skills

### Issue tracker

Issues live in GitHub Issues (uses `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Seven canonical roles: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`, `ready-for-slice`, `sliced`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
