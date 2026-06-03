module SharedConversationsHelper
  SHARE_DESCRIPTION_MAX = 200

  # A human-readable description for social/unfurl cards: the first user
  # prompt, stripped of markdown noise and clamped. Crawlers (Slack,
  # iMessage, X, …) show this under the title, so it should read as prose,
  # not raw markdown. Falls back to a generic line for empty threads.
  def share_description(conversation)
    first = conversation.messages.where(role: :user).order(:created_at).first
    text  = first&.content.to_s.gsub(/[#*`>_~\[\]()]+/, " ").squish

    text.truncate(SHARE_DESCRIPTION_MAX).presence ||
      "A conversation shared from Metis."
  end

  # Absolute URL for the Open Graph / Twitter card image. Static branded
  # card for now; swap for a per-conversation generated card later without
  # touching the view. Absolute (image_url, not image_path) because
  # crawlers won't resolve a relative path.
  def share_image_url(_conversation)
    image_url("og-default.png")
  end
end
