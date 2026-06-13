module ApplicationHelper
  # Slash-command palette entries for the composer: team-enabled skills
  # + repo skills, name + description, source-tagged. Rendered into the
  # composer as a JSON data attribute and filtered client-side by
  # SkillPaletteController.
  def chat_skill_palette
    team = current_team if user_signed_in?
    team_entries = team ? team.skills.enabled.order(:slug).pluck(:slug, :description) : []
    team_entries = team_entries.map { |slug, desc| { slug: slug, description: desc, source: "team" } }

    repo_entries = Agent::RepoSkills.all.map do |listing|
      { slug: listing.slug, description: listing.description, source: "builtin" }
    end

    (team_entries + repo_entries).sort_by { |e| e[:slug] }
  end

  # The token to embed in the bridge setup blocks: the plaintext when it
  # was just generated this request (shown once), otherwise the redacted
  # hint so the instructions always have something to show.
  def bridge_token_for_display(user, new_token)
    new_token.presence || user.bridge_token_hint_label
  end

  # Render Markdown (GitHub-flavored) message content to safe HTML.
  # Raw HTML in the source is escaped (unsafe: false) and dangerous
  # link schemes are neutralized, so agent output is safe to display.
  def markdown(text)
    return "" if text.blank?

    html = Commonmarker.to_html(text,
      options: {
        render: { hardbreaks: true, escape: true, unsafe: false },
        extension: {
          strikethrough: true,
          table: true,
          autolink: true,
          tasklist: true,
          superscript: true,
          tagfilter: true
        }
      },
      plugins: { syntax_highlighter: nil })
    html = add_link_target_blank(html)
    html = strip_dangerous_uris(html)
    html.html_safe
  end

  # The compact per-message footer: turn duration and token counts.
  # "" when neither was recorded, so the footer collapses.
  def message_meta(message)
    parts = []
    parts << format_duration(message.duration) if message.duration
    parts << token_summary(message)
    parts << format_cost(message.cost) if message.cost&.positive?
    parts.reject(&:blank?).join(" · ")
  end

  # A turn's cost: "$0.0011", "$1.23". Sub-cent costs keep 4 decimals so a
  # cheap turn doesn't render as "$0.00".
  def format_cost(cost)
    cost >= 0.01 ? format("$%.2f", cost) : format("$%.4f", cost)
  end

  # Human-readable turn duration: "2.3s", "1m 04s".
  def format_duration(seconds)
    return "#{seconds.round(1)}s" if seconds < 60

    minutes, rest = seconds.divmod(60)
    format("%dm %02ds", minutes, rest)
  end

  # Split a filename into [base, ext] so the artifact card can
  # truncate the base with ellipsis while keeping the extension
  # visible — "long_module_name.rb" → "long_modu…" + ".rb".
  def filename_parts(filename)
    ext = File.extname(filename)
    base = ext.empty? ? filename : filename.delete_suffix(ext)
    [ base, ext ]
  end

  # The provisioning phase to seed a freshly-pending turn's indicator with
  # ("Creating sandbox", "Resuming sandbox", "Starting container"), so the
  # first phase is visible even though the runtime's matching broadcast races
  # the indicator's own render. nil for runtimes with no provisioning (Local)
  # — the indicator then shows the plain elapsed timer. Resolution failures
  # must never break message rendering, so they degrade to no phase.
  def runtime_initial_phase(conversation)
    Agent::Runtime.for(conversation).initial_status
  rescue StandardError
    nil
  end

  # Summary label for an assistant turn's reasoning/tools disclosure.
  def activity_summary(message)
    return t("helpers.activity.working") unless message.done?

    parts = []
    parts << t("helpers.activity.reasoning") if message.reasoning.present?
    parts << t("helpers.activity.tool_calls", count: message.tool_calls.size) if message.tool_calls.any?
    parts.join(" · ").presence || t("helpers.activity.activity")
  end

  # A compact per-message token line, or "" when none was recorded.
  def token_summary(message)
    return "" if message.input_tokens.blank? && message.output_tokens.blank?

    parts = []
    parts << t("helpers.tokens.in", value: format_tokens(message.input_tokens)) if message.input_tokens
    parts << t("helpers.tokens.out", value: format_tokens(message.output_tokens)) if message.output_tokens
    parts << t("helpers.tokens.cached", value: format_tokens(message.cache_read_tokens)) if message.cache_read_tokens.to_i.positive?
    parts.join(" · ")
  end

  # Abbreviate a token count: 1530 -> "1.5k", 940 -> "940".
  def format_tokens(count)
    count = count.to_i
    return count.to_s if count < 1000

    format("%gk", (count / 100.0).round / 10.0)
  end

  # Timezone <option>s for the profile select. Each label carries the
  # UTC offset — "(GMT+08:00) Beijing" — so a user can scan by offset
  # instead of memorising city names. The value is still the
  # Rails-friendly `tz.name`, which is what the model validator and
  # `ProfilesController#detect_timezone` agree on.
  def timezone_options
    ActiveSupport::TimeZone.all.map do |tz|
      [ "(GMT#{tz.formatted_offset}) #{tz.name}", tz.name ]
    end
  end

  # Attributes for the chat-layout `<body>` tag. The timezone-detect
  # Stimulus controller is only wired up for a signed-in user who
  # hasn't picked a timezone yet — keeping the conditional in Ruby
  # avoids embedding ERB inside the `<body>` opening tag, which leaves
  # stray whitespace before the closing `>`.
  def chat_body_attrs
    attrs = { class: "app-shell" }
    if user_signed_in? && current_user.timezone.blank?
      attrs[:data] = {
        controller: "timezone-detect",
        timezone_detect_url_value: detect_timezone_profile_path
      }
    end
    attrs
  end

  # Human label for an `I18n.locale` code, used by the profile form's
  # language picker. Falls back to the bare code so an unknown locale
  # is still selectable rather than blank.
  def language_label(code)
    t("helpers.languages.#{code}", default: code.to_s.upcase)
  end

  # Display label for a recency bucket. Views can't reach the constant
  # by bare name (lexical scope, not the include chain), so they go
  # through this helper.
  def conversation_time_bucket_label(bucket)
    t("helpers.time_buckets.#{bucket}")
  end

  # The recency bucket a timestamp falls into. Used by _convo_items to
  # emit an inline group header only when the bucket changes from the
  # previous row — endless-scroll passes the last page's final bucket
  # back via `last_bucket=`, so cross-page continuity is automatic.
  def conversation_time_bucket(timestamp)
    return :older unless timestamp

    now = Time.current
    if timestamp.to_date == now.to_date           then :today
    elsif timestamp.to_date == now.yesterday.to_date then :yesterday
    elsif timestamp >= now.beginning_of_week      then :this_week
    elsif timestamp >= now.beginning_of_month     then :this_month
    else :older
    end
  end

  SIDEBAR_EMPTY_FILTERS = %w[team starred active].freeze

  def sidebar_empty_message(filter)
    key = SIDEBAR_EMPTY_FILTERS.include?(filter) ? filter : "active"
    t("helpers.sidebar_empty.#{key}")
  end

  # Sidebar scope-tab class, marking the current filter active.
  def sidebar_tab_class(filter)
    class_names("convo-tab", "on" => @sidebar_filter == filter)
  end

  # Human label for an identity provider key — `google_oauth2` reads as
  # "Google", `github` as "GitHub". Falls back to a titleized key.
  IDENTITY_PROVIDER_LABELS = {
    "github" => "GitHub",
    "google_oauth2" => "Google"
  }.freeze

  def identity_provider_label(provider)
    IDENTITY_PROVIDER_LABELS[provider.to_s] || provider.to_s.titleize
  end

  # The plain "Sign in with X" / "Connect X account" authorize path
  # for a catalog app — the *sign-in* shape, with no extra scopes.
  # Returns nil if the app's provider strategy isn't wired up.
  def omniauth_authorize_path_for(app)
    strategy = OauthBroker.omniauth_strategy(app.oauth_provider)
    return nil unless strategy
    return nil unless oauth_provider_configured?(app.oauth_provider)

    send("user_#{strategy}_omniauth_authorize_path")
  end

  # The *connect this connector* authorize path — same omniauth
  # strategy, but with the connector's required oauth_scopes added
  # on top of the base sign-in scopes, prompt=consent so the user
  # sees the new scope on the consent screen, and
  # include_granted_scopes so the new grant unions with whatever the
  # user has already authorized. The callback dispatches on the
  # `connect=<key>` param to upsert the connector marker.
  def connector_authorize_path_for(app)
    strategy = OauthBroker.omniauth_strategy(app.oauth_provider)
    return nil unless strategy
    return nil unless oauth_provider_configured?(app.oauth_provider)

    scopes = (OauthBroker::SIGN_IN_SCOPES.fetch(app.oauth_provider, []) + app.oauth_scopes).uniq.join(",")
    # `team` rides the OAuth state so the callback lands the connector on
    # the team the user was acting in, not their personal team.
    send("user_#{strategy}_omniauth_authorize_path",
         connect: app.key,
         team: current_team.id,
         scope: scopes,
         prompt: "consent",
         include_granted_scopes: true)
  end

  # True when a connector still needs a one-time admin OAuth-app setup —
  # a brokered provider (GitHub/Google) whose deployment credentials aren't
  # configured yet. The marketplace flags only these (with a dot) so an
  # installation owner sees what's left to wire up; mcp_oauth (DCR) and
  # token connectors need no setup and carry no marker.
  def connector_needs_setup?(app)
    app.oauth? && !oauth_provider_configured?(app.oauth_provider)
  end

  def oauth_provider_configured?(provider)
    case OauthBroker.normalize_provider(provider) || provider.to_s
    when "github"
      GithubApp::Config.configured?
    when "google"
      GoogleApp::Config.configured?
    else
      false
    end
  end

  private

  def add_link_target_blank(html)
    html.gsub("<a ", '<a target="_blank" rel="noopener" ')
  end

  def strip_dangerous_uris(html)
    html.gsub(/href\s*=\s*["']javascript:[^"']*["']/i, 'href="#"')
  end
end
