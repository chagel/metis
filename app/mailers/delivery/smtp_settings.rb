module Delivery
  # Builds the ActionMailer :smtp settings hash from ENV. Extracted from
  # config/initializers/mail.rb so the branching (SMTP_HOST alias, port
  # coercion, TLS vs STARTTLS exclusivity, AUTH only when a username is
  # set) is unit-testable without booting an environment.
  #
  # Treats a present-but-empty var the same as an absent one: .env.example
  # ships blank SMTP_* lines and foreman exports them as "", so a partial
  # config (e.g. only SMTP_ADDRESS filled, the documented minimum) must not
  # crash boot on Integer("").
  module SmtpSettings
    module_function

    # Returns the settings hash, or nil when no SMTP address is configured
    # (the caller then leaves ActionMailer's smtp_settings untouched).
    def from_env(env)
      address = env["SMTP_ADDRESS"].presence || env["SMTP_HOST"].presence
      return nil unless address

      settings = {
        address: address,
        port: Integer(env["SMTP_PORT"].presence || 587),
        domain: env["SMTP_DOMAIN"].presence,
        user_name: env["SMTP_USERNAME"].presence,
        password: env["SMTP_PASSWORD"].presence,
        open_timeout: 5,
        read_timeout: 10
      }.compact

      if settings[:user_name]
        settings[:authentication] = (env["SMTP_AUTHENTICATION"].presence || "plain").to_sym
      end

      # Implicit TLS (SMTPS, port-465 style) and STARTTLS are mutually
      # exclusive in Net::SMTP.
      if env["SMTP_TLS"] == "true"
        settings[:tls] = true
      else
        settings[:enable_starttls_auto] = (env["SMTP_ENABLE_STARTTLS"].presence || "true") == "true"
      end

      settings
    end
  end
end
