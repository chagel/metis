require "test_helper"

class Agent::HistoryTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "hist-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @current = @user.conversations.create!(title: "Current")
  end

  def render
    Agent::History.new(@current).content
  end

  test "renders a transcript section per recent conversation with its link" do
    convo = @user.conversations.create!(title: "Zoom in Asia")
    convo.messages.create!(role: :user, content: "Does Zoom work in Thailand?")
    convo.messages.create!(role: :assistant, content: "Yes, it works fine.", streaming_status: :done)

    out = render
    assert_match(/# Conversation history/, out)
    assert_match(/## Zoom in Asia/, out)
    assert_match(%r{- Link: /conversations/#{convo.id}}, out)
    assert_match(/\*\*Operator:\*\* Does Zoom work in Thailand\?/, out)
    assert_match(/\*\*Metis:\*\* Yes, it works fine\./, out)
  end

  test "excludes the current conversation" do
    @current.messages.create!(role: :user, content: "secret current content")

    refute_match(/secret current content/, render)
    refute_match(/## Current/, render)
  end

  test "excludes archived conversations" do
    archived = @user.conversations.create!(title: "Archived chat")
    archived.messages.create!(role: :user, content: "archived content")
    archived.archive!

    refute_match(/Archived chat/, render)
  end

  test "never crosses into another user's conversations" do
    other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: "password123")
    other.conversations.create!(title: "Theirs").messages.create!(role: :user, content: "private note")

    refute_match(/private note/, render)
  end

  test "caps the number of conversations rendered" do
    (Agent::History::CONVERSATIONS_MAX + 4).times do |i|
      @user.conversations.create!(title: "chat #{i}")
    end

    assert_equal Agent::History::CONVERSATIONS_MAX, render.scan(/^## /).size
  end

  test "truncates an over-long message" do
    convo = @user.conversations.create!(title: "Long one")
    convo.messages.create!(role: :user, content: "x" * (Agent::History::MESSAGE_CHARS_MAX + 500))

    section = render.split(/## Long one\n/, 2).last
    refute_match(/x{#{Agent::History::MESSAGE_CHARS_MAX + 1}}/, section)
    assert_match(/\.\.\./, section)
  end

  test "renders just the header when there are no other conversations" do
    assert_match(/# Conversation history/, render)
    refute_match(/^## /, render)
  end

  test "degrades to the header instead of crashing the turn when rendering fails" do
    @user.conversations.create!(title: "Boom")
    history = Agent::History.new(@current)

    with_stub(history, :recent_conversations, ->(*) { raise "decryption failed" }) do
      out = history.content
      assert_match(/# Conversation history/, out)
      refute_match(/^## /, out)
    end
  end
end
