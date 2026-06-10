module Api
  module Bridge
    # Serves the client-side skill (SKILL.md) that teaches a local coding
    # agent to set up and work the bridge. Unauthenticated on purpose — it
    # is documentation with the deployment URL baked in, fetched before
    # any token exists:
    #
    #   curl -fsSL https://<host>/api/bridge/skill \
    #     -o ~/.claude/skills/metis-bridge/SKILL.md
    class SkillController < ActionController::API
      TEMPLATE = Rails.root.join("app/views/api/bridge/skill/show.text.erb")

      def show
        body = ERB.new(TEMPLATE.read).result_with_hash(base_url: request.base_url)
        render plain: body, content_type: "text/markdown; charset=utf-8"
      end
    end
  end
end
