# Configuration checklist behind `bin/rails metis:doctor`: reports each
# subsystem as configured, missing, or defaulted — with the exact env
# var names — so a deployer doesn't have to read initializers to learn
# what the app expects. Never prints secret values, only presence.
class Doctor
  Check = Data.define(:status, :name, :detail) # status: :ok, :warn, :fail, :off

  SYMBOLS = { ok: "✓", warn: "!", fail: "✗", off: "-" }.freeze

  def initialize(env: ENV, delivery_method: ActionMailer::Base.delivery_method)
    @env = env
    @delivery_method = delivery_method
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
    [ runtime_check, providers_check, default_model_check, web_search_check ]
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
    else
      Check.new(:fail, "runtime", "unknown METIS_AGENT_RUNTIME #{runtime.inspect} (local, docker, e2b, daytona)")
    end
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
      pair_check("linear", %w[LINEAR_CLIENT_ID LINEAR_CLIENT_SECRET]) ]
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
