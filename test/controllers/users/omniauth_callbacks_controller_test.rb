require "test_helper"

class Users::OmniauthCallbacksControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  def mock_github(uid: "1", login: "mgc", email: "omni-#{SecureRandom.hex(4)}@example.com",
                  scope: "user:email", connect: nil)
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github",
      uid: uid.to_s,
      info: { email: email, nickname: login },
      credentials: {
        token: "live", refresh_token: "rt", expires_at: Time.current.to_i + 3600
      },
      # omniauth-github exposes the granted scopes on extra.scope, not
      # credentials.scope. Keep the mock shaped like the real strategy so
      # connector grants do not silently lose repo/read:user coverage.
      extra: { scope: scope }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:github]
    set_omniauth_params(connect: connect)
    email
  end

  def mock_google(uid: "g-1", email: "g-#{SecureRandom.hex(4)}@example.com", name: "User",
                  scope: "email profile", connect: nil, email_verified: true)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: uid.to_s,
      info: { email: email, name: name, email_verified: email_verified },
      credentials: {
        token: "g-live", refresh_token: "g-rt", expires_at: Time.current.to_i + 3600,
        scope: scope
      },
      extra: { raw_info: { "email_verified" => email_verified } }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2]
    set_omniauth_params(connect: connect)
    email
  end

  # The omniauth middleware copies the authorize URL's query params
  # into env["omniauth.params"]; in test_mode we bypass that so we
  # have to set them by hand for the connect flow.
  def set_omniauth_params(connect:)
    Rails.application.env_config["omniauth.params"] = connect ? { "connect" => connect } : nil
  end

  teardown do
    OmniAuth.config.mock_auth[:github] = nil
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    Rails.application.env_config["omniauth.auth"] = nil
    Rails.application.env_config["omniauth.params"] = nil
  end

  test "invite-only blocks creating an account via a first OAuth sign-in" do
    User.create!(email: "existing@example.com", password: "password123") # past the bootstrap
    mock_github(uid: "uninvited")

    with_registration_mode(:invite_only) do
      assert_no_difference([ "User.count", "Identity.count" ]) do
        get user_github_omniauth_callback_path
      end
    end
    assert_redirected_to new_user_session_path
  end

  test "first GitHub sign-in creates a user, records the identity, and records an OauthGrant — no connector yet" do
    email = mock_github(uid: "42", login: "mgc")

    assert_difference("User.count", 1) do
      assert_difference("Identity.count", 1) do
        assert_difference("OauthGrant.count", 1) do
          assert_no_difference("ConnectorCredential.count",
                               "sign-in must not auto-wire connectors — that's the Connect button's job") do
            get user_github_omniauth_callback_path
          end
        end
      end
    end

    identity = Identity.find_by(provider: "github", uid: "42")
    user = identity.user
    assert_equal email, user.email

    grant = user.oauth_grants.find_by(provider: "github")
    assert_equal "live", grant.access_token
    assert_equal "rt", grant.refresh_token
    assert_includes grant.scope_set, "user:email"
  end

  test "connecting GitHub through the Connect button additionally creates a per-member ConnectorCredential marker" do
    mock_github(uid: "42", login: "mgc", scope: "user:email repo read:user", connect: "github")

    assert_difference("User.count", 1) do
      assert_difference("ConnectorCredential.count", 1) do
        get user_github_omniauth_callback_path
      end
    end

    user = Identity.find_by(provider: "github", uid: "42").user
    cred = user.personal_team.connectors.find_by(catalog_key: "github").credential_for(user)
    assert_equal user, cred.user
    assert_equal "mgc", cred.external_login

    # The token lives in the grant, not the credential.
    grant = user.oauth_grants.find_by(provider: "github")
    assert_equal "live", grant.access_token
    assert_includes grant.scope_set, "repo"
  end

  test "connecting lands the connector on the team carried in the OAuth state, not the personal team" do
    user = User.create!(email: "conn-#{SecureRandom.hex(4)}@example.com", password: "password123")
    shared = Team.create!(name: "Acme")
    user.memberships.create!(team: shared, role: :admin)
    sign_in user

    mock_github(uid: "team-conn", scope: "user:email repo read:user", connect: "github")
    Rails.application.env_config["omniauth.params"] = { "connect" => "github", "team" => shared.id.to_s }

    get user_github_omniauth_callback_path

    assert shared.connectors.exists?(catalog_key: "github"), "connector lands on the acting team"
    refute user.personal_team.connectors.exists?(catalog_key: "github"), "not the personal team"
  end

  test "a forged team id the user isn't a member of falls back to the personal team" do
    user = User.create!(email: "conn-#{SecureRandom.hex(4)}@example.com", password: "password123")
    outsider_team = Team.create!(name: "NotMine")
    sign_in user

    mock_github(uid: "forged-team", scope: "user:email repo read:user", connect: "github")
    Rails.application.env_config["omniauth.params"] = { "connect" => "github", "team" => outsider_team.id.to_s }

    get user_github_omniauth_callback_path

    refute outsider_team.connectors.exists?(catalog_key: "github"), "must not attach to a team they're not in"
    assert user.personal_team.connectors.exists?(catalog_key: "github"), "falls back to personal team"
  end

  test "subsequent GitHub sign-in finds the user through the identity and updates the grant" do
    user = User.create!(email: "existing-#{SecureRandom.hex(4)}@example.com", password: "password123")
    user.identities.create!(provider: "github", uid: "7")
    user.oauth_grants.create!(provider: "github", access_token: "older", refresh_token: "rt0",
                              expires_at: 30.minutes.from_now, scopes: "user:email")
    mock_github(uid: "7", login: "mgc", email: "different-#{SecureRandom.hex(4)}@example.com")

    assert_no_difference([ "User.count", "Identity.count", "OauthGrant.count" ]) do
      get user_github_omniauth_callback_path
    end

    grant = user.oauth_grants.find_by(provider: "github").reload
    assert_equal "live", grant.access_token, "grant should pick up the fresh token from the callback"
  end

  test "first sign-in with no email falls back to a synthetic noreply address" do
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github", uid: "999",
      info: { email: nil, nickname: "mgc" },
      credentials: { token: "live", refresh_token: "rt", expires_at: Time.current.to_i + 3600 }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:github]

    assert_difference("User.count", 1) do
      get user_github_omniauth_callback_path
    end

    user = Identity.find_by(provider: "github", uid: "999").user
    assert_match(/\A999\+mgc@github\.users\.noreply\.metis\z/, user.email)
  end

  test "next sign-in backfills a real email onto a synthesized-email user" do
    user = User.create!(email: "777+mgc@github.users.noreply.metis",
                        password: "password123")
    user.identities.create!(provider: "github", uid: "777")
    mock_github(uid: "777", login: "mgc", email: "real@example.com")

    get user_github_omniauth_callback_path

    assert_equal "real@example.com", user.reload.email
  end

  test "next sign-in backfills a real email onto GitHub's noreply pseudo-email" do
    user = User.create!(email: "111+mgc@users.noreply.github.com",
                        password: "password123")
    user.identities.create!(provider: "github", uid: "111")
    mock_github(uid: "111", login: "mgc", email: "real@example.com")

    get user_github_omniauth_callback_path

    assert_equal "real@example.com", user.reload.email
  end

  test "backfill refuses to swap one placeholder for another" do
    user = User.create!(email: "222+mgc@users.noreply.github.com",
                        password: "password123")
    user.identities.create!(provider: "github", uid: "222")
    mock_github(uid: "222", login: "mgc", email: "222+other@users.noreply.github.com")

    get user_github_omniauth_callback_path

    assert_equal "222+mgc@users.noreply.github.com", user.reload.email
  end

  test "a missing auth email never downgrades a user who already has a real one" do
    user = User.create!(email: "real-#{SecureRandom.hex(4)}@example.com",
                        password: "password123")
    user.identities.create!(provider: "github", uid: "555")
    original = user.email
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github", uid: "555",
      info: { email: nil, nickname: "mgc" },
      credentials: { token: "live", refresh_token: "rt", expires_at: Time.current.to_i + 3600 }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:github]

    get user_github_omniauth_callback_path

    assert_equal original, user.reload.email
  end

  test "backfill skips when the real email already belongs to another user" do
    User.create!(email: "taken@example.com", password: "password123")
    synth = User.create!(email: "888+mgc@github.users.noreply.metis", password: "password123")
    synth.identities.create!(provider: "github", uid: "888")
    mock_github(uid: "888", login: "mgc", email: "taken@example.com")

    get user_github_omniauth_callback_path

    assert_equal "888+mgc@github.users.noreply.metis", synth.reload.email
  end

  test "linking a GitHub identity already owned by another user is rejected with a clear alert" do
    other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: "password123")
    other.identities.create!(provider: "github", uid: "claimed-42")

    me = User.create!(email: "me-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in me
    mock_github(uid: "claimed-42", login: "mgc", email: "me@example.com")

    assert_no_difference("Identity.count") do
      get user_github_omniauth_callback_path
    end

    assert_redirected_to root_path
    assert_match(/already linked/i, flash[:alert])
  end

  test "a connector activation failure during connect-flow does not block sign-in" do
    mock_github(uid: "conn-fail-1", login: "mgc", email: "ok@example.com",
                scope: "user:email repo read:user", connect: "github")

    with_stub(OmniauthConnector, :activate_connector, ->(*_) { raise "boom" }) do
      assert_difference("User.count", 1) do
        get user_github_omniauth_callback_path
      end
    end

    user = Identity.find_by(provider: "github", uid: "conn-fail-1").user
    assert_equal "ok@example.com", user.email
    # The grant still got recorded; sign-in completed.
    assert user.oauth_grants.exists?(provider: "github")
    # But the connector marker wasn't created — they can retry from the marketplace.
    refute user.personal_team.connectors.exists?(catalog_key: "github")
    assert_redirected_to root_path
  end

  test "a grant-write failure skips activate_connector so the marker doesn't outlive the grant" do
    mock_github(uid: "grant-fail-1", login: "mgc", email: "ok2@example.com",
                scope: "user:email repo read:user", connect: "github")

    with_stub(OmniauthConnector, :record_grant, ->(*_) { raise "grant write boom" }) do
      get user_github_omniauth_callback_path
    end

    user = Identity.find_by(provider: "github", uid: "grant-fail-1").user
    # Grant write failed.
    refute user.oauth_grants.exists?(provider: "github")
    # The marker MUST NOT be created when the grant write failed —
    # otherwise the marketplace tile would show "Connected" for a
    # connector with no backing grant, and McpConfig would drop it
    # every turn with no UI affordance to recover.
    refute user.personal_team.connectors.exists?(catalog_key: "github"),
           "connector marker must not exist when grant write failed"
  end

  test "GitHub connect-flow redirects to the App install URL when slug is configured" do
    # The GitHub App's user-to-server token can't see any repo until
    # the App is installed — sign-in alone is not enough. The
    # marketplace Connect button therefore must hand the user off to
    # the install page; without that step the OAuth grant looks
    # connected but every repo lookup 404s. Connect is always invoked
    # by an already-signed-in user (the marketplace lives behind auth).
    user = User.create!(email: "install-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in user
    mock_github(uid: "install-1", login: "mgc", email: user.email,
                scope: "user:email repo read:user", connect: "github")

    with_stub(GithubApp::Config, :install_url, -> { "https://github.com/apps/metis/installations/new" }) do
      get user_github_omniauth_callback_path
    end

    assert_redirected_to "https://github.com/apps/metis/installations/new"
    assert_match(/install the metis app/i, flash[:notice])
  end

  test "GitHub connect-flow falls back to the in-app redirect when slug is missing" do
    # No GITHUB_APP_SLUG → no install_url → we can't send the user to
    # install. Existing behavior wins; the user is on their own to
    # find the install page (which is the bug the slug closes).
    user = User.create!(email: "install2-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in user
    mock_github(uid: "install-2", login: "mgc", email: user.email,
                scope: "user:email repo read:user", connect: "github")

    with_stub(GithubApp::Config, :install_url, -> { nil }) do
      get user_github_omniauth_callback_path
    end

    assert_redirected_to root_path
    assert_match(/connected to github/i, flash[:notice])
  end

  test "GitHub sign-in (no connect param) is not affected by install_url config" do
    # The install redirect is a Connect-flow concern. First sign-in or
    # subsequent sign-ins through the omniauth flow must continue to
    # land where they always did, even with the slug configured.
    user = User.create!(email: "existing-#{SecureRandom.hex(4)}@example.com", password: "password123")
    user.identities.create!(provider: "github", uid: "no-connect-1")
    user.oauth_grants.create!(provider: "github", access_token: "older", refresh_token: "rt0",
                              expires_at: 30.minutes.from_now, scopes: "user:email")
    sign_in user
    mock_github(uid: "no-connect-1", login: "mgc", email: user.email)

    with_stub(GithubApp::Config, :install_url, -> { "https://github.com/apps/metis/installations/new" }) do
      get user_github_omniauth_callback_path
    end

    assert_redirected_to root_path
  end

  test "a signed-in password user attaches the GitHub identity to their account" do
    user = User.create!(email: "attach-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in user
    mock_github(uid: "13", login: "mgc", email: user.email)

    assert_no_difference("User.count") do
      assert_difference("Identity.count", 1) do
        get user_github_omniauth_callback_path
      end
    end

    assert user.reload.identities.exists?(provider: "github", uid: "13")
  end

  test "first Google sign-in creates the user and records an OauthGrant — no Gmail connector yet" do
    email = mock_google(uid: "g-42")

    assert_difference("User.count", 1) do
      assert_difference("OauthGrant.count", 1) do
        assert_no_difference("ConnectorCredential.count",
                             "sign-in must not auto-wire Gmail — Connect button does that") do
          get user_google_oauth2_omniauth_callback_path
        end
      end
    end

    user = Identity.find_by(provider: "google_oauth2", uid: "g-42").user
    assert_equal email, user.email

    grant = user.oauth_grants.find_by(provider: "google")
    assert_equal "g-live", grant.access_token
    assert_equal "g-rt", grant.refresh_token
    assert_includes grant.scope_set, "email"
  end

  test "connecting Gmail through the Connect button creates the Gmail ConnectorCredential" do
    # Connect-flow scope mock: base sign-in scopes + every scope the
    # gmail catalog entry declares. Keep this in sync with
    # ConnectorCatalog.find("gmail").oauth_scopes so the grant covers
    # the catalog's requirements (otherwise McpConfig drops the connector).
    gmail_scopes = ConnectorCatalog.find("gmail").oauth_scopes.join(" ")
    mock_google(uid: "g-42", scope: "email profile #{gmail_scopes}", connect: "gmail")

    assert_difference("ConnectorCredential.count", 1) do
      get user_google_oauth2_omniauth_callback_path
    end

    user = Identity.find_by(provider: "google_oauth2", uid: "g-42").user
    gmail = user.personal_team.connectors.find_by(catalog_key: "gmail")
    assert gmail, "Gmail connector should be created by the connect flow"
    cred = gmail.credential_for(user)
    # External_login stays blank for Google (no nickname); the view's
    # generic "Your Gmail account is connected" fallback covers it.
    assert_nil cred.external_login
    # The grant covers Gmail's required scopes.
    grant = user.oauth_grants.find_by(provider: "google")
    assert grant.covers?(ConnectorCatalog.find("gmail").oauth_scopes)
  end

  test "an unverified Google email does NOT take over an existing user with the same address" do
    # Without the email_verified guard, a forged email claim signs the
    # attacker in as the victim.
    victim = User.create!(email: "victim-#{SecureRandom.hex(4)}@example.com",
                          password: "password123")
    victim_email = victim.email
    mock_google(uid: "attacker", email: victim_email, email_verified: false)

    assert_difference("User.count", 1, "must create a new user, not log in as the victim") do
      get user_google_oauth2_omniauth_callback_path
    end

    identity = Identity.find_by(provider: "google_oauth2", uid: "attacker")
    refute_equal victim.id, identity.user_id
    refute_equal victim_email, identity.user.email
    assert_match(/users\.noreply\.metis\z/, identity.user.email)
  end

  test "a verified Google email DOES attach to the existing user with the same address" do
    existing = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com",
                            password: "password123")
    mock_google(uid: "g-new", email: existing.email, email_verified: true)

    assert_no_difference("User.count") do
      assert_difference("Identity.count", 1) do
        get user_google_oauth2_omniauth_callback_path
      end
    end

    assert_equal existing, Identity.find_by(provider: "google_oauth2", uid: "g-new").user
  end

  test "an existing GitHub user can sign in via Google to add the identity" do
    user = User.create!(email: "multi-#{SecureRandom.hex(4)}@example.com", password: "password123")
    user.identities.create!(provider: "github", uid: "100")
    sign_in user

    mock_google(uid: "g-100", email: user.email)
    assert_no_difference("User.count") do
      assert_difference("Identity.count", 1) do
        get user_google_oauth2_omniauth_callback_path
      end
    end

    user.reload
    assert user.identities.exists?(provider: "google_oauth2", uid: "g-100")
    assert user.oauth_grants.exists?(provider: "google"),
           "the Google grant should be recorded even without a connect"
    refute user.personal_team.connectors.exists?(catalog_key: "gmail"),
           "no connector should be wired without a connect param"
  end

  # Strategy-option lock-ins — these guard the operator's
  # config/initializers/devise.rb against silent regressions. Each
  # failed assertion has a concrete user-visible consequence; the
  # message names it so a future refactor can't strip the option by
  # accident. We parse the initializer source rather than introspect
  # Devise.omniauth_configs because the env-gated `config.omniauth`
  # blocks don't register without the OAuth env vars present at boot,
  # which Spring + dotenv-not-loaded-in-test makes unreliable.

  DEVISE_INITIALIZER_SRC = File.read(
    Rails.root.join("config/initializers/devise.rb")
  ).freeze
  private_constant :DEVISE_INITIALIZER_SRC

  def google_omniauth_block
    DEVISE_INITIALIZER_SRC[/config\.omniauth :google_oauth2.*?(?=\n\s*end\n)/m]
  end

  def github_omniauth_block
    DEVISE_INITIALIZER_SRC[/config\.omniauth :github.*?(?=\n\s*end\n)/m]
  end

  test "Google sign-in strategy stays minimal-scope + offline + incremental" do
    block = google_omniauth_block
    assert block, "no config.omniauth :google_oauth2 block found in devise.rb"

    assert_match(/scope:\s*["']email,profile["']/, block,
                 "sign-in must ask for only the minimal identity scopes — connector scopes " \
                 "are added by connector_authorize_path_for via the Connect button. " \
                 "Bloating the sign-in scope here brings back the all-or-nothing consent " \
                 "screen and the silent no-op behavior on later scope changes.")
    assert_match(/access_type:\s*["']offline["']/, block,
                 "access_type=offline is required to receive a refresh_token; without " \
                 "it Google issues only a 1-hour access token and every refresh fails.")
    assert_match(/prompt:\s*["']select_account["']/, block,
                 "prompt=select_account lets a returning user pick which Google account to " \
                 "use without forcing a re-consent on every sign-in. The per-connector " \
                 "authorize path overrides this with prompt=consent for the actual scope grant.")
    assert_match(/include_granted_scopes:\s*true/, block,
                 "include_granted_scopes lets later per-connector grants union with the " \
                 "existing one. Without it each Connect rotates the grant and prior " \
                 "connectors lose authorization.")
  end

  test "GitHub omniauth strategy requests user:email so the real address comes through" do
    block = github_omniauth_block
    assert block, "no config.omniauth :github block found in devise.rb"

    assert_match(/scope:\s*["']user:email["']/, block,
                 "scope=user:email is what tells omniauth-github to call /user/emails " \
                 "and pick the primary verified address. Drop it and every GitHub user " \
                 "whose profile email is private silently lands as a noreply placeholder.")
  end
end
