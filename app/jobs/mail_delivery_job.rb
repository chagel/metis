require "net/smtp"

# The job behind every deliver_later. Retries transient delivery
# failures (rate limits, a busy or briefly unreachable server, network
# blips) with backoff so a momentary blip doesn't silently drop an email
# the user was told we sent. Permanent failures (bad address, bad
# credentials) are not retried — they surface to Sentry via the parent's
# exception handling.
class MailDeliveryJob < ActionMailer::MailDeliveryJob
  retry_on Delivery::Cloudflare::TransientError,
    Net::SMTPServerBusy, Net::OpenTimeout, Net::ReadTimeout,
    Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT, SocketError, EOFError,
    wait: :polynomially_longer, attempts: 5
end
