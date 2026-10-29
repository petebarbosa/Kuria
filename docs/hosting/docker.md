# Self-hosting Kuria with Docker

This guide covers a production-style Kuria deployment with Docker Compose, including how to configure the RubyLLM provider path used by the AI assistant and transaction enrichment. It is the detailed companion to the self-hosting section of the [main README](../../README.md).

## What runs

The example stack in [`compose.example.yml`](../../compose.example.yml) has four services:

| Service  | Purpose                            |
| -------- | ---------------------------------- |
| `web`    | Rails application on port 3000     |
| `worker` | Sidekiq background jobs            |
| `db`     | PostgreSQL                         |
| `redis`  | Redis for Action Cable and Sidekiq |

All services join the `kuria_network` bridge network. AI requests go directly from `web`/`worker` to the hosted provider APIs over the internet; there is **no OpenCode Server service** in the stack, and none is required or started.

## Prerequisites

- Docker Engine with Docker Compose v2
- A host with enough memory for Rails, PostgreSQL, and Redis
- Provider API keys only if you want the AI assistant (see [AI provider configuration](#ai-provider-configuration-rubyllm))
- Optional: a reverse proxy that terminates TLS for your domain

## 1. Create the environment file

Start from the public example and keep your real file out of version control:

```sh
cp .env.example .env
```

Set at least:

| Variable            | Purpose                                                                 |
| ------------------- | ----------------------------------------------------------------------- |
| `SECRET_KEY_BASE`   | Required. Generate with `openssl rand -hex 64`.                         |
| `POSTGRES_PASSWORD` | Database password. Use a strong value; do not reuse an example value.   |
| `SELF_HOSTED`       | Set to `true` for self-hosted mode. The example Compose file forces it. |

The example Compose file passes through `SECRET_KEY_BASE`, the database settings, the AI provider keys, `MCP_AUTH_TOKEN`, `FREECRYPTO_API_KEY`, and `ASSISTANT_REQUESTS_PER_HOUR`. [`.env.example`](../../.env.example) documents the rest (`APP_DOMAIN`, `PAYMENTS_ENABLED`, `SMTP_*`, optional encryption keys). If you need an additional variable inside the containers, add it to the `x-rails-env` block in the Compose file and set it in `.env`.

Do **not** put real keys in `.env.example`, `compose.example.yml`, or any committed file. `.env` is ignored by git and should stay local to the deployment host.

## 2. Start the stack

```sh
docker compose -f compose.example.yml up -d --build
```

On the `web` container, the image entrypoint runs `bin/rails db:prepare` before starting the server, so the database is created or migrated on first boot. Follow the boot logs with:

```sh
docker compose -f compose.example.yml logs -f web
```

Once the app is healthy, open `http://localhost:3000` (or your configured domain). The first registration creates a new family and makes that user its administrator. Later signups can be restricted with the invite-code setting.

To stop the stack without deleting data:

```sh
docker compose -f compose.example.yml down
```

Never run `docker compose ... down -v` unless you intend to delete the PostgreSQL, Redis, application-storage, and retained OpenCode volumes.

## AI provider configuration (RubyLLM)

Kuria's assistant and transaction enrichment use RubyLLM to call hosted provider APIs directly. The supported provider accounts are:

| Account     | Canonical model reference | Credential            |
| ----------- | ------------------------- | --------------------- |
| OpenAI      | `openai/<model>`          | `OPENAI_API_KEY`      |
| OpenCode Go | `opencode_go/<model>`     | `OPENCODE_GO_API_KEY` |

`<model>` is the provider's own model identifier. The reference is always the account prefix plus that identifier; for example, a live-listed OpenAI model is selected as `openai/<model>`, and a live-listed OpenCode Go model as `opencode_go/<model>`. There is no hardcoded model list in this guide: the list changes as providers add and retire models.

### Configure the keys

Set one or both provider keys as environment variables in the deployment. The example Compose file passes them through from `.env` or the shell:

```sh
OPENAI_API_KEY=...
OPENCODE_GO_API_KEY=...
```

Alternatively, store each key in Rails encrypted credentials under the same identifier (`OPENAI_API_KEY`, `OPENCODE_GO_API_KEY`). The environment takes precedence when both are present. Restart the `web` and `worker` services after changing a key.

Provider keys are **never** stored in ordinary application settings. The self-hosting settings page only reports which provider accounts are connected; it does not persist or display the key. Provider keys are never written to logs or error responses and are excluded from telemetry, so do not paste them into issue reports or support requests.

### Explicit model selection — no default, no fallback

After a key is configured and the app is restarted, the model picker lists the models that are **currently available for that account**. Availability is computed from Kuria's verified Chat Completions catalog intersected with the account's live model list. A model that exists only in the static catalog, or only in the live list, is not selectable.

- There is no deployment default model and no automatic model choice.
- Each chat explicitly selects a model; the choice is saved on that chat.
- If a previously saved model is no longer available, the picker shows that the selection is unavailable and asks the user to choose again. Kuria never silently replaces it with another model.
- If the live model list cannot be fetched, the picker fails closed and reports that models are unavailable. It does not fall back to a static list or to a different provider.

The same rules apply to transaction enrichment. An administrator chooses the family's enrichment model under **Settings → Account → Transaction enrichment model**. The saved reference is revalidated against the live catalog; a stale reference is shown as unavailable and fails safely until an administrator reselects. Enrichment has no default model either.

### Supported protocols and pinned RubyLLM behavior

Both provider accounts use the **OpenAI-compatible Chat Completions** protocol. Kuria pins RubyLLM `2.1.1` and passes catalog-admitted models with `assume_model_exists: true`; it does not refresh or depend on RubyLLM's bundled model registry.

The following protocols are **not enabled** and their model references are rejected:

- OpenAI **Responses**-only models
- **Anthropic Messages** models
- **Gemini** models

A rejected reference fails with a clear unsupported-model error. Kuria does not translate a request to another protocol, downgrade the model, or substitute a fallback.

OpenCode Go is reached through its hosted OpenAI-compatible inference endpoint, not an OpenCode Server or local runtime:

- Chat Completions: `https://opencode.ai/inference/go/openai/v1/chat/completions`
- Model list: `https://opencode.ai/inference/go/v1/models`

## Optional: independent MCP endpoint

Kuria exposes an MCP endpoint at `POST /mcp`. It is an **optional, independent integration** for MCP clients; it is not an LLM provider and is separate from the RubyLLM path. It does not require, start, or proxy an OpenCode Server.

Set `MCP_AUTH_TOKEN` and send it as a Bearer token:

```sh
MCP_AUTH_TOKEN=...
```

```http
POST /mcp
Authorization: Bearer <token>
```

The endpoint rejects requests with `401 Unauthorized` when no token is configured or the token does not match. Leave `MCP_AUTH_TOKEN` blank if you do not use MCP clients; the rest of the application is unaffected. The example Compose file passes the variable through but starts no MCP-specific service.

## Assistant request limit

Assistant requests are rate limited per authenticated user (web and API) at `ASSISTANT_REQUESTS_PER_HOUR`, defaulting to `100`. Requests over the limit are rejected before any provider work. An invalid value fails loudly instead of silently disabling the limit.

## Transaction proposal confirmation

The assistant's `propose_transaction` tool only prepares an inspectable `PendingAction` with a 10-minute TTL and preview; it never creates or mutates a transaction. A prepared proposal is executed through the authenticated web endpoint:

```http
POST /pending_actions/:id/confirm
```

The endpoint requires an authenticated user session and returns JSON. The first confirmation executes the transaction exactly once and records the confirming user and the execution status on both the pending action and the tool-call audit. Replays return `422 Unprocessable Entity` with reason `already_confirmed`, expired proposals return `422` with reason `expired`, and a proposal belonging to another family returns `404 Not Found`; none of these execute again. If execution itself fails, the response is `422` with `status: "confirmed"` and `execution_status: "failed"`.

There are no in-chat confirmation controls yet: the assistant exposes no confirmation tool and the chat UI renders no confirm action, so confirmation is endpoint-based only. The `pending_confirmation` tool result carries the `pending_action_id` and preview that the endpoint needs.

## Current limitations

Remaining work is tracked in GitHub issues. In this checkout:

| Issue | Status  | Scope                                                                                      |
| ----- | ------- | ------------------------------------------------------------------------------------------ |
| #21   | Pending | Produce the RubyLLM readiness acceptance report.                                           |
| #31   | Pending | Complete the RubyLLM-only cutover and retire remaining OpenCode Server code/configuration. |

RubyLLM is the only LLM path used by the assistant and enrichment in this checkout, and the example Compose stack has no OpenCode Server service. #31 remains open because legacy OpenCode Server code and configuration still exist in the codebase; the cutover is not claimed complete until that issue is finished.

Unsupported or deferred operations fail safely: they surface as a failed provider response, a form alert, or a rejected model selection. They never report placeholder success or silently substitute a model.

## Optional live compatibility smoke tests

The live OpenAI/OpenCode Go compatibility tests are **opt-in only** and are not part of routine CI. They are skipped unless explicitly enabled. No live validation has been run in this checkout, so the harnesses describe coverage, not proven provider parity.

Run them from a development checkout where the `test` bundle is installed (not inside the production image, which excludes test gems):

```sh
export KURIA_LIVE_LLM_TESTS=1
export KURIA_LIVE_OPENAI_MODEL=openai/<model>
export KURIA_LIVE_OPENCODE_GO_MODEL=opencode_go/<model>
# OPENAI_API_KEY / OPENCODE_GO_API_KEY are read from the environment.

DISABLE_PARALLELIZATION=true bin/rails test test/live
```

Only set `KURIA_LIVE_LLM_TESTS` and the model variables for a deliberate smoke run. Credentials are gated and read only from `OPENAI_API_KEY` / `OPENCODE_GO_API_KEY`; never commit them or put them in the test command. The tests use tiny prompts and a harmless local echo tool, not production financial data. See [`test/live/README.md`](../../test/live/README.md) for the full safety model and coverage.

## Historical OpenCode data

Historical OpenCode data is retained. The example Compose file keeps an `opencode-config` volume declared, even though no current service mounts it; leave it in place during upgrades. No history columns (including chat session identifiers) are dropped, and no destructive migration removes them.

Do not delete the `opencode-config` volume, and do not use `down -v` as part of a normal upgrade. If you intentionally discard historical data, do it as an explicit, backed-up operation.

## Operations

### Logs and health

```sh
docker compose -f compose.example.yml ps
docker compose -f compose.example.yml logs -f web worker
```

### Upgrades

```sh
git pull
docker compose -f compose.example.yml up -d --build
```

The `web` entrypoint runs `bin/rails db:prepare` on boot, applying pending migrations. Back up the database before a major upgrade.

### Backups

Back up at minimum:

- the PostgreSQL data volume (`postgres-data`)
- the Rails storage volume (`app-storage`)
- the retained `opencode-config` volume, if you may need historical OpenCode data

Redis is a cache/queue and does not need a backup for normal operation.

### TLS and domains

The example stack publishes port 3000 directly and sets `RAILS_FORCE_SSL=false` / `RAILS_ASSUME_SSL=false`. For a public deployment, terminate TLS at a reverse proxy and forward requests to the `web` service. If the app must be aware of the external domain or proxy SSL behavior, add `APP_DOMAIN` and the relevant SSL variables to the `x-rails-env` block and set them in `.env`.

## Troubleshooting

| Symptom                                            | Check                                                                                                                                                                          |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Model picker says no models are available          | Confirm at least one provider key is set, then restart `web` and `worker`. A key set only in a shell that Compose cannot see has no effect.                                    |
| Model picker says models are unavailable right now | The live model-list request failed. Check outbound network access, the provider status, and that the key is valid. Kuria fails closed rather than using a static list.         |
| A model reference is rejected                      | Use a currently listed `openai/<model>` or `opencode_go/<model>` reference. Responses-only, Anthropic Messages, and Gemini references are unsupported.                         |
| A saved model stops working                        | The provider retired it or the live list changed. Reselect a model in the chat or in **Settings → Account → Transaction enrichment model**; Kuria will not choose one for you. |
| Assistant requests return a rate-limit error       | Raise `ASSISTANT_REQUESTS_PER_HOUR` or wait for the window to reset.                                                                                                           |
| MCP requests return `401`                          | Set `MCP_AUTH_TOKEN` and send the same value as a Bearer token.                                                                                                                |
| `web` exits during boot                            | Inspect `docker compose -f compose.example.yml logs web`; the usual causes are a blank `SECRET_KEY_BASE`, an unreachable database, or a failed migration.                      |
