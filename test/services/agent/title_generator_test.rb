require "test_helper"

class Agent::TitleGeneratorTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "title-gen@example.com", password: "password123")
    @conversation = @user.conversations.create!(settings: { "provider" => "anthropic" })
    @conversation.messages.create!(role: :user, content: "What is Ruby?", streaming_status: :done)
  end

  test "returns nil when the conversation has no message content" do
    empty = @user.conversations.create!(settings: { "provider" => "anthropic" })
    assert_nil Agent::TitleGenerator.call(empty)
  end

  test "returns nil when no API key is configured for the chosen provider" do
    with_stub(Rails.application.config.x.agent, :api_keys, -> { {} }) do
      assert_nil Agent::TitleGenerator.call(@conversation)
    end
  end

  test "returns nil and logs a warning when the HTTP call raises" do
    with_stub(Rails.application.config.x.agent, :api_keys, -> { { "anthropic" => "test-key" } }) do
      generator = Agent::TitleGenerator.new(@conversation)
      generator.define_singleton_method(:post) { |_uri, _body, _hdrs| raise "connection refused" }
      assert_nil generator.call
    end
  end

  test "prefers the conversation's chosen provider over the deployment default" do
    @conversation.update!(settings: { "provider" => "openai" })
    seen_provider = nil
    fake_response = { "choices" => [ { "message" => { "content" => "Ruby Basics" } } ] }

    with_stub(Rails.application.config.x.agent, :api_keys, -> { { "openai" => "k", "anthropic" => "k" } }) do
      with_stub(Rails.application.config.x.agent, :provider, -> { "anthropic" }) do
        generator = Agent::TitleGenerator.new(@conversation)
        generator.define_singleton_method(:post) { |uri, _body, _hdrs| seen_provider = uri.host; fake_response }
        assert_equal "Ruby Basics", generator.call
      end
    end

    assert_match(/openai/, seen_provider)
  end

  test "an unsupported provider falls through to a supported one with a key" do
    @conversation.update!(settings: { "provider" => "minimax" })
    seen_host = nil
    fake_response = { "choices" => [ { "message" => { "content" => "Ruby Basics" } } ] }

    with_stub(Rails.application.config.x.agent, :api_keys, -> { { "minimax" => "k", "openai" => "k" } }) do
      with_stub(Rails.application.config.x.agent, :provider, -> { "minimax" }) do
        generator = Agent::TitleGenerator.new(@conversation)
        generator.define_singleton_method(:post) { |uri, _body, _hdrs| seen_host = uri.host; fake_response }
        assert_equal "Ruby Basics", generator.call
      end
    end

    assert_match(/openai/, seen_host)
  end

  test "parses and sanitizes a successful Anthropic response" do
    fake_response = { "content" => [ { "type" => "text", "text" => '  "What Is Ruby"  ' } ] }
    with_stub(Rails.application.config.x.agent, :api_keys, -> { { "anthropic" => "test-key" } }) do
      generator = Agent::TitleGenerator.new(@conversation)
      generator.define_singleton_method(:post) { |_uri, _body, _hdrs| fake_response }
      assert_equal "What Is Ruby", generator.call
    end
  end

  test "parses a successful OpenAI response" do
    @conversation.update!(settings: { "provider" => "openai" })
    fake_response = { "choices" => [ { "message" => { "content" => "Ruby Basics" } } ] }
    with_stub(Rails.application.config.x.agent, :api_keys, -> { { "openai" => "test-key" } }) do
      generator = Agent::TitleGenerator.new(@conversation)
      generator.define_singleton_method(:post) { |_uri, _body, _hdrs| fake_response }
      assert_equal "Ruby Basics", generator.call
    end
  end

  test "parses a successful Google response" do
    @conversation.update!(settings: { "provider" => "google" })
    fake_response = {
      "candidates" => [ { "content" => { "parts" => [ { "text" => "Gemini Overview" } ] } } ]
    }
    with_stub(Rails.application.config.x.agent, :api_keys, -> { { "google" => "test-key" } }) do
      generator = Agent::TitleGenerator.new(@conversation)
      generator.define_singleton_method(:post) { |_uri, _body, _hdrs| fake_response }
      assert_equal "Gemini Overview", generator.call
    end
  end

  test "sanitize strips markdown wrappers and rejects too-short output" do
    wrapped = { "content" => [ { "text" => '  **"Rails Tips"**  ' } ] }
    too_short = { "content" => [ { "text" => "**a**" } ] }

    with_stub(Rails.application.config.x.agent, :api_keys, -> { { "anthropic" => "test-key" } }) do
      generator = Agent::TitleGenerator.new(@conversation)
      generator.define_singleton_method(:post) { |_uri, _body, _hdrs| wrapped }
      assert_equal "Rails Tips", generator.call

      generator2 = Agent::TitleGenerator.new(@conversation)
      generator2.define_singleton_method(:post) { |_uri, _body, _hdrs| too_short }
      assert_nil generator2.call
    end
  end

  test "wraps the conversation context in <session> tags as a prompt-injection guard" do
    captured = nil
    fake_response = { "content" => [ { "text" => "Intro to Ruby" } ] }

    with_stub(Rails.application.config.x.agent, :api_keys, -> { { "anthropic" => "test-key" } }) do
      generator = Agent::TitleGenerator.new(@conversation)
      generator.define_singleton_method(:post) { |_uri, body, _hdrs| captured = body; fake_response }
      generator.call
    end

    assert_match(%r{<session>.*User: What is Ruby\?.*</session>}m, captured.dig(:messages, 0, :content))
  end

  test "includes the assistant reply in the prompt context when available" do
    @conversation.messages.create!(
      role: :assistant, content: "Ruby is a dynamic language.", streaming_status: :done
    )
    captured = nil
    fake_response = { "content" => [ { "text" => "Intro to Ruby" } ] }

    with_stub(Rails.application.config.x.agent, :api_keys, -> { { "anthropic" => "test-key" } }) do
      generator = Agent::TitleGenerator.new(@conversation)
      generator.define_singleton_method(:post) { |_uri, body, _hdrs| captured = body; fake_response }
      generator.call
    end

    user_message = captured.dig(:messages, 0, :content)
    assert_match(/User: What is Ruby\?/, user_message)
    assert_match(/Assistant: Ruby is a dynamic language\./, user_message)
  end
end
