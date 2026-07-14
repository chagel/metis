require "test_helper"

class XApp::OauthTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :body)

  class FakeHttp
    attr_reader :last_request

    def initialize(response) = @response = response

    def request(req)
      @last_request = req
      @response
    end
  end

  def with_config(&block)
    with_stub(XApp::Config, :client_id, -> { "cid" }) do
      with_stub(XApp::Config, :client_secret, -> { "csec" }) do
        with_stub(XApp::Config, :redirect_uri, -> { "https://m/settings/connectors/x/callback" }, &block)
      end
    end
  end

  def with_http(response)
    http = FakeHttp.new(response)
    with_config do
      with_stub(XApp::Oauth, :https_client, ->(_uri) { http }) { yield http }
    end
  end

  test "authorize_url carries the exact oauth + PKCE params" do
    with_config do
      url = XApp::Oauth.authorize_url(state: "st", code_challenge: "chal")
      query = Rack::Utils.parse_query(URI(url).query)

      assert url.start_with?("https://x.com/i/oauth2/authorize?")
      assert_equal "code", query["response_type"]
      assert_equal "cid", query["client_id"]
      assert_equal "https://m/settings/connectors/x/callback", query["redirect_uri"]
      assert_equal "tweet.read tweet.write users.read bookmark.read bookmark.write offline.access", query["scope"]
      assert_equal "st", query["state"]
      assert_equal "chal", query["code_challenge"]
      assert_equal "S256", query["code_challenge_method"]
    end
  end

  test "exchange posts the code with the verifier and Basic client auth" do
    response = Response.new("200", { access_token: "at", refresh_token: "rt",
                                     expires_in: 7200, scope: "tweet.read users.read" }.to_json)
    with_http(response) do |http|
      tokens = XApp::Oauth.exchange(code: "c1", code_verifier: "v1")

      assert_equal "at", tokens["access_token"]
      form = Rack::Utils.parse_query(http.last_request.body)
      assert_equal "authorization_code", form["grant_type"]
      assert_equal "c1", form["code"]
      assert_equal "v1", form["code_verifier"]
      assert_equal "cid", form["client_id"]
      assert_equal "https://m/settings/connectors/x/callback", form["redirect_uri"]
      assert_equal "Basic #{[ "cid:csec" ].pack("m0")}", http.last_request["authorization"]
    end
  end

  test "refresh posts the refresh token" do
    response = Response.new("200", { access_token: "at2", refresh_token: "rt2", expires_in: 7200 }.to_json)
    with_http(response) do |http|
      tokens = XApp::Oauth.refresh("rt1")

      assert_equal "rt2", tokens["refresh_token"]
      form = Rack::Utils.parse_query(http.last_request.body)
      assert_equal "refresh_token", form["grant_type"]
      assert_equal "rt1", form["refresh_token"]
    end
  end

  test "a failure never echoes the response body into the error" do
    response = Response.new("403", { error: "client-forbidden", leaked_token: "tok-9" }.to_json)
    with_http(response) do
      error = assert_raises(XApp::Oauth::Error) { XApp::Oauth.exchange(code: "c", code_verifier: "v") }
      assert_includes error.message, "client-forbidden"
      assert_not_includes error.message, "tok-9"
    end
  end

  test "invalid_grant raises the broker's InvalidGrantError" do
    response = Response.new("400", { error: "invalid_grant" }.to_json)
    with_http(response) do
      assert_raises(OauthBroker::InvalidGrantError) { XApp::Oauth.refresh("rt-dead") }
    end
  end

  test "a 200 without an access token is an error, not a partial grant" do
    with_http(Response.new("200", "{}")) do
      assert_raises(XApp::Oauth::Error) { XApp::Oauth.exchange(code: "c", code_verifier: "v") }
    end
  end

  test "malformed JSON is an error" do
    with_http(Response.new("200", "<html>oops</html>")) do
      assert_raises(XApp::Oauth::Error) { XApp::Oauth.refresh("rt") }
    end
  end
end
