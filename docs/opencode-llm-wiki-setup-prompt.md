# OpenCode Prompt - LLM Wiki Setup (Karpathy Pattern, Ops-First)

You are OpenCode. Set up a persistent LLM-maintained knowledge wiki for this repository, using an ops-first structure and strict guardrails.

## Mission

Implement a full, production-grade documentation workflow where:

1. `docs/raw/*` stores immutable source material (source of truth).
2. `docs/wiki/*` stores LLM-compiled, continuously maintained knowledge.
3. `AGENTS.md` defines strict operational rules and skill-based workflows so future sessions behave consistently.

This is not a one-off scaffold. Build a durable system for incremental ingest, query, linting, and synthesis.

---

## Non-Negotiable Rules

- Use OpenCode conventions, not Claude-specific conventions.
- The control file is `AGENTS.md` at repository root.
- Create and use this structure exactly:
  - `AGENTS.md`
  - `docs/raw/*`
  - `docs/wiki/*`
- `docs/raw/*` is read-only to the LLM after ingestion (never rewrite raw sources).
- `docs/wiki/*` is LLM-owned and can be updated continuously.
- Every meaningful wiki claim must be traceable to source references.
- Every operation must append an entry to `docs/wiki/log.md`.

---

## Create This Folder Structure

Create (if missing) and preserve existing files (do not destroy existing content):

- `docs/raw/`
- `docs/raw/assets/`
- `docs/wiki/`
- `docs/wiki/index.md`
- `docs/wiki/log.md`
- `docs/wiki/sources/`
- `docs/wiki/entities/`
- `docs/wiki/analysis/`
- `docs/wiki/outputs/`
- `docs/wiki/templates/`
- `docs/wiki/schemas/`
- `docs/wiki/lint/`

Also create:

- `.opencode/skills/ingest-source/SKILL.md`
- `.opencode/skills/query-wiki/SKILL.md`
- `.opencode/skills/lint-wiki/SKILL.md`
- `.opencode/skills/synthesize-output/SKILL.md`

If `.opencode/skills/` already exists, merge safely and do not remove unrelated skills.

---

## Core 4 Skill Contracts (Mandatory)

Define these workflows both in `AGENTS.md` and inside each skill file.

### 1) `ingest-source`

Purpose: Turn one new raw source into integrated wiki knowledge.

Required behavior:

- Read one source from `docs/raw/*`.
- Create/update source summary page in `docs/wiki/sources/`.
- Update related pages in `docs/wiki/entities/` and `docs/wiki/analysis/`.
- Add backlinks and outbound links.
- Update `docs/wiki/index.md`.
- Append operation entry to `docs/wiki/log.md`.
- Include a "Source Trace" section in modified/new wiki pages.

### 2) `query-wiki`

Purpose: Answer complex repo/app questions using compiled wiki first.

Required behavior:

- Start from `docs/wiki/index.md` to locate relevant pages.
- Read targeted wiki pages before touching raw files.
- Produce cited answer in `docs/wiki/outputs/` (markdown artifact, not chat-only).
- Optionally promote durable findings into `docs/wiki/analysis/` or `docs/wiki/entities/`.
- Append to `docs/wiki/log.md`.

### 3) `lint-wiki`

Purpose: Health-check consistency and structural quality.

Required checks:

- Contradictions across wiki pages.
- Orphan pages (no inbound links).
- Broken links.
- Stale claims superseded by newer sources.
- Missing concept/entity pages for frequently mentioned terms.
- Weak source traceability.

Outputs:

- Write lint report to `docs/wiki/lint/YYYY-MM-DD-<slug>.md`.
- Propose concrete fixes.
- Apply safe auto-fixes when confidence is high.
- Log everything in `docs/wiki/log.md`.

### 4) `synthesize-output`

Purpose: Convert queries into reusable artifacts that compound knowledge.

Required outputs:

- Markdown reports by default.
- Optional slide-ready markdown (Marp style) when requested.
- Comparison tables/changelogs/onboarding briefs when relevant.

Required behavior:

- Save outputs to `docs/wiki/outputs/`.
- If output contains reusable knowledge, file it back into wiki pages.
- Update `docs/wiki/index.md` and `docs/wiki/log.md`.

---

## AGENTS.md Requirements

Generate or update `AGENTS.md` with clear, enforceable rules:

1. Operating model: Raw (immutable) -> Wiki (compiled) -> Outputs (compounding).
2. Guardrails strict mode:
   - Never edit `docs/raw/*`.
   - Always maintain source traceability.
   - Always update `index.md` and `log.md`.
3. Skill routing policy:
   - Ingest requests -> `ingest-source`
   - Question answering -> `query-wiki`
   - Quality/cleanup tasks -> `lint-wiki`
   - Deliverable generation -> `synthesize-output`
4. File ownership policy:
   - Human owns raw curation.
   - LLM owns wiki maintenance.
5. Logging format standard:
   - `## [YYYY-MM-DD] <operation> | <title>`
   - Include touched files and short rationale.
6. Citation policy:
   - Every major conclusion links to source pages (which in turn map to raw inputs).
7. Incremental update policy:
   - Prefer small, compounding edits over full rewrites.

---

## Index and Log Specifications

### `docs/wiki/index.md`

Maintain as a structured catalog:

- Group by: sources, entities, analysis, outputs, lint.
- Each entry includes:
  - Link
  - One-line summary
  - Last-updated date
  - Source-count (if applicable)

### `docs/wiki/log.md`

Append-only chronological ledger:

- Entry header format: `## [YYYY-MM-DD] <operation> | <title>`
- Include:
  - What was done
  - Why it was done
  - Files touched
  - Follow-up suggestions

---

## Templates and Schemas

Create practical templates in `docs/wiki/templates/` for:

- Source summary page
- Entity page
- Analysis page
- Output report
- Lint report

Create lightweight schema docs in `docs/wiki/schemas/` defining:

- Required frontmatter keys
- Linking conventions
- Citation block format
- Naming conventions

---

## Quality Bar (Definition of Done)

Complete only when all are true:

1. Required directory structure exists.
2. `AGENTS.md` contains the strict policy and skill routing.
3. Core 4 skills exist under `.opencode/skills/*/SKILL.md`.
4. `index.md` and `log.md` are initialized and documented.
5. Templates and schema docs exist and are coherent.
6. A short bootstrap note explains how to run first ingest/query/lint cycle.

At the end, provide:

- A concise summary of created/updated files.
- A suggested first command sequence:
  1. add first source into `docs/raw/`
  2. run `ingest-source`
  3. run `query-wiki`
  4. run `lint-wiki`
  5. run `synthesize-output`
