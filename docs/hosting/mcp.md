# Connecting OpenCode to the Kuria MCP server

This guide describes the Kuria MCP endpoint and how to connect an OpenCode V2 client to it with a user/family OAuth token. It assumes a working Kuria deployment; see [Self-hosting Kuria with Docker](docker.md) for the stack itself.

Kuria exposes a stateless [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports) endpoint at `/mcp`. OpenCode V2 is configured as a remote MCP client; it is not an OpenCode Server deployment and does not create a global MCP token.

## Endpoint behavior

| Property | Value |
| --- | --- |
| Path | `/mcp` |
| Methods | `POST`, `GET`, `DELETE` |
| Session model | Stateless; no `Mcp-Session-Id` is issued |
| Request content type | `application/json` |
| Accepted response types | `application/json` and `text/event-stream` |
| Persistent stream | No; `GET` returns `405 Method Not Allowed` in stateless mode |
| Legacy request result | A single JSON-RPC response |
| Modern finite exchange | SSE frames are forwarded when the SDK produces a finite SSE response |

Use both accepted types in client headers:

```http
Accept: application/json, text/event-stream
Content-Type: application/json
Authorization: Bearer <user-family-oauth-token>
```

`GET` is intentionally not a long-lived SSE stream. `DELETE` is handled as a stateless success response. Do not point a streaming proxy at this endpoint expecting an open subscription stream.

## Tools and scopes

Kuria publishes nine tools. Read tools require `read`; write tools require `read_write`. Both kinds also require the exact `mcp` scope. `read_write` implies `read`, but it never implies `mcp`.

| Tool | Kind | Required scope | Purpose |
| --- | --- | --- | --- |
| `get_accounts` | Read | `mcp read` | Accounts and balance history for the authenticated family |
| `get_transactions` | Read | `mcp read` | Paginated family transactions |
| `get_balance_sheet` | Read | `mcp read` | Net worth, assets, and liabilities |
| `get_income_statement` | Read | `mcp read` | Income and expense totals by category |
| `create_transaction` | Prepare write | `mcp read_write` | Prepare a transaction proposal |
| `update_transaction` | Prepare write | `mcp read_write` | Prepare an update for an existing transaction |
| `create_or_update_budget` | Prepare write | `mcp read_write` | Prepare a monthly budget total |
| `create_or_update_budget_category` | Prepare write | `mcp read_write` | Prepare a category allocation |
| `confirm_action` | Confirm write | `mcp read_write` | Execute a previously prepared action |

The tool schemas do not expose `family_id`, `user_id`, or an idempotency key. The server binds the family from the authenticated token and rejects extra schema fields.

Write tools only prepare a `PendingAction`. The action has a ten-minute TTL and must be confirmed through `confirm_action`. Confirmation is family-scoped: an authorized user in the same family can confirm another user's proposal, and the real confirming user is recorded in the audit result. The tool description asks the client to obtain user approval, but the server does not enforce a human confirmation UI. Savepoints, audit results, and idempotency remain part of the action lifecycle.

`upsert_exchange_rates` is intentionally not part of the MCP catalog. Legacy exchange-rate pending actions are refused by `confirm_action`; there is no global exchange-rate tool.

## Required server configuration

Set `APP_DOMAIN` to the canonical public host in production. The controller allowlist is built from `APP_DOMAIN` plus the configured mailer host; the SDK adds only loopback defaults. A request whose `Host` or browser `Origin` is not allowed receives `403`.

Terminate HTTPS at your reverse proxy and preserve Rails' trusted-proxy configuration. Do not derive the allowlist from the incoming `Host` or `Origin`.

There is no global `MCP_AUTH_TOKEN` fallback and API tokens are not accepted. A mobile/API `read_write` token without `mcp` is rejected. A token with only `mcp` lacks `read` and receives `403 insufficient_scope`.

## Obtain a user/family OAuth token

Kuria uses Doorkeeper and the existing authorization-code flow with PKCE. The token is scoped to the signed-in user and their family; it is not a shared static credential.

1. Sign in to Kuria as a family administrator and create an OAuth application at `/oauth/applications`.
2. Configure it as a public client, select the scopes `mcp read` or `mcp read_write`, and use a loopback redirect URI such as `http://127.0.0.1:1455/callback`. Register the exact redirect URI you will use.
3. Start an authorization-code request with PKCE `S256`, a random `state`, and a `code_challenge` derived from your local `code_verifier`:

   ```text
   GET /oauth/authorize
     ?client_id=<client-id>
     &redirect_uri=<redirect-uri>
     &response_type=code
     &scope=mcp%20read
     &state=<random-state>
     &code_challenge=<s256-challenge>
     &code_challenge_method=S256
   ```

4. Exchange the returned code at `/oauth/token` with the matching `code_verifier`:

   ```sh
   curl -sS -X POST "https://kuria.example.com/oauth/token" \
     -H "Content-Type: application/x-www-form-urlencoded" \
     --data-urlencode "grant_type=authorization_code" \
     --data-urlencode "code=$CODE" \
     --data-urlencode "redirect_uri=$REDIRECT_URI" \
     --data-urlencode "client_id=$CLIENT_ID" \
     --data-urlencode "code_verifier=$CODE_VERIFIER"
   ```

