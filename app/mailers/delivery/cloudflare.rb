require "net/http"
require "json"

module Delivery
  # ActionMailer delivery method that sends through Cloudflare Email
  # Service's REST API rather than SMTP:
  # https://developers.cloudflare.com/email-service/api/send-emails/rest-api/
  #
  # Registered as :cloudflare in config/initializers/mail.rb; an
  # environment opts in via config.action_mailer.delivery_method. The
  # account id + scoped API token are a deployment-level resource (no
  # per-user keys), passed in as settings. Raising on failure lets the
  # existing MailDeliveryJob path record/retry it — same contract as the
  # built-in :smtp method.
  class Cloudflare
    Error = Class.new(StandardError)
    # A retryable failure — a rate-limit, a Cloudflare 5xx, or a network
    # blip. The delivery job retries these; permanent 4xx stay as Error.
    TransientError = Class.new(Error)

    ENDPOINT = "https://api.cloudflare.com/client/v4/accounts/%s/email/sending/send".freeze

    NETWORK_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
      Errno::ETIMEDOUT, SocketError, EOFError, IOError
    ].freeze

    def initialize(settings = {})
      @account_id = settings[:account_id]
      @api_token  = settings[:api_token]
    end

    def deliver!(mail)
      if @account_id.blank? || @api_token.blank?
        raise Error, "Cloudflare email is not configured (set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_EMAIL_API_TOKEN)"
      end

      response = post(payload(mail))
      code = response.code.to_i
      return mail if code.between?(200, 299)

      message = "Cloudflare email send failed (#{response.code}): #{response.body.to_s.truncate(300)}"
      # 429 (rate limit) and 5xx are worth retrying; 4xx (bad address,
      # unverified sender, disabled account) are permanent.
      raise(code == 429 || code >= 500 ? TransientError : Error, message)
    rescue *NETWORK_ERRORS => e
      raise TransientError, "Cloudflare email send failed (#{e.class}): #{e.message}"
    end

    # Maps a Mail::Message onto Cloudflare's flat JSON body. Public so the
    # mapping is unit-testable without touching the network.
    def payload(mail)
      body = {
        from: mail[:from].formatted.first,
        to: mail.to,
        subject: mail.subject
      }
      body[:reply_to] = mail[:reply_to].formatted.first if mail.reply_to.present?
      body[:cc] = mail.cc if mail.cc.present?
      body[:bcc] = mail.bcc if mail.bcc.present?

      html, text = body_parts(mail)
      body[:html] = html if html.present?
      body[:text] = text if text.present?
      body
    end

    private

    def body_parts(mail)
      if mail.multipart?
        [ mail.html_part&.body&.decoded, mail.text_part&.body&.decoded ]
      elsif mail.mime_type == "text/html"
        [ mail.body.decoded, nil ]
      else
        [ nil, mail.body.decoded ]
      end
    end

    def post(body)
      uri = URI(format(ENDPOINT, @account_id))
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@api_token}"
      request["Content-Type"] = "application/json"
      request.body = body.to_json

      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 10
      http.request(request)
    end
  end
end
