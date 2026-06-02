# Outbound email. Metis sends through Cloudflare Email Service's REST
# API (Delivery::Cloudflare), not SMTP. The account id + scoped API
# token are a deployment-level resource — supplied via ENV like the
# agent provider keys, never per-user. The sender domain must be one
# verified in the Cloudflare account.
Rails.application.config.x.mail.from =
  ENV.fetch("METIS_MAIL_FROM", "Metis <noreply@example.com>")

# Retry transient Cloudflare failures instead of dropping the email.
Rails.application.config.action_mailer.delivery_job = "MailDeliveryJob"

# Registered in to_prepare so the autoloaded Delivery::Cloudflare
# constant resolves (and survives dev reloads); add_delivery_method is
# idempotent.
Rails.application.config.to_prepare do
  ActionMailer::Base.add_delivery_method :cloudflare, Delivery::Cloudflare,
    account_id: ENV["CLOUDFLARE_ACCOUNT_ID"].presence,
    api_token: ENV["CLOUDFLARE_EMAIL_API_TOKEN"].presence
end
