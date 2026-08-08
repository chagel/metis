# Configuration checklist behind `bin/rails metis:doctor`: reports each
# subsystem as configured, missing, or defaulted — with the exact env
# var names — so a deployer doesn't have to read initializers to learn
# what the app expects. Never prints secret values, only presence.
require "open3"
require Rails.root.join("lib/tasks/support/pi_image_fingerprint")

class Doctor
  Check = Data.define(:status, :name, :detail) # status: :ok, :warn, :fail, :off

  SYMBOLS = { ok: "✓", warn: "!", fail: "✗", off: "-" }.freeze
  ARTIFACT_NOUNS = { "e2b" => "template", "daytona" => "snapshot" }.freeze

  # pi_version is injected like env and delivery_method: reading it shells
  # out to the binary, which tests must not do 16 times over.
  def initialize(env: ENV, delivery_method: ActionMailer::Base.delivery_method,
                 pi_version: -> { Doctor.local_pi_version },
                 docker_image: ->(name) { Doctor.docker_image_metadata(name) })
    @env = env
    @delivery_method = delivery_method
    @pi_version = pi_version
    @docker_image = docker_image
  end

  def self.local_pi_version
    out, status = Open3.capture2("pi", "--version")
    status.success? ? out.strip.presence : nil
  rescue Errno::ENOENT
    nil
  end

  # nil when there is no daemon to ask (the doctor also runs on hosts that
  # have no docker); present: false when the daemon answers and has no such
  # image. The two must not collapse: one is unverifiable, the other is broken.
  #
  # daemon_arch is what the image is compared against, not the image's own
  # architecture — a cross-arch metis-pi inspects as internally consistent and
  # fails only at turn time, as a 30s BootTimeout (see PiImageFingerprint).
  def self.docker_image_metadata(name)
    arch = docker_daemon_arch
    return nil if arch.nil?

    out, _err, status = Open3.capture3(
      "docker", "image", "inspect", name,
      "--format", '{{index .Config.Labels "metis.fingerprint"}}'
    )
    return { present: false, daemon_arch: arch } unless status.success?

    { present: true, daemon_arch: arch, fingerprint: out.strip }
  rescue Errno::ENOENT
    nil
  end

  def self.docker_daemon_arch
    out, _err, status = Open3.capture3("docker", "version", "--format", "{{.Server.Arch}}")
    status.success? ? out.strip.presence : nil
  rescue Errno::ENOENT
    nil
  end

  def sections
    @sections ||= {
      "Core" => core_checks,
      "Email" => email_checks,
      "Agent" => agent_checks,
      "Storage" => storage_checks,
      "Access" => access_checks,
      "Connectors" => connector_checks,
      "Observability" => observability_checks
    }
  end

  def ok?
    checks.none? { |check| check.status == :fail }
  end

  def report
    lines = [ "Metis doctor — #{Rails.env}" ]
    sections.each do |title, section_checks|
      lines << "" << title
      section_checks.each do |check|
        lines << format("  %s %-14s %s", SYMBOLS.fetch(check.status), check.name, check.detail)
      end
    end
    lines << "" << summary
    lines.join("\n")
  end

  private

  def checks = sections.values.flatten

  def summary
    fails = checks.count { |check| check.status == :fail }
    warns = checks.count { |check| check.status == :warn }
    return "All good." if fails.zero? && warns.zero?

    [ ("#{fails} problem#{"s" unless fails == 1}" if fails.positive?),
      ("#{warns} warning#{"s" unless warns == 1}" if warns.positive?) ].compact.join(", ") + "."
  end

  def core_checks
    [ database_check, migrations_check, encryption_check ]
  end

  def database_check
    ActiveRecord::Base.connection.select_value("SELECT 1")
    Check.new(:ok, "database", "connected")
  rescue StandardError => e
    Check.new(:fail, "database", "#{e.class}: #{e.message.lines.first&.strip}".truncate(120))
  end

  def migrations_check
    ActiveRecord::Migration.check_all_pending!
    Check.new(:ok, "migrations", "up to date")
  rescue ActiveRecord::PendingMigrationError
    Check.new(:fail, "migrations", "pending — run bin/rails db:migrate")
  rescue StandardError
    Check.new(:fail, "migrations", "unknown (database unavailable)")
  end

  def encryption_check
    # config.primary_key raises Errors::Configuration when unset (it's
    # `has_primary_key? or raise`), so use the predicate — this check must
    # survive the very keyless environment it exists to diagnose.
    if ActiveRecord::Encryption.config.has_primary_key?
      Check.new(:ok, "encryption", "Active Record encryption keys present")
    else
      Check.new(:fail, "encryption", "keys missing — bin/rails db:encryption:init, then credentials or ACTIVE_RECORD_ENCRYPTION_* env")
    end
  end

  def email_checks
    [ transport_check, sender_check, links_host_check ].compact
  end

  def transport_check
    case @delivery_method
    when :smtp
      address = ActionMailer::Base.smtp_settings[:address]
      return Check.new(:fail, "transport", "smtp selected but SMTP_ADDRESS is unset") if address.blank?

      auth = ActionMailer::Base.smtp_settings[:user_name].present? ? "authenticated" : "no AUTH"
      Check.new(:ok, "transport", "smtp via #{address} (#{auth})")
    when :cloudflare
      missing = %w[CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_EMAIL_API_TOKEN].select { |var| @env[var].blank? }
      if missing.any?
        Check.new(:fail, "transport", "cloudflare selected but #{missing.join(", ")} unset")
      else
        Check.new(:ok, "transport", "cloudflare")
      end
    when :test
      status = Rails.env.production? ? :warn : :off
      Check.new(status, "transport", "test — mail kept in memory, nothing sent")
    else
      Check.new(:ok, "transport", @delivery_method.to_s)
    end
  end

  def sender_check
    if @env["METIS_MAIL_FROM"].present?
      Check.new(:ok, "sender", @env["METIS_MAIL_FROM"])
    else
      status = Rails.env.production? ? :warn : :off
      Check.new(status, "sender", "METIS_MAIL_FROM unset — sending as Metis <noreply@example.com>")
    end
  end

  def links_host_check
    return unless Rails.env.production?

    if @env["METIS_APP_HOST"].present?
      Check.new(:ok, "link host", @env["METIS_APP_HOST"])
    else
      Check.new(:warn, "link host", "METIS_APP_HOST unset — email links point at example.com")
    end
  end

  def agent_checks
    [ runtime_check, pi_check, providers_check, default_model_check, web_search_check ]
  end

  # pi itself, which runtime_check does not cover: it reports how the agent is
  # isolated, not whether the agent is there. A local runtime with no pi on
  # PATH read as fully configured until every turn failed on BinaryNotFound.
  def pi_check
    pinned = PiAgent::SUPPORTED_PI_VERSION
    return remote_pi_check(pinned) unless runtime == "local"

    version = @pi_version.call
    if version.nil?
      Check.new(:fail, "pi", "not on PATH — npm i -g @earendil-works/pi-coding-agent@#{pinned}")
    elsif version == pinned
      Check.new(:ok, "pi", "#{version} on PATH")
    else
      Check.new(:warn, "pi", "#{version} on PATH, but pi-agent-rb pins #{pinned}")
    end
  end

  # A remote runtime's pi is baked into a provider artifact at build time, so
  # the pin alone says nothing about what the artifact holds — a stale image
  # left by a gem bump is exactly the drift worth catching, and asserting the
  # pin is "baked in" would report it green. Docker's artifact carries the
  # build's content fingerprint as a label and is read here; the hosted
  # providers' cannot be read without launching a sandbox, so they are
  # reported unverified rather than passed.
  def remote_pi_check(pinned)
    image = Agent::Runtime.runtime_class(runtime).image_ref
    return docker_pi_check(pinned, image) if runtime == "docker"

    Check.new(:off, "pi", "#{pinned} pinned — what the #{runtime} #{artifact_noun} #{image} actually " \
                          "holds is unverifiable from here; bin/rails runtime:image after a bump")
  rescue Agent::Error
    Check.new(:off, "pi", "unknown runtime — see the runtime check")
  end

  def artifact_noun = ARTIFACT_NOUNS.fetch(runtime, "image")

  def docker_pi_check(pinned, image)
    meta = @docker_image.call(image)
    if meta.nil?
      return Check.new(:off, "pi", "#{pinned} pinned into #{image} — no docker daemon here to verify it against")
    end
    unless meta[:present]
      return Check.new(:fail, "pi", "#{image} is not on this docker daemon — bin/rails runtime:image")
    end

    want = PiImageFingerprint.call(pi_version: pinned, arch: meta[:daemon_arch], root: Rails.root)
    if meta[:fingerprint] == want
      Check.new(:ok, "pi", "#{pinned} verified in #{image} (#{meta[:daemon_arch]}, #{want.first(12)})")
    else
      have = meta[:fingerprint].presence&.first(12) || "unlabelled"
      Check.new(:warn, "pi", "#{image} was built from other sources (#{have}, want #{want.first(12)}) — " \
                             "bin/rails runtime:image")
    end
  end



  def runtime = @env.fetch("METIS_AGENT_RUNTIME", "local")

  def runtime_check
    case runtime
    when "local"
      status = Rails.env.production? ? :warn : :ok
      Check.new(status, "runtime", "local — pi runs on the host, no isolation")
    when "docker"
      oci = @env["METIS_DOCKER_RUNTIME"].presence || "runc (daemon default)"
      Check.new(:ok, "runtime", "docker — image #{@env.fetch("METIS_DOCKER_IMAGE", "metis-pi")}, OCI runtime #{oci}")
    when "e2b"
      key_check("runtime", "E2B_API_KEY", ok: "e2b — template #{@env.fetch("METIS_E2B_TEMPLATE", "base")}")
    when "daytona"
      key_check("runtime", "DAYTONA_API_KEY", ok: "daytona — snapshot #{@env.fetch("METIS_DAYTONA_SNAPSHOT", "metis-pi")}")
    when "microsandbox"
      microsandbox_check
    else
      Check.new(:fail, "runtime", "unknown METIS_AGENT_RUNTIME #{runtime.inspect} (local, docker, e2b, daytona, microsandbox)")
    end
  end

  # The gem rides an optional bundler group — the one misconfiguration this
  # runtime uniquely invites is selecting it on a host that never opted in.
  # Only the two errors that actually mean "absent" are caught (Agent::Error
  # is load_gem's translation of LoadError); anything else is a real failure
  # and must not be mislabelled as a missing gem.
  def microsandbox_check
    Agent::Runtime::Microsandbox.load_gem
    Check.new(:ok, "runtime", "microsandbox — #{microsandbox_detail}")
  rescue LoadError, Agent::Error
    Check.new(:fail, "runtime",
      "microsandbox — gem not installed (bundle config set --local with microsandbox && bundle install)")
  end

  def microsandbox_detail
    detail = "image #{@env.fetch("METIS_MICROSANDBOX_IMAGE", "metis-pi")}"
    quota = Rails.configuration.x.agent.microsandbox_workspace_quota_mib
    quota ? "#{detail}, workspace quota #{quota} MiB" : detail
  end

  def providers_check
    configured = Rails.configuration.x.agent.provider_metadata.filter_map do |provider, meta|
      provider if meta[:env] && @env[meta[:env]].present?
    end
    if configured.any?
      Check.new(:ok, "providers", configured.join(", "))
    elsif runtime == "local"
      Check.new(:warn, "providers", "no key in Metis env — local pi may still use its own config (~/.pi)")
    else
      Check.new(:fail, "providers", "no LLM provider key set — ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, …")
    end
  end

  def default_model_check
    provider, model = @env["METIS_AGENT_PROVIDER"], @env["METIS_AGENT_MODEL"]
    if provider.present? || model.present?
      Check.new(:ok, "default model", [ provider, model ].compact_blank.join(" / "))
    else
      Check.new(:off, "default model", "METIS_AGENT_PROVIDER/MODEL unset — pi's own default")
    end
  end

  def web_search_check
    backend = { "SERPER_API_KEY" => "serper", "BRAVE_SEARCH_API_KEY" => "brave",
                "SEARXNG_URL" => "searxng" }.find { |var, _| @env[var].present? }&.last
    if backend
      Check.new(:ok, "web search", backend)
    else
      Check.new(:warn, "web search", "none — DuckDuckGo fallback is rate-limited from sandboxes")
    end
  end

  def storage_checks
    service = Rails.application.config.active_storage.service
    case service
    when :amazon
      missing = %w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_BUCKET AWS_REGION].select { |var| @env[var].blank? }
      if missing.any?
        [ Check.new(:fail, "uploads", "S3 selected but #{missing.join(", ")} unset") ]
      else
        [ Check.new(:ok, "uploads", "S3 bucket #{@env["AWS_BUCKET"]} (#{@env["AWS_REGION"]})") ]
      end
    when :local
      status = Rails.env.production? ? :warn : :ok
      [ Check.new(status, "uploads", "local disk — set AWS_* for S3") ]
    else
      [ Check.new(:off, "uploads", service.to_s) ]
    end
  end

  def access_checks
    mode = @env.fetch("METIS_REGISTRATION_MODE", "invite_only")
    domains = @env.fetch("METIS_ALLOWED_DOMAINS", "")
    detail = mode
    detail += " (open domains: #{domains})" if domains.present?
    [ Check.new(:ok, "registration", detail) ]
  end

  def connector_checks
    [ pair_check("github app", %w[GITHUB_APP_CLIENT_ID GITHUB_APP_CLIENT_SECRET]),
      pair_check("github bot", %w[GITHUB_APP_ID GITHUB_APP_PRIVATE_KEY]),
      pair_check("google oauth", %w[GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET]),
      pair_check("linear", %w[LINEAR_CLIENT_ID LINEAR_CLIENT_SECRET]),
      x_check ]
  end

  # X config resolves ENV-then-credentials per key (XApp::Config), so this
  # can't be a plain pair_check; missing keys are reported by ENV name.
  def x_check
    missing = XApp::Config.missing_keys(env: @env)
    if missing.empty?
      Check.new(:ok, "x oauth", "configured")
    elsif missing.size == XApp::Config::KEYS.size
      Check.new(:off, "x oauth", "not configured")
    else
      Check.new(:fail, "x oauth", "partial — #{missing.join(", ")} unset")
    end
  end

  def observability_checks
    enabled = Observability.truthy?(@env["METIS_LANGFUSE_ENABLED"])
    keys = %w[LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY].select { |var| @env[var].blank? }
    if enabled && keys.empty?
      [ Check.new(:ok, "langfuse", "export on (#{@env.fetch("LANGFUSE_HOST", "https://cloud.langfuse.com")})") ]
    elsif enabled
      [ Check.new(:fail, "langfuse", "METIS_LANGFUSE_ENABLED set but #{keys.join(", ")} unset") ]
    else
      [ Check.new(:off, "langfuse", "export off") ]
    end
  end

  def pair_check(name, vars)
    missing = vars.select { |var| @env[var].blank? }
    if missing.empty?
      Check.new(:ok, name, "configured")
    elsif missing == vars
      Check.new(:off, name, "not configured")
    else
      Check.new(:fail, name, "partial — #{missing.join(", ")} unset")
    end
  end

  def key_check(name, var, ok:)
    if @env[var].present?
      Check.new(:ok, name, ok)
    else
      Check.new(:fail, name, "#{ok.split(" — ").first} selected but #{var} unset")
    end
  end
end
