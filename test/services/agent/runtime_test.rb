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

  test "stderr_relay tags, logs, and forwards each line" do
    logged = []
    logger = ActiveSupport::Logger.new(nil)
    logger.define_singleton_method(:warn) { |msg| logged << msg }
    forwarded = []

    relay = Agent::Runtime.stderr_relay("docker", ->(line) { forwarded << line })
    original = Rails.logger
    Rails.logger = logger
    begin
      relay.call("pi: boot failed")
    ensure
      Rails.logger = original
    end

    assert_equal [ "[docker pi stderr] pi: boot failed" ], logged
    assert_equal [ "pi: boot failed" ], forwarded
  end
end
