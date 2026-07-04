# Outbound email, wired in one place. Two transports: Rails' built-in
# :smtp (any provider — set the SMTP_* vars) and Cloudflare Email
# Service's REST API (Delivery::Cloudflare). SMTP_ADDRESS selects
# :smtp, a CLOUDFLARE_EMAIL_API_TOKEN selects :cloudflare, and
# METIS_MAIL_DELIVERY=smtp|cloudflare|test forces one explicitly.
# Credentials are a deployment-level resource — supplied via ENV like
# the agent provider keys, never per-user. The sender must be on a
# domain the transport may send for. See
# docs/configuration.md#email--account-access.
Rails.application.config.x.mail.from =
  ENV.fetch("METIS_MAIL_FROM", "Metis <noreply@example.com>")

# SMTP_HOST is accepted as an alias — .env.example long shipped that name.
smtp_address = ENV["SMTP_ADDRESS"].presence || ENV["SMTP_HOST"].presence

if smtp_address
  settings = {
    address: smtp_address,
    port: Integer(ENV.fetch("SMTP_PORT", 587)),
    domain: ENV["SMTP_DOMAIN"].presence,
    user_name: ENV["SMTP_USERNAME"].presence,
    password: ENV["SMTP_PASSWORD"].presence,
    open_timeout: 5,
    read_timeout: 10
  }.compact
  settings[:authentication] = ENV.fetch("SMTP_AUTHENTICATION", "plain").to_sym if settings[:user_name]
  # Implicit TLS (SMTPS, port-465 style) and STARTTLS are mutually
  # exclusive in Net::SMTP.
  if ENV["SMTP_TLS"] == "true"
    settings[:tls] = true
  else
    settings[:enable_starttls_auto] = ENV.fetch("SMTP_ENABLE_STARTTLS", "true") == "true"
  end
  Rails.application.config.action_mailer.smtp_settings = settings
end

# The test environment always stubs delivery (config/environments/test.rb).
unless Rails.env.test?
  Rails.application.config.action_mailer.delivery_method =
    ENV.fetch("METIS_MAIL_DELIVERY") do
      if smtp_address then "smtp"
      elsif ENV["CLOUDFLARE_EMAIL_API_TOKEN"].present? then "cloudflare"
      # Unconfigured production still routes to :cloudflare so the first
      # send fails loudly, pointing at the missing env vars; development
      # just accumulates in ActionMailer::Base.deliveries.
      elsif Rails.env.production? then "cloudflare"
      else "test"
      end
    end.to_sym
end

# Retry transient delivery failures instead of dropping the email.
Rails.application.config.action_mailer.delivery_job = "MailDeliveryJob"

# Registered in to_prepare so the autoloaded Delivery::Cloudflare
# constant resolves (and survives dev reloads); add_delivery_method is
# idempotent.
Rails.application.config.to_prepare do
  ActionMailer::Base.add_delivery_method :cloudflare, Delivery::Cloudflare,
    account_id: ENV["CLOUDFLARE_ACCOUNT_ID"].presence,
    api_token: ENV["CLOUDFLARE_EMAIL_API_TOKEN"].presence
end
