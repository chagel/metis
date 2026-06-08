require "test_helper"

class Agent::RuntimeTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rtsel@example.com", password: "password123")
    @conversation = @user.conversations.create!
  end

  def with_runtime_config(name)
    original = Rails.application.config.x.agent.runtime
    Rails.application.config.x.agent.runtime = name
    yield
  ensure
    Rails.application.config.x.agent.runtime = original
  end

  test "for resolves :local to Runtime::Local" do
    with_runtime_config(:local) do
      assert_instance_of Agent::Runtime::Local, Agent::Runtime.for(@conversation)
    end
  end

  test "for resolves :docker to Runtime::Docker" do
    with_runtime_config(:docker) do
      assert_instance_of Agent::Runtime::Docker, Agent::Runtime.for(@conversation)
    end
  end

  test "for resolves :e2b to Runtime::E2b" do
    with_runtime_config(:e2b) do
      assert_instance_of Agent::Runtime::E2b, Agent::Runtime.for(@conversation)
    end
  end

  test "for raises Agent::Error on an unknown runtime" do
    with_runtime_config(:nonsense) do
      assert_raises(Agent::Error) { Agent::Runtime.for(@conversation) }
    end
  end

  def with_enabled_runtimes(*names)
    original = Rails.application.config.x.agent.enabled_runtimes
    Rails.application.config.x.agent.enabled_runtimes = names
    yield
  ensure
    Rails.application.config.x.agent.enabled_runtimes = original
  end

  test "for honours the conversation's chosen runtime when enabled" do
    with_runtime_config(:local) do
      with_enabled_runtimes(:local, :docker) do
        @conversation.update!(settings: { "runtime" => "docker" })
        assert_instance_of Agent::Runtime::Docker, Agent::Runtime.for(@conversation)
      end
    end
  end

  test "for falls back to the default when the chosen runtime is not enabled" do
    with_runtime_config(:local) do
      with_enabled_runtimes(:local) do
        @conversation.update!(settings: { "runtime" => "docker" })
        assert_instance_of Agent::Runtime::Local, Agent::Runtime.for(@conversation)
      end
    end
  end

  test "for falls back to the default on an unknown chosen runtime" do
    with_runtime_config(:local) do
      @conversation.update!(settings: { "runtime" => "bogus" })
      assert_instance_of Agent::Runtime::Local, Agent::Runtime.for(@conversation)
    end
  end

  test "for keeps a locked conversation's runtime even when dropped from the menu" do
    with_runtime_config(:local) do
      with_enabled_runtimes(:local) do
        @conversation.update!(settings: { "runtime" => "e2b" }, e2b_sandbox_id: "sb_123")
        assert @conversation.runtime_locked?
        assert_instance_of Agent::Runtime::E2b, Agent::Runtime.for(@conversation)
      end
    end
  end

  test "enabled always includes the default and drops unknown ids" do
    with_runtime_config(:docker) do
      with_enabled_runtimes(:e2b, :bogus) do
        assert_equal [ :docker, :e2b ].sort, Agent::Runtime.enabled.sort
      end
    end
  end

  test "enabled hides local in production unless explicitly allowed" do
    with_runtime_config(:docker) do
      with_enabled_runtimes(:docker, :local) do
        with_stub(Rails, :env, ->() { ActiveSupport::StringInquirer.new("production") }) do
          assert_not_includes Agent::Runtime.enabled, :local
        end
      end
    end
  end

  test "selectable? is false for a single-runtime deployment" do
    with_runtime_config(:local) do
      with_enabled_runtimes(:local) do
        assert_not Agent::Runtime.selectable?
      end
    end
  end

  test "picker_options lists the default first" do
    with_runtime_config(:docker) do
      with_enabled_runtimes(:docker, :e2b) do
        assert_equal "docker", Agent::Runtime.picker_options.first.last
      end
    end
  end
end
