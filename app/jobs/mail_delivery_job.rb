# The job behind every deliver_later. Retries transient Cloudflare
# failures (rate limits, 5xx, network blips) with backoff so a momentary
# blip doesn't silently drop an email the user was told we sent. Permanent
# failures (Delivery::Cloudflare::Error and everything else) are not
# retried — they surface to Sentry via the parent's exception handling.
class MailDeliveryJob < ActionMailer::MailDeliveryJob
  retry_on Delivery::Cloudflare::TransientError, wait: :polynomially_longer, attempts: 5
end
