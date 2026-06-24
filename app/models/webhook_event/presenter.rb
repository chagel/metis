# One-line activity entry for a WebhookEvent. Wording is locale-resolved
# here so it lives in one place; unknown event types degrade to a bare
# humanized name rather than raising.
class WebhookEvent
  class Presenter
    def initialize(event)
      @event = event
      @payload = event.payload
    end

    def actor
      @payload.dig("sender", "login").presence || "someone"
    end

    def avatar_url
      @payload.dig("sender", "avatar_url").presence
    end

    def created_at
      @event.created_at
    end

    # External GitHub link for the entry, or nil (the row renders unlinked).
    def url
      case kind
      when :push          then @payload["compare"]
      when :pull_request  then @payload.dig("pull_request", "html_url")
      when :issues        then @payload.dig("issue", "html_url")
      when :issue_comment then @payload.dig("comment", "html_url")
      end.presence
    end

    # The action sentence (no actor — the view renders that beside the
    # avatar). Plain text; the view escapes it.
    def summary
      case kind
      when :push
        scoped(:push, count: Array(@payload["commits"]).size, branch: branch)
      when :pull_request
        scoped(:pull_request, verb: verb, number: number, title: title("pull_request"))
      when :issues
        scoped(:issues, verb: verb, number: number, title: title("issue"))
      when :issue_comment
        scoped(:issue_comment, number: number)
      else
        scoped(:other, event: @event.event_type)
      end
    end

    private

    # "pull_request.synchronize" -> :pull_request, "push" -> :push.
    def kind
      @event.event_type.split(".").first.to_sym
    end

    def action
      @event.event_type.split(".", 2)[1]
    end

    def branch
      @payload["ref"].to_s.sub("refs/heads/", "")
    end

    def number
      @payload["number"] || @payload.dig("pull_request", "number") || @payload.dig("issue", "number")
    end

    def title(key)
      @payload.dig(key, "title")
    end

    # A merged PR closes with merged=true — surface that, not "closed".
    def verb
      act = action
      act = "merged" if kind == :pull_request && act == "closed" && @payload.dig("pull_request", "merged")
      I18n.t(act, scope: "projects.activity.verbs", default: act.to_s.humanize.downcase)
    end

    def scoped(key, **args)
      I18n.t(key, scope: "projects.activity.lines", **args)
    end
  end
end
