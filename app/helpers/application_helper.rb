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

  # Friendly catalog label for a turn's model ("Claude Opus 4.7"), falling
  # back to the raw pi key. The catalog map is memoized per render so a
  # message collection resolves in one query, not one per row.
  def model_key_label(key)
    return "" if key.blank?
    (@model_label_map ||= LlmModel.pluck(:key, :label).to_h)[key] || key
  end

  # Public attribution for a turn's model: "Claude Opus 4.7 · Anthropic"
  # from the catalog, falling back to the raw pi key when uncatalogued.
  def model_attribution(key)
    return "" if key.blank?
    labels = LlmModel.joins(:llm_provider).where(key: key).pick("llm_models.label", "llm_providers.label")
    labels&.join(" · ") || key
  end

  # The assistant footer on a public share: "model · duration". Duration (not
  # a wall-clock stamp) is the informative axis — a shared conversation is one
  # instant flow, so "3m ago" on every turn says nothing, while "1m 10s" tells
  # the reader how long that turn took.
  def assistant_shared_stamp(message)
    [ model_key_label(message.model_key),
      (format_duration(message.duration) if message.duration) ].reject(&:blank?).join(" · ")
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
  # Sections that open collapsed (icon rail) by default — the board and
  # sharing pages are full-width grids the panel only crowds. Server-
  # rendered to avoid a flash; the controller still honors a sticky
  # per-section override.
  NAV_DEFAULT_COLLAPSED = %w[board sharing].freeze

  def nav_default_collapsed?
    NAV_DEFAULT_COLLAPSED.include?(controller_name)
  end

  # The team's projects, most recently active first. A project's own
  # updated_at only moves on settings edits, so "active" means its latest
  # conversation (chats and runs alike) or inbound event — falling back to
  # the project timestamp for one that's seen neither. Two grouped MAX
  # queries, sorted in Ruby.
  def sidebar_projects(team)
    # A query scope, not the bare association — the latter would include an
    # unsaved built record (e.g. a failed create's @project, nil id).
    projects = team.projects.order(:created_at).to_a
    return projects if projects.size < 2

    ids = projects.map(&:id)
    last_conv = Conversation.where(project_id: ids).group(:project_id).maximum(:updated_at)
    last_event = WebhookEvent.where(project_id: ids).group(:project_id).maximum(:created_at)
    projects.sort_by { |p| -[ last_conv[p.id], last_event[p.id], p.updated_at ].compact.max.to_f }
  end

  # Per-project counts for the sidebar project cards — three grouped
  # queries total, not N+1. Chats/runs honor the viewer's visibility like
  # the dashboard; events are team-level. Returns
  # { project_id => { chats:, runs:, events: } }.
  def sidebar_project_stats(projects)
    ids = projects.map(&:id)
    return {} if ids.empty?

    visible = Conversation.accessible_to(current_user)
    chats = Conversation.where(project_id: ids).merge(visible).group(:project_id).count
    runs = WorkflowRun.joins(:conversation).where(conversations: { project_id: ids })
                      .merge(visible).group("conversations.project_id").count
    events = WebhookEvent.where(project_id: ids).group(:project_id).count
    ids.index_with do |id|
      { chats: chats[id].to_i, runs: runs[id].to_i, events: events[id].to_i }
    end
  end

  def chat_body_attrs
    attrs = { class: class_names("app-shell", "hotwire-native": hotwire_native_app?) }
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

  # Monogram for an activity row with no actor photo: one initial for a
  # single token ("chagel" → "CH"), two for a name ("Mike Chen" → "MC").
  def activity_initials(name)
    words = name.to_s.gsub(/[^[:alnum:]\s]/, " ").split
    return "?" if words.empty?

    (words.one? ? words.first[0, 2] : words.first(2).map { |w| w[0] }.join).upcase
  end

  # Brand mark stamped on the corner of an activity avatar so the source
  # provider reads at a glance. Paths inherit `currentColor`; the badge's
  # class tints it. Unknown provider → no badge.
  ACTIVITY_PROVIDER_BADGES = {
    "github" => '<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>',
    "linear" => '<svg viewBox="0 0 100 100" fill="currentColor" aria-hidden="true"><path d="M1.22541 61.5228c-.2225-.9485.90748-1.5459 1.59638-.857L39.5193 97.1797c.6889.6889.0915 1.8189-.857 1.5964C20.0515 94.4522 5.54779 79.9485 1.22541 61.5228Z"/><path d="M.00189135 46.8891c-.01764375.2833.08887215.5599.28957165.7606L52.3503 99.7085c.2007.2007.4773.3075.7606.2896 2.3692-.1476 4.6938-.46 6.9624-.9259.7645-.157 1.0301-1.0963.4782-1.6481L2.57595 39.4485c-.55186-.5519-1.491178-.2863-1.648139.4782-.465915 2.2686-.77832 4.5932-.92591695 6.9624Z"/><path d="M4.21093 29.7054c-.16649.3738-.08169.8106.20765 1.1l64.77602 64.776c.2894.2894.7262.3742 1.1.2077 1.7861-.7956 3.5171-1.6927 5.1855-2.6849.5096-.3031.5904-1.0078.1731-1.4251L8.31837 24.3469c-.41727-.4173-1.22185-.3365-1.52498.1731-.99221 1.6684-1.88927 3.3994-2.68246 5.1854Z"/><path d="M12.6587 18.074c-.3701-.3701-.393-.9637-.0443-1.3541C21.7795 6.45931 35.1114 0 49.9519 0 77.5927 0 100 22.4073 100 50.0481c0 14.8405-6.4593 28.1724-16.7199 37.3375-.3904.3487-.984.3258-1.3541-.0443L12.6587 18.074Z"/></svg>'
  }.freeze

  def activity_provider_badge(provider)
    ACTIVITY_PROVIDER_BADGES[provider.to_s]&.html_safe
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
    # X connects through its own controller (no omniauth strategy).
    return XApp::Config.configured? ? connector_x_authorize_path : nil if app.oauth_provider == "x"

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
    when "x"
      XApp::Config.configured?
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
