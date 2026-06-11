module Composing
  extend ActiveSupport::Concern

  private

  def composed_content
    params[:content].to_s.strip
  end

  def composed_uploads
    Array(params[:attachments]).reject(&:blank?)
  end

  # The conversation's provider/model from the composer's model picker.
  # Composer wins; profile default backs up a scrubbed pick; both blank →
  # the adapter falls back to deployment defaults.
  def chat_settings
    model = params[:model].presence || current_user.preferred_model.presence
    { "provider" => model && Agent::Catalog.provider_for(model), "model" => model }.compact
  end

  # The composer's visibility pick; anything but an explicit "team" stays
  # personal.
  def composed_visibility
    params[:visibility] == "team" ? :team : :personal
  end

  # One transaction so a turn-guard collision on the assistant row rolls
  # the user message back too — no orphan. The turn-start core lives in
  # ConversationTurn (shared with the workflow engine); here we only add
  # the composer's upload handling.
  def start_turn(conversation, content, uploads)
    ConversationTurn.start(conversation, content: content, sender: current_user) do |user_message|
      attach_uploads(user_message, uploads)
    end
  end

  def attach_uploads(message, uploads)
    images, files = uploads.partition { |u| u.content_type.to_s.start_with?("image/") }
    message.images.attach(images) if images.any?
    message.files.attach(files) if files.any?
  end

  def upload_error(uploads)
    uploads.each do |upload|
      if upload.size > Message::MAX_UPLOAD_SIZE
        return "#{upload.original_filename} is too large (max #{Message::MAX_UPLOAD_SIZE / 1.megabyte} MB)."
      end
      unless Message::ALLOWED_CONTENT_TYPES.include?(upload.content_type)
        return "#{upload.original_filename} has an unsupported file type."
      end
    end
    nil
  end

  # conversation: nil for the new-chat composer.
  def render_composer_error(conversation, error)
    render(
      turbo_stream: turbo_stream.replace(
        "composer",
        partial: "conversations/composer",
        locals: { conversation: conversation, error: error }
      ),
      status: :unprocessable_entity
    )
  end
end
