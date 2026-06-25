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
      when :push                 then @payload["compare"]
      when :pull_request         then @payload.dig("pull_request", "html_url")
      when :pull_request_review  then @payload.dig("review", "html_url")
      when :release              then @payload.dig("release", "html_url")
      when :issues               then @payload.dig("issue", "html_url")
      when :issue_comment, :pull_request_review_comment then @payload.dig("comment", "html_url")
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
      when :pull_request_review
        scoped(:pull_request, verb: review_verb, number: number, title: title("pull_request"))
      when :issues
        scoped(:issues, verb: verb, number: number, title: title("issue"))
      when :issue_comment, :pull_request_review_comment
        scoped(:issue_comment, number: number)
      when :release
        scoped(:release, verb: verb, name: release_name)
      else
        scoped(:other, event: humanized_event)
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

    # GitHub's review *state* is the meaningful verb, not the "submitted" action.
    def review_verb
      key = { "approved" => "approved", "changes_requested" => "requested_changes",
              "commented" => "reviewed" }.fetch(@payload.dig("review", "state"), "reviewed")
      I18n.t(key, scope: "projects.activity.verbs", default: key.humanize.downcase)
    end

    def release_name
      @payload.dig("release", "name").presence || @payload.dig("release", "tag_name")
    end

    # Last resort for an event with no bespoke wording: verb-first, spelled
    # out ("milestone.created" -> "created milestone",
    # "pull_request_review_thread.resolved" -> "resolved pull request review
    # thread") instead of leaking the raw identifier.
    def humanized_event
      [ action, kind.to_s ].compact.join(" ").tr("_", " ").squeeze(" ").strip
    end

    def scoped(key, **args)
      I18n.t(key, scope: "projects.activity.lines", **args)
    end
  end
end
