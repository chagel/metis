# One-line activity entry for a Linear WebhookEvent. Mirrors the GitHub
# Presenter's shape (actor / avatar_url / url / summary) over Linear's
# differently-shaped payload — an `actor` object, a top-level `url`, and
# an entity `type` (the Linear-Event header) plus a create/update/remove
# `action`. Unknown types degrade to a verb-first spelled-out name.
class WebhookEvent
  class Presenter
    class Linear
      def initialize(event)
        @event = event
        @payload = event.payload
      end

      def actor
        @payload.dig("actor", "name").presence || "someone"
      end

      def avatar_url
        @payload.dig("actor", "avatarUrl").presence
      end

      def provider
        @event.provider
      end

      def created_at
        @event.created_at
      end

      # Linear hands us the subject entity's URL directly.
      def url
        @payload["url"].presence
      end

      def summary
        case type
        when "Issue"   then line(:issue, verb: verb, title: issue_title)
        when "Project" then line(:project, verb: verb, name: data["name"])
        when "Comment" then line(:comment, title: comment_subject)
        else line(:other, event: humanized)
        end
      end

      private

      def data
        @payload["data"] || {}
      end

      # "Issue.create" -> "Issue"; "Issue" -> "Issue".
      def type
        @event.event_type.split(".").first
      end

      def action
        @event.event_type.split(".", 2)[1]
      end

      def verb
        I18n.t(action, scope: "projects.activity.linear.verbs",
                       default: action.to_s.humanize.downcase)
      end

      # "ENG-123: Title" when both are present, else whichever we have.
      def issue_title
        [ data["identifier"], data["title"] ].compact.join(": ").presence || data["identifier"]
      end

      def comment_subject
        data.dig("issue", "identifier") || data.dig("issue", "title")
      end

      # Verb-first spelled-out fallback: "Cycle.create" -> "created cycle",
      # "IssueLabel.update" -> "updated issue label".
      def humanized
        "#{verb} #{type.to_s.underscore.tr('_', ' ')}".squeeze(" ").strip
      end

      def line(key, **args)
        I18n.t(key, scope: "projects.activity.linear.lines", **args)
      end
    end
  end
end
