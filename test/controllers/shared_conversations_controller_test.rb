require "test_helper"

class SharedConversationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "owner@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "Shared chat")
    @conversation.messages.create!(role: :user, content: "hello", streaming_status: :done)
    @conversation.messages.create!(role: :assistant, content: "hi back", streaming_status: :done)
    @token = @conversation.generate_share_token!
  end

  test "renders the public conversation without authentication" do
    get shared_conversation_path(token: @token)
    assert_response :success
    assert_select "h1.shared-title", text: "Shared chat"
    assert_select ".thread .chat-content", text: /hello/
    assert_select ".thread .chat-content", text: /hi back/
  end

  test "emits Open Graph and Twitter card meta for unfurls" do
    get shared_conversation_path(token: @token)
    assert_response :success

    assert_select "meta[property='og:title'][content=?]", "Shared chat"
    assert_select "meta[property='og:type'][content=?]", "article"
    assert_select "meta[property='og:site_name'][content=?]", "Metis"
    assert_select "meta[property='og:image']" do |tags|
      assert_match %r{og-default.*\.png\z}, tags.first["content"]
      assert_match %r{\Ahttps?://}, tags.first["content"]
    end
    assert_select "meta[property='og:description'][content=?]", "hello"
    assert_select "meta[name='twitter:card'][content=?]", "summary_large_image"
    assert_select "meta[name='twitter:image']"
    assert_select "link[rel='canonical']"
  end

  test "returns 404 for an unknown token" do
    get shared_conversation_path(token: "no-such-token")
    assert_response :not_found
  end

  test "returns 404 once the share has been revoked" do
    @conversation.revoke_share!
    get shared_conversation_path(token: @token)
    assert_response :not_found
  end
end
