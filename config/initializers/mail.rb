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

# Retry transient delivery failures instead of dropping the email.
Rails.application.config.action_mailer.delivery_job = "MailDeliveryJob"

# Registered in to_prepare so the autoloaded Delivery::* constants
# resolve (and survive dev reloads). SMTP_HOST is accepted as an alias
# for SMTP_ADDRESS — .env.example long shipped that name; and
# Delivery::SmtpSettings.from_env treats present-but-empty vars as unset,
# so a partial config from the shipped .env.example can't crash boot.
# add_delivery_method is idempotent.
Rails.application.config.to_prepare do
  if (smtp_settings = Delivery::SmtpSettings.from_env(ENV))
    ActionMailer::Base.smtp_settings = smtp_settings
  end

  ActionMailer::Base.add_delivery_method :cloudflare, Delivery::Cloudflare,
    account_id: ENV["CLOUDFLARE_ACCOUNT_ID"].presence,
    api_token: ENV["CLOUDFLARE_EMAIL_API_TOKEN"].presence
end
