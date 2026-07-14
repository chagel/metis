require "test_helper"

class OauthBrokerTest < ActiveSupport::TestCase
  def user
    @user ||= User.create!(email: "ob-#{SecureRandom.hex(4)}@example.com", password: "password123")
  end

  def grant(provider: "github", **attrs)
    user.oauth_grants.create!({
      provider: provider, access_token: "at", refresh_token: "rt",
      expires_at: 1.hour.from_now, scopes: "x"
    }.merge(attrs))
  end

  test "returns the stored access token when not near expiry" do
    g = grant(access_token: "live")

    assert_equal "live", OauthBroker.access_token_for(g)
  end

  test "refreshes through the github client when past expiry" do
    g = grant(provider: "github", access_token: "old", refresh_token: "rt0", expires_at: 10.seconds.ago)

    token = with_stub(GithubApp::OauthClient, :refresh, lambda { |_rt|
      { "access_token" => "fresh", "refresh_token" => "rt1", "expires_in" => 3600 }
    }) { OauthBroker.access_token_for(g) }

    assert_equal "fresh", token
    g.reload
    assert_equal "fresh", g.access_token
    assert_equal "rt1", g.refresh_token
  end

  test "refreshes through the google client and preserves the prior refresh token" do
    g = grant(provider: "google", access_token: "old", refresh_token: "rt-google", expires_at: 10.seconds.ago)

    # Google's refresh response omits refresh_token entirely.
    token = with_stub(OauthBroker::Clients::Google, :refresh, lambda { |_rt|
      { "access_token" => "fresh", "expires_in" => 3600, "scope" => "gmail.readonly" }
    }) { OauthBroker.access_token_for(g) }

    assert_equal "fresh", token
    assert_equal "rt-google", g.reload.refresh_token
  end

  test "a permanently dead refresh token (invalid_grant) clears the grant and raises" do
    g = grant(provider: "google", access_token: "old", refresh_token: "rt-dead", expires_at: 10.seconds.ago)

    failing = ->(_rt) { raise OauthBroker::InvalidGrantError, "google invalid_grant: token revoked or expired" }
    assert_raises(OauthBroker::InvalidGrantError) do
      with_stub(OauthBroker::Clients::Google, :refresh, failing) { OauthBroker.access_token_for(g) }
    end

    assert_not OauthGrant.exists?(g.id), "dead grant should be cleared so the next Connect re-consents"
  end

  test "the Google client raises InvalidGrantError on an invalid_grant body" do
    response = Struct.new(:code, :body).new("400", %({"error":"invalid_grant","error_description":"Token has been expired or revoked."}))

    error = assert_raises(OauthBroker::InvalidGrantError) { OauthBroker::Clients::Google.parse(response) }
    assert_match(/expired or revoked/, error.message)
  end

  test "raises on an unknown provider" do
    g = grant(expires_at: 10.seconds.ago)
    g.update_column(:provider, "bogus") # bypass validation just to exercise the broker

    assert_raises(OauthBroker::Error) { OauthBroker.access_token_for(g) }
  end

  test "raises when expired and there is no refresh token to use" do
    g = grant(access_token: "expired", refresh_token: nil, expires_at: 10.seconds.ago)

    assert_raises(OauthBroker::Error) { OauthBroker.access_token_for(g) }
  end

  test "refreshes a grant whose access_token is blank even when fresh? would say it's fine" do
    # Legacy backfill edge case: expires_at is set in the future
    # (so fresh? returns true) but access_token came over blank.
    # Returning the blank token would render `Authorization: Bearer `
    # to the MCP server. The broker must refresh instead.
    g = grant(access_token: nil, refresh_token: "rt", expires_at: 1.hour.from_now)

    token = with_stub(GithubApp::OauthClient, :refresh, lambda { |_rt|
      { "access_token" => "fresh", "refresh_token" => "rt2", "expires_in" => 3600 }
    }) { OauthBroker.access_token_for(g) }

    assert_equal "fresh", token
    assert_equal "fresh", g.reload.access_token
  end

  test "revoke sends Google's refresh token when present" do
    g = grant(provider: "google")
    called_with = nil

    with_stub(OauthBroker::Clients::Google, :revoke, ->(token) { called_with = token }) do
      OauthBroker.revoke(g)
    end

    assert_equal g.refresh_token, called_with,
                 "revoke should hit the refresh_token (the long-lived one) when available"
  end

  test "revoke sends GitHub's access token" do
    g = grant(provider: "github", access_token: "access-token", refresh_token: "refresh-token")
    called_with = nil

    with_stub(OauthBroker::Clients::Github, :revoke, ->(token) { called_with = token }) do
      OauthBroker.revoke(g)
    end

    assert_equal "access-token", called_with,
                 "GitHub's app authorization DELETE endpoint expects access_token, not refresh_token"
  end

  test "revoke swallows provider errors so the local delete can proceed" do
    g = grant(provider: "google")

    with_stub(OauthBroker::Clients::Google, :revoke, ->(_) { raise "network down" }) do
      assert_nothing_raised { OauthBroker.revoke(g) }
    end
  end

  test "bearer_for returns the access token when the grant covers the required scopes (Google)" do
    grant(provider: "google", access_token: "live",
          scopes: "email https://www.googleapis.com/auth/gmail.readonly")

    assert_equal "live", OauthBroker.bearer_for(
      user: user, provider: "google",
      required_scopes: %w[https://www.googleapis.com/auth/gmail.readonly]
    )
  end

  test "bearer_for returns nil when no grant exists for the provider" do
    assert_nil OauthBroker.bearer_for(user: user, provider: "github", required_scopes: %w[repo])
  end

  test "bearer_for returns nil when a scope-meaningful grant does not cover the required scopes" do
    grant(provider: "google", access_token: "live", scopes: "email") # no gmail scope

    assert_nil OauthBroker.bearer_for(
      user: user, provider: "google",
      required_scopes: %w[https://www.googleapis.com/auth/gmail.readonly]
    )
  end

  test "bearer_for skips the scope check for GitHub — App OAuth response carries no scopes" do
    # GitHub Apps don't echo OAuth scopes (App permissions are the real
    # gate, configured server-side at the App). grant.scopes ends up
    # empty/incomplete regardless of what we asked for, so gating on
    # `covers?` would lock out every legitimately-connected GitHub user.
    grant(provider: "github", access_token: "live", scopes: nil)

    assert_equal "live", OauthBroker.bearer_for(
      user: user, provider: "github", required_scopes: %w[repo]
    )
  end

  test "bearer_for refreshes when the grant is past expiry" do
    grant(provider: "github", access_token: "old", refresh_token: "rt0",
          expires_at: 10.seconds.ago, scopes: nil)

    token = with_stub(GithubApp::OauthClient, :refresh, lambda { |_rt|
      { "access_token" => "fresh", "refresh_token" => "rt1", "expires_in" => 3600 }
    }) { OauthBroker.bearer_for(user: user, provider: "github", required_scopes: %w[repo]) }

    assert_equal "fresh", token
  end

  test "scope_check_meaningful? is false for github and true otherwise" do
    refute OauthBroker.scope_check_meaningful?("github"),
           "GitHub App OAuth responses don't carry scopes; coverage check is unenforceable"
    assert OauthBroker.scope_check_meaningful?("google")
  end

  test "normalize_provider maps the omniauth strategy name to the canonical OauthGrant provider name" do
    assert_equal "github", OauthBroker.normalize_provider("github")
    assert_equal "google", OauthBroker.normalize_provider("google_oauth2")
    assert_nil OauthBroker.normalize_provider("twitter")
    assert_nil OauthBroker.normalize_provider(nil)
  end

  test "omniauth_strategy is the inverse of normalize_provider" do
    OauthBroker::STRATEGY_TO_PROVIDER.each_value do |provider|
      strategy = OauthBroker.omniauth_strategy(provider)
      assert strategy, "omniauth_strategy(#{provider.inspect}) returned nil"
      assert_equal provider, OauthBroker.normalize_provider(strategy)
    end
  end

  test "x is a grant provider with no omniauth strategy" do
    # X connects through Connectors::XOauthController, not Devise omniauth.
    assert_includes OauthBroker::PROVIDERS, "x"
    assert_nil OauthBroker.omniauth_strategy("x")
  end

  test "refreshes through the X client and absorbs the rotated refresh token" do
    g = grant(provider: "x", access_token: "old", refresh_token: "xrt0", expires_at: 10.seconds.ago)

    token = with_stub(XApp::Oauth, :refresh, lambda { |_rt|
      { "access_token" => "xat1", "refresh_token" => "xrt1", "expires_in" => 7200 }
    }) { OauthBroker.access_token_for(g) }

    assert_equal "xat1", token
    g.reload
    assert_equal "xat1", g.access_token
    assert_equal "xrt1", g.refresh_token
  end

  test "an X refresh response without a refresh token preserves the prior one" do
    g = grant(provider: "x", access_token: "old", refresh_token: "xrt-keep", expires_at: 10.seconds.ago)

    with_stub(XApp::Oauth, :refresh, ->(_rt) { { "access_token" => "xat1", "expires_in" => 7200 } }) do
      OauthBroker.access_token_for(g)
    end

    assert_equal "xrt-keep", g.reload.refresh_token
  end

  test "an X invalid_grant clears the grant and raises" do
    g = grant(provider: "x", access_token: "old", refresh_token: "xrt-dead", expires_at: 10.seconds.ago)

    failing = ->(_rt) { raise OauthBroker::InvalidGrantError, "x invalid_grant: token revoked or expired" }
    assert_raises(OauthBroker::InvalidGrantError) do
      with_stub(XApp::Oauth, :refresh, failing) { OauthBroker.access_token_for(g) }
    end

    assert_not OauthGrant.exists?(g.id)
  end

  test "an XApp error surfaces as a broker error" do
    g = grant(provider: "x", access_token: "old", refresh_token: "xrt", expires_at: 10.seconds.ago)

    failing = ->(_rt) { raise XApp::Oauth::Error, "x oauth refresh status 500: unexpected response" }
    error = assert_raises(OauthBroker::Error) do
      with_stub(XApp::Oauth, :refresh, failing) { OauthBroker.access_token_for(g) }
    end
    assert_match(/status 500/, error.message)
    assert OauthGrant.exists?(g.id), "a transient failure must not delete the grant"
  end

  test "revoke sends X's refresh token" do
    g = grant(provider: "x", access_token: "xat", refresh_token: "xrt")
    called_with = nil

    with_stub(XApp::Oauth, :revoke, ->(token) { called_with = token }) do
      OauthBroker.revoke(g)
    end

    assert_equal "xrt", called_with
  end
end
