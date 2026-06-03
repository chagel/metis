# MCP OAuth connectors (Dynamic Client Registration)

How Metis can connect to the long tail of remote MCP servers — Notion,
Linear, Stripe, … — **without a pre-registered per-provider OAuth app**.
The lever is the MCP authorization spec: a server advertises its OAuth
endpoints, and a client **registers itself dynamically** at connect time.

This turns the marginal cost of a connector from *days* (register an app,
add an omniauth strategy, wire `OauthBroker`) into *one catalog row*.

## Why this exists

The endpoint of a remote MCP server is free — a `streamable-http` URL is
a one-line catalog entry. **Auth is the entire cost.** Today every OAuth
connector (`github`, `google`, `linear`) is *Metis-brokered*: a registered
OAuth app + an omniauth strategy + `OauthBroker` config, per provider.

But modern remote MCP servers authenticate through the MCP spec's own
OAuth flow, which supports **Dynamic Client Registration (DCR, RFC 7591)**.
A client discovers the server's authorization server and registers on the
fly — no human pre-registration. One implementation unlocks every
DCR-capable server.

## Verified mechanics (live, 2026-06-03)

Probing real servers:

| Server | Protected-resource metadata | `registration_endpoint` | DCR `POST /register` |
|---|---|---|---|
| **Notion** | `…/.well-known/oauth-protected-resource/mcp` | `https://mcp.notion.com/register` | `201` — public client, PKCE, no secret |
| **Linear** | `…/.well-known/oauth-protected-resource/mcp` | `https://mcp.linear.app/register` | `201` — public client, PKCE, no secret |
| **Stripe** | `…/.well-known/oauth-protected-resource` | `https://access.stripe.com/mcp/oauth2/register` | (endpoint present) |
| **Atlassian** | (not at standard paths) | — | non-standard / manual |

Both Notion and Linear returned a fresh `client_id` with
`token_endpoint_auth_method: none` — a public client using PKCE, nothing
secret to store. That is the proof: any deployment can self-register.

## The flow

```
connector.definition.url  (the MCP resource, e.g. https://mcp.notion.com/mcp)
  1. GET  /.well-known/oauth-protected-resource{/path}   → authorization_servers[0]   (RFC 9728)
  2. GET  /.well-known/oauth-authorization-server{/path} → authorize/token/register   (RFC 8414)
  3. POST {registration_endpoint}                        → client_id   (DCR / RFC 7591, cached per server)
  4. redirect browser → {authorization_endpoint}         → code        (auth-code + PKCE S256 + resource=<url>)
  5. POST {token_endpoint}                               → access + refresh token   (audience-bound, RFC 8707)
  6. McpConfig injects  Authorization: Bearer <token>    → pi-mcp-adapter talks to the server
```

Steps 1–3 are **per server** (deployment-wide); 4–6 are **per member**.

## Mapping onto Metis

Most of this already exists — it generalizes what `github` does.

| Piece | Status |
|---|---|
| `Connector` (team row) + `ConnectorCredential` (per-member marker) | reuse |
| Bearer injection for a remote `streamable-http` connector (`Agent::McpConfig#server_entry`) | **already does this** for `github` |
| Per-user token store (`OauthGrant`) | reuse, but generalize the key from a fixed provider enum to the connector/resource |
| Driving browser consent server-side (`OmniauthConnector` connect flow) | reuse the pattern; the OAuth dance is new |

**New (the only real build):**

- `Mcp::Oauth` — the OAuth client: `Discovery`, `Registration` (DCR),
  `Pkce`, plus `authorize_url` / `exchange_code`. *(Scaffolded in this
  branch; see below.)*
- A cache of DCR clients per authorization server (one `client_id` reused
  deployment-wide) — a small `mcp_oauth_clients` table.
- A **single generic callback** route (`/connectors/oauth/callback`); the
  `state` encodes connector + team + PKCE verifier.
- A new catalog `auth: mcp_oauth` type. A connector entry then collapses to:

  ```yaml
  notion:
    name: Notion
    transport: http
    definition: { url: https://mcp.notion.com/mcp }
    auth: mcp_oauth        # discover + DCR + PKCE — no oauth_provider, no scopes, no app
  ```

This is OAuth in Rails, not MCP-in-Rails: **Rails holds credentials and
runs consent** (it has the user's browser; pi is headless in a sandbox),
then hands the bearer to the adapter via `.mcp.json` — exactly the
existing `github` shape. Consistent with VISION (MCP is the default
transport; no Rails-side MCP runtime).

## Gotchas the standard imposes

1. **Well-known URL is host-inserted.** Metadata lives at
   `{scheme}://{host}/.well-known/{name}{/path}` — the path goes *after*
   the well-known name, not before. (Stripe looked DCR-less until the URL
   was built this way.) Try the host-inserted form, then a bare fallback.
2. **Resource indicator (RFC 8707) is mandatory.** Send `resource=<mcp
   url>` on both authorize and token requests so the token is
   audience-bound to that server. Omitting it → token rejected or
   over-scoped.
3. **Per-server client lifecycle.** DCR returns a `client_id` (sometimes a
   secret) per authorization server — cache and reuse deployment-wide;
   re-register on a 401-at-token (registration expired).
4. **Public vs confidential.** Notion/Linear issue public clients (PKCE,
   no secret — nothing to store). Handle the confidential case (encrypt
   the secret) for servers that issue one.
5. **Scopes often absent.** `scopes_supported` was null on all three —
   request none and let the server default, or read scopes from the
   protected-resource metadata when present.
6. **Not everyone is DCR.** Atlassian's protected-resource metadata
   wasn't at the standard paths. Classify and fall back.

## The four-state classifier

The registry sync (and the catalog) should tag each candidate connector:

- `no-auth` — public server (e.g. Microsoft Learn). Catalog row only.
- `api-key` — static token; reuse the existing token-auth credential path.
- `oauth-dcr` — advertises DCR; **this** path. Catalog row only.
- `oauth-manual` — OAuth without DCR (or non-standard); needs a
  Metis-brokered app (the legacy path) or is skipped.

Only the first three are "quick wins."

## Status in this branch (spike)

Scaffolded and unit-tested (HTTP stubbed; live behavior verified above):

- `Mcp::Oauth::Discovery` — walks resource → protected-resource → AS
  metadata, host-inserted well-known with fallback.
- `Mcp::Oauth::Registration` — RFC 7591 DCR; public client.
- `Mcp::Oauth::Pkce` — S256 verifier/challenge.
- `Mcp::Oauth.authorize_url` / `.exchange_code` — auth-code + PKCE +
  `resource` indicator.

**Not yet built (the integration, next slice):** the `mcp_oauth_clients`
cache table, the generic callback route + controller, generalizing
`OauthGrant` keying, the `auth: mcp_oauth` catalog type, and the
registry-fed candidate queue. The spike de-risks discovery + registration
— the parts the standard makes fiddly.
