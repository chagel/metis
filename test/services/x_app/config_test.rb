require "test_helper"

class XApp::ConfigTest < ActiveSupport::TestCase
  test "ENV wins over credentials per key" do
    with_stub(Rails.application.credentials, :dig, ->(*path) { "cred-#{path.join(".")}" }) do
      assert_equal "env-id", XApp::Config.client_id(env: { "X_CLIENT_ID" => "env-id" })
      assert_equal "cred-x.client_secret", XApp::Config.client_secret(env: {})
      assert_equal "cred-x.redirect_uri", XApp::Config.redirect_uri(env: {})
    end
  end

  test "configured? needs all three effective values" do
    with_stub(Rails.application.credentials, :dig, ->(*) { nil }) do
      assert_not XApp::Config.configured?(env: {})
      assert_not XApp::Config.configured?(env: { "X_CLIENT_ID" => "id", "X_CLIENT_SECRET" => "s" })
      assert XApp::Config.configured?(
        env: { "X_CLIENT_ID" => "id", "X_CLIENT_SECRET" => "s", "X_REDIRECT_URI" => "https://m/cb" }
      )
    end
  end

  test "a credentials value fills a missing ENV key" do
    with_stub(Rails.application.credentials, :dig, ->(*path) { path == [ :x, :redirect_uri ] ? "https://m/cb" : nil }) do
      assert XApp::Config.configured?(env: { "X_CLIENT_ID" => "id", "X_CLIENT_SECRET" => "s" })
    end
  end

  test "missing_keys names the unset ENV vars, never values" do
    with_stub(Rails.application.credentials, :dig, ->(*) { nil }) do
      assert_equal %w[X_CLIENT_SECRET X_REDIRECT_URI],
                   XApp::Config.missing_keys(env: { "X_CLIENT_ID" => "sekret-id" })
    end
  end

  test "the requested scopes are exactly the spec'd six" do
    assert_equal %w[tweet.read tweet.write users.read bookmark.read bookmark.write offline.access],
                 XApp::Config::SCOPES
  end
end
