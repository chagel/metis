require "test_helper"

class LinearApp::OauthTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :body)

  test "authorize_url carries the oauth params" do
    with_stub(LinearApp::Config, :client_id, -> { "cid" }) do
      url = LinearApp::Oauth.authorize_url(redirect_uri: "https://m/cb", state: "st")

      assert_match %r{\Ahttps://linear\.app/oauth/authorize\?}, url
      assert_includes url, "client_id=cid"
      assert_includes url, "state=st"
      assert_includes url, "response_type=code"
      assert_includes url, "scope=read"
    end
  end

  test "exchange returns the parsed token payload on 200" do
    response = Response.new("200", { access_token: "tok", scope: "read" }.to_json)
    with_stub(Net::HTTP, :post_form, ->(_uri, _params) { response }) do
      tokens = LinearApp::Oauth.exchange(code: "c", redirect_uri: "https://m/cb")
      assert_equal "tok", tokens["access_token"]
    end
  end

  test "exchange raises Error on a non-200" do
    with_stub(Net::HTTP, :post_form, ->(_uri, _params) { Response.new("400", "bad") }) do
      assert_raises(LinearApp::Oauth::Error) { LinearApp::Oauth.exchange(code: "c", redirect_uri: "x") }
    end
  end

  test "refresh trades the refresh token for a fresh payload" do
    response = Response.new("200", { access_token: "new", refresh_token: "r2", expires_in: 86_400 }.to_json)
    sent = nil
    with_stub(Net::HTTP, :post_form, ->(_uri, params) { sent = params; response }) do
      tokens = LinearApp::Oauth.refresh(refresh_token: "r1")
      assert_equal "new", tokens["access_token"]
    end
    assert_equal "refresh_token", sent["grant_type"]
    assert_equal "r1", sent["refresh_token"]
  end

  test "refresh raises Error on a non-200" do
    with_stub(Net::HTTP, :post_form, ->(_uri, _params) { Response.new("401", "nope") }) do
      assert_raises(LinearApp::Oauth::Error) { LinearApp::Oauth.refresh(refresh_token: "r1") }
    end
  end
end
