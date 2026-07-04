# Teams, membership & invitations

How people share a workspace in Metis: teams, the roles within them, and
the invitation flow that brings members in. For *why* the team is the one
tenancy unit and how authorization is modelled, see
[`tenancy.md`](tenancy.md) — this doc is the lifecycle and the surfaces.

## The team

Every durable resource (`Conversation`, `Connector`, `Skill`, …) belongs
to a `Team`. A **personal account is a team of one** — created at signup
(`User#create_personal_team`, `personal: true`), of which the user is the
sole `owner`. Shared teams are created from the team switcher
(`TeamsController#create`); `reject_personal_team!` keeps roster
operations (invite, rename, delete, leave) off personal workspaces.

### The active team

Requests act in **one** team at a time — `current_team`
(`ApplicationController`), backed by `session[:current_team_id]` and
**always re-validated against membership**, so a stale or forged id can
never reach a team the user isn't in. It falls back to the personal team
when nothing is selected. `TeamsController#switch` (`POST
/teams/:id/switch`) changes it; the breadcrumb team switcher
(`_team_switcher`) is the UI.

## Roles

`Membership` joins a user to a team with a `role` enum — `member`,
`admin`, `owner` — and is the authorization primitive. `manages_team?`
(admin **or** owner) gates the write controls:

- **member** — uses the team's shared tools; connects their own account
  to the team's connectors.
- **admin** — the above, plus curates the team: invite/revoke, add and
  configure connectors, manage skills/projects.
- **owner** — the above, plus rename/delete the team and transfer
  ownership. Exactly one owner; ownership moves via transfer, never an
  invite (`Invitation::INVITABLE_ROLES` is `member`/`admin` only).

Controller gates: `require_team_admin!`, `require_team_owner!`. These are
orthogonal to **superuser** (deployment-level LLM-catalog authority,
granted out-of-band) — see [`tenancy.md`](tenancy.md).

Member management lives in `Settings::MembershipsController`: `update`
(change role), `destroy` (remove), `transfer` (hand over ownership),
`leave` (`DELETE /settings/team/memberships/leave`).

## Invitations

An admin invites by email from `/settings/team`
(`Settings::InvitationsController#create`). An `Invitation` carries a
secure `token`, the offered `role`, and `expires_at` (14 days,
`Invitation::EXPIRES_IN`). One pending invite per email per team.

### The email

`TeamMailer.invitation` is delivered **async** (`deliver_later` →
`MailDeliveryJob`) and sent through the configured mail transport —
SMTP or Cloudflare Email Service ([`configuration.md`](configuration.md)). The
link points at the **show page** (a GET), not the POST-only accept route.

**Resend** (`#resend`) re-arms expiry (`Invitation#reissue!`) and
re-sends, throttled by a 2-minute per-invite cooldown
(`Invitation#resendable?`, keyed off `updated_at`) so the invitee can't
be spammed.

### Accepting (built for first-time invitees)

`InvitationsController#show` (`GET /invitations/:token`) is **public** —
the invitee usually has no account yet. It renders an auth-state-aware
landing:

- **signed out** → invite details + "Create your account" / "Sign in"
  (invited email pre-filled). The token is stashed in the session.
- **signed in, email matches** → a "Join" button (`POST .../accept`).
- **signed in, different email** → a "wrong account" notice.

After signing up or in, `ApplicationController#after_sign_in_path_for`
returns the user to the stashed invite — covering both password and
OAuth. `accept` is sign-in-gated and requires the signed-in email to
match the invited address (`Invitation#for?`).

### Invite-only registration

Account creation is the access boundary — every account runs the agent
on the deployment's shared provider keys — so registration is
**invite-only by default** (`METIS_REGISTRATION_MODE`, see
[`configuration.md`](configuration.md)). Both signup vectors are gated
through `ApplicationController#registration_allowed_for?`:

- the Devise form (`Users::RegistrationsController`), and
- OAuth signup (`User.from_omniauth(allow_signup:)`, raising
  `User::SignupNotAllowed`).

The invited email must match, so one invite link mints one account. The
**first account** on a deployment is always allowed (bootstrap); grant it
superuser with `rake superuser:grant[email]`. Set
`METIS_REGISTRATION_MODE=open` to allow anyone to register.

## Connectors are per-team

A team's connectors are shared: an admin adds the `Connector`, and each
member authorizes their own `ConnectorCredential` against it (the agent
acts as the right person per member). OAuth connects land on the team the
user is acting in — `current_team` rides the OAuth state and the callback
validates it against membership (`OmniauthConnector.activate_connector`).
See [`connectors.md`](connectors.md).
