# Live provider compatibility smoke tests (#19)

These tests establish protocol compatibility for a normal OpenAI account and an
OpenCode Go subscription. They are **opt-in only** and must never be part of
routine CI. No live validation has been run in this checkout; production
OpenCode Go routing/header compatibility remains blocked as described below.

## Safety model

- Every test first checks `KURIA_LIVE_LLM_TESTS=1` **and** the provider
  credential before any catalog, model-list, or provider request.
- Missing configuration is reported with the environment variable name only.
  Credentials are never printed, compared, inspected, or copied into errors.
- No live model calls run during a normal `bin/rails test` because the explicit
  flag is absent. The tests are reported as skipped.
- Prompts are tiny, requests are bounded, and the harness implements no
  retries.
- The only tool is a local `echo_marker` function. No real financial data or
  production records are sent.
- Live network access is enabled only inside `LiveProviderHelper.with_live_network`;
  WebMock's previous restrictions are restored even when the block raises.

## Required environment

| Variable | Purpose |
| --- | --- |
| `KURIA_LIVE_LLM_TESTS` | Must be exactly `1` to enable any live test. |
| `OPENAI_API_KEY` | OpenAI credential; required for OpenAI tests. |
| `OPENCODE_GO_API_KEY` | OpenCode Go credential; required for Go tests. |
| `KURIA_LIVE_OPENAI_MODEL` | Explicit `openai/<model>` reference. There is no default. |
| `KURIA_LIVE_OPENCODE_GO_MODEL` | Explicit `opencode_go/<model>` reference. There is no default. |

Set the two model references to models that are currently available for the
matching account and already admitted by Kuria's Chat Completions catalog. The
harness never selects a model automatically and never substitutes a fallback.

Example (keys are exported by the operator, not committed):

```sh
export KURIA_LIVE_LLM_TESTS=1
export KURIA_LIVE_OPENAI_MODEL=openai/gpt-5.4-mini
export KURIA_LIVE_OPENCODE_GO_MODEL=opencode_go/glm-5.3-flash

DISABLE_PARALLELIZATION=true bin/rails test test/live
```

The isolated lane wrapper can be used for a focused run, for example:

```sh
DISABLE_PARALLELIZATION=true .slim/test-support/run integration bin/rails test test/live
```

Use whichever configured lane is appropriate in the current checkout.

## Coverage

The live suite has two layers: a direct Chat Completions HTTP protocol harness
and production-seam tests through `Provider::RubyLlm`.

### Raw HTTP protocol harness

`llm_compatibility_test.rb` covers:

- OpenAI and OpenCode Go selected independently in the same process from
  separate explicit references, credentials, and API bases.
- Direct developer-role acceptance on OpenAI Chat Completions.
- Direct system-role acceptance on OpenCode Go Chat Completions.
- Ordered streaming with `stream_options.include_usage: true` and a usage
  object for both providers.
- One harmless local `echo_marker` tool-call check for both providers.
- Strict JSON-schema structured output for both providers.
- Real bearer behavior for OpenCode Go: a valid bearer succeeds and an invalid
  bearer is rejected with `401`/`403`.

Most of these are direct HTTP protocol checks. The older file also retains one
OpenAI `Provider::RubyLlm` developer-instructions check and a production Go
check that skips on the blocker described below; the new production-seam file
adds the bounded adapter checks below.

Known Responses-only, Anthropic Messages, and Gemini model references are
rejected with a clear unsupported-model message. If the configured reference is
not in Kuria's Chat Completions catalog, the harness fails closed instead of
downgrading or choosing another model.

### Production `Provider::RubyLlm` seam

`ruby_llm_compatibility_test.rb` exercises the adapter path the application
uses:

- Streamed `output_text` chunks concatenate to the final response content, and
  exactly one final response chunk carries that completed response.
- A harmless local `echo_marker_seam` tool is actually executed by RubyLLM and
  appears in the audit tool-call and tool-result events.
- Strict structured synthetic auto-categorization returns a
  provider-independent `Provider::LlmConcept::AutoCategorization`.
- Explicit OpenAI and OpenCode Go references are selected independently. The
  dual-selection test skips when the known production Go routing/header blocker
  is present instead of claiming parity.

The production-seam file also contains a deterministic gate assertion that runs
without any network access.

## OpenCode Go canonical transport

The documented canonical endpoints verified by the harness are:

- Chat Completions: `https://opencode.ai/inference/go/openai/v1/chat/completions`
- Model list: `https://opencode.ai/inference/go/v1/models`

The canonical transport sends:

- `Authorization: Bearer <token>`
- `x-opencode-session: <stable per-conversation id>`
- a client-specific `User-Agent`

A successful model-list response is **availability evidence only**. It does
not validate credentials. Authentication is proven by an actual chat
completion, including the invalid-bearer rejection test.

Kuria's production OpenCode Go routing is currently the legacy
`https://opencode.ai/zen/go/v1` base and does not send `x-opencode-session` or a
client-specific `User-Agent`. Issue #19 does **not** change production routing.
Both live files therefore detect and report those blockers and explicitly skip
their production Go checks instead of claiming parity. The documented canonical
transport is verified separately by the raw HTTP protocol tests.

## Deterministic harness tests

The deterministic helper test proves the gate, missing-key behavior, explicit
model selection, header shape, context isolation through the existing provider
boundary, SSE ordering/usage parsing, and WebMock restoration without any
provider call:

```sh
DISABLE_PARALLELIZATION=true bin/rails test test/support/live_provider_helper_test.rb
```

`ruby_llm_compatibility_test.rb` also contains a deterministic gate assertion
that proves the gate rejects missing opt-in/credential state before any
production-seam catalog or network work.

To prove both live files are inert without the flag, run:

```sh
DISABLE_PARALLELIZATION=true bin/rails test test/live
```

The expected result is the live tests skipped with no provider requests; the
deterministic gate assertion passes without network access.

## Version note

The harness targets the installed RubyLLM `2.1.1` API and does not modify or
upgrade it. OpenAI/Go catalog admission still comes from Kuria's provider
catalog; the live harness only adds optional compatibility evidence.
