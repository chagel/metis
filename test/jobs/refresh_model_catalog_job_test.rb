require "test_helper"

class RefreshModelCatalogJobTest < ActiveSupport::TestCase
  test "runs the catalog sync; an unreachable pi leaves it untouched" do
    provider = LlmProvider.create!(key: "openai-codex", label: "OpenAI Codex")
    provider.llm_models.create!(key: "gpt-5.5", label: "GPT-5.5")

    with_stub(PiAgent, :session, ->(*, **) { raise "no pi" }) do
      assert_nothing_raised { RefreshModelCatalogJob.perform_now }
    end

    assert_equal 1, LlmModel.count, "unreachable pi must not mutate the catalog"
  end
end
