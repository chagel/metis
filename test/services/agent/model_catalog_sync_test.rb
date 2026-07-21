require "test_helper"

class Agent::ModelCatalogSyncTest < ActiveSupport::TestCase
  FakeSession = Struct.new(:models) do
    def available_models = models
    def close = nil
  end

  def with_pi(models)
    fake = FakeSession.new(models)
    with_stub(PiAgent, :session, ->(*, **) { fake }) { yield }
  end

  def with_runtime_config(runtime)
    original = Rails.application.config.x.agent.runtime
    Rails.application.config.x.agent.runtime = runtime
    yield
  ensure
    Rails.application.config.x.agent.runtime = original
  end

  PAYLOAD = [
    { "id" => "gpt-5.5", "name" => "GPT-5.5", "provider" => "openai-codex",
      "contextWindow" => 272_000, "maxTokens" => 128_000, "reasoning" => true,
      "input" => %w[text image], "cost" => { "input" => 1.75 } }
  ].freeze

  test "creates providers and models from pi's payload" do
    result = with_pi(PAYLOAD) { Agent::ModelCatalogSync.call }

    assert result[:ok]
    assert_equal 1, result[:models]

    provider = LlmProvider.find_by(key: "openai-codex")
    assert_equal "OpenAI Codex", provider.label

    model = provider.llm_models.find_by(key: "gpt-5.5")
    assert_equal "GPT-5.5", model.label
    assert_equal 272_000, model.context_window
    assert model.reasoning?
    assert_equal %w[text image], model.input_modalities
    assert_not_nil model.last_seen_at
  end

  test "a refresh refreshes metadata but preserves operator curation" do
    provider = LlmProvider.create!(key: "openai-codex", label: "Custom", position: 5)
    model = provider.llm_models.create!(key: "gpt-5.5", label: "My GPT", enabled: false,
                                        position: 9, context_window: 1)

    with_pi(PAYLOAD) { Agent::ModelCatalogSync.call }

    assert_equal "Custom", provider.reload.label
    assert_not provider.enabled?
    assert_equal "My GPT", model.reload.label
    assert_not model.enabled?
    assert_equal 9, model.position
    assert_equal 272_000, model.context_window
  end

  test "ok is false and nothing is mutated when pi is unreachable" do
    result = nil
    with_stub(PiAgent, :session, ->(*, **) { raise "no pi" }) do
      result = Agent::ModelCatalogSync.call
    end

    assert_not result[:ok]
    assert_equal 0, LlmProvider.count
  end

  test "docker runtime fetches models through the configured image" do
    fake = FakeSession.new(PAYLOAD)
    captured = nil
    original_keys = Rails.application.config.x.agent.api_keys
    Rails.application.config.x.agent.api_keys = { "openai" => "sk-test" }

    with_runtime_config(:docker) do
      with_stub(Agent::Runtime::Docker, :transport_factory, ->(args, env) { captured = [ args, env ]; nil }) do
        with_stub(PiAgent, :session, ->(**) { fake }) do
          Agent::ModelCatalogSync.call
        end
      end
    end

    args, env = captured
    assert_includes args, Rails.application.config.x.agent.docker_image
    assert_equal({ "OPENAI_API_KEY" => "sk-test" }, env)
  ensure
    Rails.application.config.x.agent.api_keys = original_keys
  end
end
