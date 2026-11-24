require "test_helper"

class Agent::CatalogTest < ActiveSupport::TestCase
  def seed_catalog
    anthropic = LlmProvider.create!(key: "anthropic", label: "Anthropic", position: 1)
    anthropic.llm_models.create!(key: "claude-opus-4-8", label: "Claude Opus 4.8", position: 1)
    codex = LlmProvider.create!(key: "openai-codex", label: "OpenAI Codex", position: 2)
    codex.llm_models.create!(key: "gpt-5.5", label: "GPT-5.5", position: 1)
    [ anthropic, codex ]
  end

  test "providers reflects enabled rows grouped by provider, in order" do
    seed_catalog

    assert_equal %w[Anthropic], Agent::Catalog.providers.map { |p| p[:label] }.first(1)
    assert_equal [ "Anthropic", "OpenAI Codex" ], Agent::Catalog.providers.map { |p| p[:label] }
  end

  test "disabled providers and models are excluded" do
    _anthropic, codex = seed_catalog
    codex.set_enabled!(false)

    assert_equal [ "Anthropic" ], Agent::Catalog.providers.map { |p| p[:label] }
  end

  test "is empty when the catalog has no rows" do
    assert_empty Agent::Catalog.providers
    assert_nil Agent::Catalog.provider_for("anything")
  end

  test "known_model needs an enabled catalog model" do
    assert_not Agent::Catalog.known_model?("gpt-5.5")
    seed_catalog
    assert Agent::Catalog.known_model?("gpt-5.5")
  end

  test "grouped_model_options groups label/id model pairs under each provider" do
    seed_catalog
    groups = Agent::Catalog.grouped_model_options

    anthropic = groups.find { |label, _| label == "Anthropic" }.last
    assert_includes anthropic, [ "Claude Opus 4.8", "claude-opus-4-8" ]
  end

  test "provider_for resolves the provider that offers a model" do
    seed_catalog

    assert_equal "openai-codex", Agent::Catalog.provider_for("gpt-5.5")
    assert_nil Agent::Catalog.provider_for("no-such-model")
  end

  test "default_model and default_provider follow the model marked on the Models page" do
    _, codex = seed_catalog
    codex.llm_models.first.make_deployment_default!

    assert_equal "gpt-5.5", Agent::Catalog.default_model
    assert_equal "openai-codex", Agent::Catalog.default_provider
  end

  test "default falls back to the first listed provider's first model" do
    seed_catalog

    assert_equal "anthropic", Agent::Catalog.default_provider
    assert_equal "claude-opus-4-8", Agent::Catalog.default_model
  end

  test "a disabled default falls back too, and only one model is ever the default" do
    anthropic, codex = seed_catalog
    codex.llm_models.first.make_deployment_default!
    anthropic.llm_models.first.make_deployment_default!
    assert_equal 1, LlmModel.where(deployment_default: true).count

    anthropic.llm_models.first.update!(enabled: false)
    assert_equal "gpt-5.5", Agent::Catalog.default_model
  end
end
