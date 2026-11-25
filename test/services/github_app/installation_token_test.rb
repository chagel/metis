require "test_helper"

class GithubApp::InstallationTokenTest < ActiveSupport::TestCase
  def with_env(env)
    previous = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    yield
  ensure
    env.each_key { |k| previous.key?(k) ? ENV[k] = previous[k] : ENV.delete(k) }
  end

  # A throwaway RSA key so app_jwt can actually sign during tests that
  # exercise it; most tests stub `mint` and never reach signing. Stored
  # base64, the canonical env form.
  def configured(&block)
    key = Base64.strict_encode64(OpenSSL::PKey::RSA.new(2048).to_pem)
    with_env("GITHUB_APP_ID" => "123456", "GITHUB_APP_PRIVATE_KEY" => key, &block)
  end

  test "raises when the deployment can't mint installation tokens" do
    with_env("GITHUB_APP_ID" => "", "GITHUB_APP_PRIVATE_KEY" => "") do
      error = assert_raises(GithubApp::InstallationToken::Error) do
        GithubApp::InstallationToken.for("42")
      end
      assert_match(/not configured/, error.message)
    end
  end

  test "resolves the App's sole installation when no id is given" do
    configured do
      with_stub(GithubApp::InstallationToken, :installation_ids, -> { [ "555" ] }) do
        with_stub(GithubApp::InstallationToken, :mint, ->(id) { "ghs_#{id}" }) do
          assert_equal "ghs_555", GithubApp::InstallationToken.for
        end
      end
    end
  end

  test "uses GITHUB_APP_INSTALLATION_ID over resolution when set" do
    configured do
      with_env("GITHUB_APP_INSTALLATION_ID" => "999") do
        # installation_ids is left unstubbed — the override must short-circuit
        # before any network lookup.
        with_stub(GithubApp::InstallationToken, :mint, ->(id) { "ghs_#{id}" }) do
          assert_equal "ghs_999", GithubApp::InstallationToken.for
        end
      end
    end
  end

  test "raises when there is no installation to resolve" do
    configured do
      with_stub(GithubApp::InstallationToken, :installation_ids, -> { [] }) do
        error = assert_raises(GithubApp::InstallationToken::Error) { GithubApp::InstallationToken.for }
        assert_match(/no installations/, error.message)
      end
    end
  end

  test "raises naming the env var when the installation is ambiguous" do
    configured do
      with_stub(GithubApp::InstallationToken, :installation_ids, -> { [ "1", "2" ] }) do
        error = assert_raises(GithubApp::InstallationToken::Error) { GithubApp::InstallationToken.for }
        assert_match(/GITHUB_APP_INSTALLATION_ID/, error.message)
      end
    end
  end

  test "funnels network/signing/parse failures into Error" do
    # bot_entry rescues only Error and runs every turn — a GitHub blip
    # must not bubble out as a raw Net::OpenTimeout and break the turn.
    configured do
      with_env("GITHUB_APP_INSTALLATION_ID" => "42") do
        with_stub(GithubApp::InstallationToken, :mint, ->(_id) { raise Net::OpenTimeout, "timed out" }) do
          error = assert_raises(GithubApp::InstallationToken::Error) { GithubApp::InstallationToken.for }
          assert_match(/Net::OpenTimeout/, error.message)
        end
      end
    end
  end

  test "returns the minted token" do
    configured do
      with_stub(GithubApp::InstallationToken, :mint, ->(_id) { "ghs_minted" }) do
        assert_equal "ghs_minted", GithubApp::InstallationToken.for("42")
      end
    end
  end

  test "caches the token across calls for the same installation" do
    configured do
      store = ActiveSupport::Cache::MemoryStore.new
      calls = 0
      minter = ->(_id) { calls += 1; "ghs_#{calls}" }
      with_stub(Rails, :cache, -> { store }) do
        with_stub(GithubApp::InstallationToken, :mint, minter) do
          assert_equal "ghs_1", GithubApp::InstallationToken.for("42")
          assert_equal "ghs_1", GithubApp::InstallationToken.for("42")
        end
      end
      assert_equal 1, calls, "expected the token to be minted once and cached"
    end
  end

  test "installations lists id and account for each install" do
    configured do
      body = [ { "id" => 1, "account" => { "login" => "acme", "type" => "Organization" } } ].to_json
      fake = Struct.new(:code, :body).new("200", body)
      with_stub(GithubApp::InstallationToken, :signed_request, ->(_klass, _path) { fake }) do
        assert_equal [ { "id" => "1", "login" => "acme", "type" => "Organization" } ],
                     GithubApp::InstallationToken.installations
      end
    end
  end

  test "installations raises Error when unconfigured or GitHub rejects" do
    with_env("GITHUB_APP_ID" => "", "GITHUB_APP_PRIVATE_KEY" => "") do
      assert_raises(GithubApp::InstallationToken::Error) { GithubApp::InstallationToken.installations }
    end

    configured do
      fake = Struct.new(:code, :body).new("401", "{}")
      with_stub(GithubApp::InstallationToken, :signed_request, ->(_klass, _path) { fake }) do
        error = assert_raises(GithubApp::InstallationToken::Error) { GithubApp::InstallationToken.installations }
        assert_match(/401/, error.message)
      end
    end
  end

  test "app_jwt signs an RS256 token issued by the configured app id" do
    configured do
      jwt = GithubApp::InstallationToken.send(:app_jwt)
      payload, header = JWT.decode(jwt, nil, false)

      assert_equal "RS256", header["alg"]
      assert_equal "123456", payload["iss"]
      assert_operator payload["exp"], :>, payload["iat"]
    end
  end
end
