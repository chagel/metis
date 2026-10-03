require "test_helper"

class LlmModelTest < ActiveSupport::TestCase
  setup { @provider = LlmProvider.create!(key: "p", label: "P") }

  test "key is unique within a provider" do
    @provider.llm_models.create!(key: "m", label: "M")
    dup = @provider.llm_models.build(key: "m", label: "M2")

    assert_not dup.valid?
  end

  test "first_enabled_key_for returns a provider's first enabled model in catalog order" do
    anthropic = LlmProvider.create!(key: "anthropic", label: "Anthropic")
    anthropic.llm_models.create!(key: "claude-off", label: "Off", position: 0, enabled: false)
    anthropic.llm_models.create!(key: "claude-b", label: "B", position: 2)
    anthropic.llm_models.create!(key: "claude-a", label: "A", position: 1)
    LlmProvider.create!(key: "openai", label: "OpenAI").llm_models.create!(key: "gpt", label: "GPT", position: 0)

    assert_equal "claude-a", LlmModel.first_enabled_key_for("anthropic")
    assert_nil LlmModel.first_enabled_key_for("nope")
  end
end
