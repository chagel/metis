# Outbound email credentials. The delivery method itself is set per
# environment (config/environments/*.rb via METIS_MAIL_DELIVERY): :smtp
# is Rails' built-in transport fed by the SMTP_* settings below,
# :cloudflare is Cloudflare Email Service's REST API
# (Delivery::Cloudflare). Credentials are a deployment-level resource —
# supplied via ENV like the agent provider keys, never per-user. The
# sender must be on a domain the transport may send for. See
# docs/configuration.md#email--account-access.
Rails.application.config.x.mail.from =
  ENV.fetch("METIS_MAIL_FROM", "Metis <noreply@example.com>")

# SMTP_HOST is accepted as an alias — .env.example long shipped that name.
if (smtp_address = ENV["SMTP_ADDRESS"].presence || ENV["SMTP_HOST"].presence)
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
