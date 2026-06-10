module Api
  module Bridge
    # The client-side skill (SKILL.md) with the deployment URL baked in.
    # Unauthenticated on purpose — documentation, fetched before any
    # token exists.
    class SkillController < ActionController::API
      TEMPLATE = Rails.root.join("app/views/api/bridge/skill/show.text.erb")

      def show
        body = ERB.new(TEMPLATE.read).result_with_hash(base_url: request.base_url)
        render plain: body, content_type: "text/markdown; charset=utf-8"
      end
    end
  end
end
