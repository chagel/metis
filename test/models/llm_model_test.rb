require "test_helper"

class LlmModelTest < ActiveSupport::TestCase
  setup { @provider = LlmProvider.create!(key: "p", label: "P") }

  test "key is unique within a provider" do
    @provider.llm_models.create!(key: "m", label: "M")
    dup = @provider.llm_models.build(key: "m", label: "M2")

    assert_not dup.valid?
  end
end
