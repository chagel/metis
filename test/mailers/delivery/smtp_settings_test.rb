require "test_helper"

class Delivery::SmtpSettingsTest < ActiveSupport::TestCase
  test "returns nil when no address is configured" do
    assert_nil Delivery::SmtpSettings.from_env({})
    assert_nil Delivery::SmtpSettings.from_env({ "SMTP_ADDRESS" => "", "SMTP_HOST" => "" })
  end

  test "SMTP_HOST is honored as an alias for SMTP_ADDRESS" do
    settings = Delivery::SmtpSettings.from_env({ "SMTP_HOST" => "smtp.legacy.test" })

    assert_equal "smtp.legacy.test", settings[:address]
  end

  test "SMTP_ADDRESS wins over the SMTP_HOST alias" do
    settings = Delivery::SmtpSettings.from_env(
      { "SMTP_ADDRESS" => "smtp.new.test", "SMTP_HOST" => "smtp.legacy.test" }
    )

    assert_equal "smtp.new.test", settings[:address]
  end

  test "a present-but-empty SMTP_PORT falls back to 587 instead of crashing" do
    settings = Delivery::SmtpSettings.from_env(
      { "SMTP_ADDRESS" => "smtp.example.com", "SMTP_PORT" => "" }
    )

    assert_equal 587, settings[:port]
  end

  test "an explicit SMTP_PORT is coerced to an integer" do
    settings = Delivery::SmtpSettings.from_env(
      { "SMTP_ADDRESS" => "smtp.example.com", "SMTP_PORT" => "2525" }
    )

    assert_equal 2525, settings[:port]
  end

  test "blank credentials mean no AUTH (authentication key omitted)" do
    settings = Delivery::SmtpSettings.from_env(
      { "SMTP_ADDRESS" => "smtp.example.com", "SMTP_USERNAME" => "", "SMTP_PASSWORD" => "" }
    )

    assert_nil settings[:user_name]
    assert_nil settings[:password]
    assert_not settings.key?(:authentication)
  end

  test "a username enables plain authentication by default" do
    settings = Delivery::SmtpSettings.from_env(
      { "SMTP_ADDRESS" => "smtp.example.com", "SMTP_USERNAME" => "u", "SMTP_PASSWORD" => "p" }
    )

    assert_equal "u", settings[:user_name]
    assert_equal :plain, settings[:authentication]
  end

  test "SMTP_AUTHENTICATION overrides the auth mechanism" do
    settings = Delivery::SmtpSettings.from_env(
      { "SMTP_ADDRESS" => "smtp.example.com", "SMTP_USERNAME" => "u",
        "SMTP_AUTHENTICATION" => "login" }
    )

    assert_equal :login, settings[:authentication]
  end

  test "STARTTLS is enabled by default and mutually exclusive with implicit TLS" do
    settings = Delivery::SmtpSettings.from_env({ "SMTP_ADDRESS" => "smtp.example.com" })

    assert_equal true, settings[:enable_starttls_auto]
    assert_not settings.key?(:tls)
  end

  test "SMTP_ENABLE_STARTTLS=false disables the STARTTLS upgrade" do
    settings = Delivery::SmtpSettings.from_env(
      { "SMTP_ADDRESS" => "smtp.example.com", "SMTP_ENABLE_STARTTLS" => "false" }
    )

    assert_equal false, settings[:enable_starttls_auto]
  end

  test "SMTP_TLS=true selects implicit TLS and omits STARTTLS" do
    settings = Delivery::SmtpSettings.from_env(
      { "SMTP_ADDRESS" => "smtp.example.com", "SMTP_TLS" => "true" }
    )

    assert_equal true, settings[:tls]
    assert_not settings.key?(:enable_starttls_auto)
  end
end
