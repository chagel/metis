# Who may create an account. Account creation is the real access boundary:
# every user gets a personal team that runs the agent on the deployment's
# shared, paid provider keys, so anonymous signup = public agent access on
# the operator's budget. Default is invite-only — accounts come through a
# team invitation (Invitation), with the first-ever account allowed as the
# bootstrap (see ApplicationController#registration_allowed_for?).
#
#   invite_only — (default) only invitees and the first user may register
#   open        — anyone may register (single-trusted-network deployments)
#
# Test defaults to :open so the OAuth-mechanics suite exercises signup;
# the gate itself is covered by dedicated invite_only tests.
Rails.application.config.x.registration_mode =
  ENV.fetch("METIS_REGISTRATION_MODE", Rails.env.test? ? "open" : "invite_only").to_sym

# In invite-only mode, emails on these domains may also register without
# an invitation (empty = off). The password form trusts the typed address
# — there is no email confirmation — so list only domains where a claimed
# address is acceptable proof; OAuth requires a provider-verified email.
Rails.application.config.x.allowed_domains =
  ENV.fetch("METIS_ALLOWED_DOMAINS", "").split(",").map { |domain| domain.strip.downcase }.reject(&:empty?).freeze
