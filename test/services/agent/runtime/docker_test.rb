require "test_helper"

class Agent::Runtime::DockerTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rt-docker@example.com", password: "password123")
    @conversation = @user.conversations.create!
    @runtime = Agent::Runtime::Docker.new(conversation: @conversation)
    @workspace = Agent::Workspace.persistent(@conversation)
    # Never shell out to `docker` for teardown in a unit test.
    @runtime.define_singleton_method(:remove_container) { nil }
  end

  teardown do
    FileUtils.rm_rf(Agent::Workspace::PERSISTENT_ROOT.join("u#{@user.id}"))
  end

  # Swap PiAgent.session so #run never spawns `docker run`.
  def with_pi_session(session)
    original = PiAgent.method(:session)
    PiAgent.define_singleton_method(:session) { |*, **| session }
    yield
  ensure
    PiAgent.define_singleton_method(:session, original)
  end

  def fake_session
    session = Object.new
    def session.closed? = @closed
    def session.close = (@closed = true)
    session
  end

  def with_docker_runtime(value)
    config = Rails.application.config.x.agent
    original = config.docker_runtime
    config.docker_runtime = value
    yield
  ensure
    config.docker_runtime = original
  end

  def with_search_config(serper: nil, brave: nil, searxng: nil)
    config = Rails.application.config.x.agent
    originals = [ config.serper_api_key, config.brave_search_api_key, config.searxng_url ]
    config.serper_api_key = serper
    config.brave_search_api_key = brave
    config.searxng_url = searxng
    yield
  ensure
    config.serper_api_key, config.brave_search_api_key, config.searxng_url = originals
  end

  test "session_dir is the in-container session path" do
    assert_equal Pathname.new("/metis/sessions"), @runtime.session_dir
  end

  test "extension_paths point at the image-baked extensions dir" do
    paths = @runtime.extension_paths.map(&:to_s)
    assert_includes paths, "/metis-extensions/web-tools/index.ts"
  end

  test "docker_args does not bind-mount extensions (baked into the image)" do
    # Extensions ship inside metis-pi (docker/pi-runtime/Dockerfile), so no
    # host bind mount — that would break under Docker-in-Docker anyway.
    args = @runtime.send(:docker_args, [ "--mode", "rpc" ])
    refute(args.any? { |a| a.to_s.include?("/metis-extensions") },
      "docker_args should not mount the extensions dir")
  end


  test "runtime_info names the docker runtime and its container" do
    info = @runtime.runtime_info
    assert_equal "docker", info["runtime"]
    assert_match(/\Ametis-c#{@conversation.id}-/, info["container"])
  end

  test "docker_args wraps pi in a disposable, mounted, hardened container" do
    args = @runtime.send(:docker_args, [ "--mode", "rpc" ])

    assert_equal "run", args.first
    assert_includes args, "--rm"
    assert_includes args, "-i"
    assert_includes args, "--cap-drop"
    assert_includes args, "#{@workspace.scope_dir}:/metis"
    assert_includes args, Rails.application.config.x.agent.docker_image
    assert_equal [ "pi", "--mode", "rpc" ], args.last(3)
  end

  test "docker_args omits --runtime when no OCI runtime is configured" do
    refute_includes @runtime.send(:docker_args, [ "--mode", "rpc" ]), "--runtime"
  end

  test "docker_args injects --runtime <oci> when one is configured (e.g. gVisor)" do
    with_docker_runtime("runsc") do
      args = @runtime.send(:docker_args, [ "--mode", "rpc" ])

      idx = args.index("--runtime")
      assert idx, "expected --runtime in docker args"
      assert_equal "runsc", args[idx + 1]
    end
  end

  test "control_session passes the configured --runtime to its throwaway container" do
    captured = nil
    original = PiAgent.method(:session)
    PiAgent.define_singleton_method(:session) { |*, **kw| captured = kw[:args]; fake = Object.new; def fake.close = nil; fake }

    with_docker_runtime("runsc") do
      Agent::Runtime::Docker.control_session { |_s| nil }
    end

    idx = captured.index("--runtime")
    assert idx, "expected --runtime in control_session args"
    assert_equal "runsc", captured[idx + 1]
  ensure
    PiAgent.define_singleton_method(:session, original)
  end

  test "docker_args forwards credential env vars with the bare-key form (no token in argv)" do
    # `--env NAME` (no value) tells docker to read NAME from the parent
    # process's env. PiAgent.session(env:) puts the value there. This
    # keeps the bearer out of argv where `ps` could see it.
    args = @runtime.send(:docker_args, [ "--mode", "rpc" ], env: { "GH_TOKEN" => "secret-bearer" })

    gh_index = args.each_index.find { |i| args[i] == "--env" && args[i + 1] == "GH_TOKEN" }
    assert gh_index, "expected --env GH_TOKEN in docker args"
    refute_includes args, "GH_TOKEN=secret-bearer", "bearer must not appear inline in argv"
    refute_includes args, "secret-bearer", "bearer must not appear inline in argv"
  end

  test "sandbox_env carries GH_TOKEN and git identity when the user has a covering GitHub grant" do
    @user.oauth_grants.create!(
      provider: "github", access_token: "live-bearer", refresh_token: "rt",
      expires_at: 1.hour.from_now, scopes: "user:email repo"
    )

    env = @runtime.sandbox_env

    assert_equal "live-bearer", env["GH_TOKEN"]
    assert_equal @user.email, env["GIT_AUTHOR_EMAIL"]
    assert_equal @user.email, env["GIT_COMMITTER_EMAIL"]
    assert_equal @user.email.split("@", 2).first, env["GIT_AUTHOR_NAME"]
  end

  test "sandbox_env is empty when the user has no GitHub or Google grant" do
    assert_empty @runtime.sandbox_env
  end

  test "sandbox_env carries GOOGLE_WORKSPACE_CLI_TOKEN when the user has a Google grant" do
    @user.oauth_grants.create!(
      provider: "google", access_token: "ya29.live-google", refresh_token: "rt",
      expires_at: 1.hour.from_now,
      scopes: "https://www.googleapis.com/auth/gmail.readonly"
    )

    env = @runtime.sandbox_env

    assert_equal "ya29.live-google", env["GOOGLE_WORKSPACE_CLI_TOKEN"]
    # gws would otherwise prompt for a desktop keyring inside the
    # headless sandbox and hang the first call.
    assert_equal "file", env["GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"]
  end

  test "sandbox_env omits a credential when its refresh fails instead of crashing the turn" do
    @user.oauth_grants.create!(
      provider: "google", access_token: "expired", refresh_token: "rt",
      expires_at: 10.seconds.ago,
      scopes: "https://www.googleapis.com/auth/gmail.readonly"
    )

    with_stub(OauthBroker::Clients::Google, :refresh, ->(_) { raise OauthBroker::Error, "google oauth status 400" }) do
      env = @runtime.sandbox_env

      assert_nil env["GOOGLE_WORKSPACE_CLI_TOKEN"]
      assert_nil env["GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"]
    end
  end

  test "sandbox_env does not set GOOGLE_WORKSPACE_CLI_TOKEN without a Google grant" do
    @user.oauth_grants.create!(
      provider: "github", access_token: "ghu_live", refresh_token: "rt",
      expires_at: 1.hour.from_now, scopes: "repo"
    )

    env = @runtime.sandbox_env

    assert_nil env["GOOGLE_WORKSPACE_CLI_TOKEN"]
    assert_nil env["GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"]
  end

  test "sandbox_env carries GH_TOKEN for a GitHub grant with empty scopes (App OAuth)" do
    # GitHub Apps don't echo OAuth scopes; legitimate connected users
    # have empty scope_set. Old gate (covers?(repo)) would never inject
    # GH_TOKEN for them; new gate is grant+token presence.
    @user.oauth_grants.create!(
      provider: "github", access_token: "ghu_live", refresh_token: "rt",
      expires_at: 1.hour.from_now, scopes: nil
    )

    assert_equal "ghu_live", @runtime.sandbox_env["GH_TOKEN"]
  end

  test "sandbox_env carries the deployment web-search config when set" do
    with_search_config(serper: "serper-key", brave: "brave-key", searxng: "https://searx.example") do
      env = @runtime.sandbox_env

      assert_equal "serper-key", env["SERPER_API_KEY"]
      assert_equal "brave-key", env["BRAVE_SEARCH_API_KEY"]
      assert_equal "https://searx.example", env["SEARXNG_URL"]
    end
  end

  test "sandbox_env omits web-search keys when the deployment sets none" do
    with_search_config(serper: nil, brave: nil, searxng: nil) do
      env = @runtime.sandbox_env

      assert_nil env["SERPER_API_KEY"]
      assert_nil env["BRAVE_SEARCH_API_KEY"]
      assert_nil env["SEARXNG_URL"]
    end
  end

  test "run provisions the workspace and yields the session — no archive" do
    session = fake_session
    yielded = nil

    with_pi_session(session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) do |s|
        yielded = s
        assert Dir.exist?(@workspace.workspace_dir), "workspace provisioned"
      end
    end

    assert_equal session, yielded
    assert session.closed?, "session closed by the runtime"
  end

  test "collects artifacts from the bind-mounted host workspace post-turn" do
    with_pi_session(fake_session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) do |_s|
        FileUtils.mkdir_p(@workspace.artifacts_dir)
        File.write(@workspace.artifacts_dir.join("chart.png"), "fakepng")
      end
    end

    assert_equal [ "chart.png" ], @runtime.artifacts.map { |a| a[:filename] }
  end

  test "files the agent writes survive into the next turn via the persistent bind mount" do
    # Drop something into the workspace during the first turn; assert it
    # is still there at the start of the second turn. This is the core
    # property of the v2 lifecycle — no archive, no reset; the host dir
    # bind-mounted into --rm containers is the conversation's memory.
    with_pi_session(fake_session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { @workspace.workspace_dir.join("wip.txt").write("hello") }
    end

    # A second runtime instance for the same conversation — a different
    # turn / different worker / no shared in-memory state.
    second_runtime = Agent::Runtime::Docker.new(conversation: @conversation)
    second_runtime.define_singleton_method(:remove_container) { nil }
    with_pi_session(fake_session) do
      second_runtime.run(pi_args: [ "--mode", "rpc" ]) do
        assert_equal "hello", @workspace.workspace_dir.join("wip.txt").read
      end
    end
  end

  test "the first turn after a workspace eviction gets the files-are-gone warning" do
    # An evicted conversation: pi has run before (backend_session_id set),
    # sessions/ survives, workspace/ is gone.
    @conversation.update_column(:backend_session_id, "sess-1")
    @workspace.ensure!
    FileUtils.rm_rf(@workspace.workspace_dir)

    with_pi_session(fake_session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { }
    end

    agents_md = @workspace.workspace_dir.join(Agent::Identity::FILENAME).read
    assert_match(/## Workspace notice/, agents_md)
  end

  test "no eviction warning on a first turn" do
    with_pi_session(fake_session) do
      @runtime.run(pi_args: [ "--mode", "rpc" ]) { }
    end

    refute_match(/## Workspace notice/, @workspace.workspace_dir.join(Agent::Identity::FILENAME).read)
  end
end