5. Keep the access token outside the repository and outside the OpenCode process, for example in the client's environment:

   ```sh
   export KURIA_MCP_ACCESS_TOKEN='<oauth-access-token>'
   export KURIA_MCP_URL='https://kuria.example.com/mcp'
   ```

Never put a real token, client secret, authorization code, `code_verifier`, or token response in the repository, a shell history file you share, or logs. This is a manual PKCE setup; with `oauth: false`, OpenCode does not run automatic browser OAuth, discovery, dynamic client registration, or token refresh.

Do not create tokens directly through Rails as the normal user setup. Use the OAuth application flow so the token carries the user/family identity and the configured scopes.

## OpenCode V2 configuration

OpenCode V2 expects remote servers under `mcp.servers`. Add this to the user or project OpenCode configuration:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "maybe-finance": {
        "type": "remote",
        "url": "https://kuria.example.com/mcp",
        "oauth": false,
        "headers": {
          "Authorization": "Bearer {env:KURIA_MCP_ACCESS_TOKEN}"
        }
      }
    }
  }
}
```

Keep the server name `maybe-finance`: it is the prefix OpenCode uses for the tools. The environment placeholder is resolved by OpenCode at runtime. The generator and generated file never contain the token value; Kuria receives it only as the request's bearer credential.

`oauth: false` disables OpenCode's automatic MCP OAuth discovery and refresh flow. The header still carries a Doorkeeper OAuth token for one user/family; it is not a global or static server token.

Provider settings use the V2 `providers` map. An explicit provider key is shaped as:

```json
{
  "providers": {
    "openai": {
      "settings": {
        "apiKey": "{env:OPENAI_API_KEY}"
      }
    }
  }
}
```

The local generator does not read LLM provider keys during the normal rake task; `from_settings` calls it with an empty provider map. If you pass provider keys explicitly to the Ruby generator, those keys are written into the generated file, so keep that file private.

## Generate the local config

The development helper writes the V2 shape to `.opencode/opencode.json`, which is ignored by git:

```sh
bundle exec rails opencode:config:generate
```

The generator uses `OPENCODE_MCP_HOST` and `PORT` for its URL. Its default is `http://host.docker.internal:<PORT>/mcp`; that hostname works only when the OpenCode process can reach the Docker host. If you use a canonical public host, set `OPENCODE_MCP_HOST` to that host and make sure the server allowlist includes it (`APP_DOMAIN` or the mailer host). Loopback hosts are accepted by the SDK defaults.

The generated file contains the literal environment placeholder `{env:KURIA_MCP_ACCESS_TOKEN}`, never the token value. The task prints the MCP URL and provider names, and reminds you that `KURIA_MCP_ACCESS_TOKEN` needs an OAuth token with `mcp` plus `read` or `read_write`. It does not print the token.

## Token expiry and revocation

Access tokens expire. With `oauth: false`, OpenCode does not refresh them automatically. When a token expires or is revoked, obtain a new token through the same PKCE flow and update `KURIA_MCP_ACCESS_TOKEN` in the client environment.

Revoke access through the authorized applications page at `/oauth/authorized_applications` or, if your Doorkeeper configuration exposes it, the token revocation endpoint. Revoking the application invalidates its tokens; issue a new token afterward.

## Migrating an older client config

Move any V1 `mcp.<name>` entry under V2 `mcp.servers.<name>`. Remove deprecated `enabled`, `protocol`, and codemode-style settings. Migrate `provider.<id>.options.apiKey` to `providers.<id>.settings.apiKey`. Remove any old global MCP token header value; the client now supplies the OAuth token through `KURIA_MCP_ACCESS_TOKEN`, and the server no longer accepts a global MCP token.

Clients must stop sending `family_id`, `user_id`, or idempotency keys; those are server-bound or rejected by the schema.

## Security and limitations

- The token must be scoped to `mcp` and either `read` or `read_write`. A token without `mcp` is rejected; `mcp` without `read` is insufficient scope.
- OAuth scopes here authorize client behavior; Doorkeeper does not provide native RFC 8707 resource/audience binding for this endpoint. Do not treat the token as proof of a resource audience.
- The server does not implement automatic dynamic client registration or resource discovery. Pre-register the application and use PKCE manually.
- The server verifies the user and family on every request, but claims are a snapshot. The token holder remains responsible for keeping it private.
- Request-body limits are enforced by the MCP SDK, but Rails may read and filter parameters before the SDK sees the request. Early body-size rejection is therefore not guaranteed. Configure a request-size limit at the reverse proxy if you need one; this repository does not add that deployment change here.
- Do not log tokens, authorization codes, or PKCE verifiers. Do not commit generated OpenCode configuration containing provider keys.

## Optional check

With the environment variables above set, this read-only check lists the catalog. It prints no credentials:

```sh
curl -sS "$KURIA_MCP_URL" \
  -H "Authorization: Bearer $KURIA_MCP_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

A legacy exchange returns JSON. A modern finite exchange may return `text/event-stream`; read the SSE frames rather than assuming a single JSON object.

For the official client configuration reference, see [OpenCode V2 configuration](https://opencode.ai/v2/docs/config), [MCP servers](https://opencode.ai/v2/docs/mcp-servers), and [Migrate from V1](https://opencode.ai/v2/docs/migrate-v1).
