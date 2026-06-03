require "test_helper"

class SharedConversationsHelperTest < ActionView::TestCase
  setup do
    @user = User.create!(email: "owner@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "Shared chat")
  end

  test "share_description uses the first user message, stripped and clamped" do
    @conversation.messages.create!(
      role: :user,
      content: "# Heading\n\nHelp me **refactor** the `share` layout for unfurls",
      streaming_status: :done
    )

    desc = share_description(@conversation)

    assert_includes desc, "Help me refactor the share layout for unfurls"
    refute_includes desc, "#"
    refute_includes desc, "*"
    refute_includes desc, "`"
  end

  test "share_description truncates very long prompts" do
    @conversation.messages.create!(
      role: :user, content: "word " * 200, streaming_status: :done
    )

    assert_operator share_description(@conversation).length, :<=,
      SharedConversationsHelper::SHARE_DESCRIPTION_MAX
  end

  test "share_description falls back when there is no user message" do
    assert_equal "A conversation shared from Metis.", share_description(@conversation)
  end
end
