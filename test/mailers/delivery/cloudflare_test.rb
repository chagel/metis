require "test_helper"

class Delivery::CloudflareTest < ActiveSupport::TestCase
  setup do
    @delivery = Delivery::Cloudflare.new(account_id: "acct_123", api_token: "tok_secret")
    @mail = Mail.new do
      from "Metis <noreply@metis.test>"
      to "alice@example.com"
      reply_to "owner@metis.test"
      subject "You're invited"
      text_part { body "Join us: https://metis.test/x" }
      html_part do
        content_type "text/html; charset=UTF-8"
        body "<p>Join us</p>"
      end
    end
  end

  test "maps a multipart message onto Cloudflare's flat JSON body" do
    payload = @delivery.payload(@mail)

    assert_equal "Metis <noreply@metis.test>", payload[:from]
    assert_equal [ "alice@example.com" ], payload[:to]
    assert_equal "owner@metis.test", payload[:reply_to]
    assert_equal "You're invited", payload[:subject]
    assert_equal "<p>Join us</p>", payload[:html]
    assert_equal "Join us: https://metis.test/x", payload[:text]
  end

  test "deliver! posts to the account endpoint with bearer auth and returns the mail" do
    captured = stub_http(response(200, %({"success":true}))) do
      assert_equal @mail, @delivery.deliver!(@mail)
    end

    assert_equal "api.cloudflare.com", captured[:host]
    assert_equal "/client/v4/accounts/acct_123/email/sending/send", captured[:path]
    assert_equal "Bearer tok_secret", captured[:authorization]
    assert_equal "You're invited", JSON.parse(captured[:body])["subject"]
  end

  test "deliver! raises a permanent Error on a 4xx response" do
    stub_http(response(403, %({"errors":[{"code":10203}]}))) do
      error = assert_raises(Delivery::Cloudflare::Error) { @delivery.deliver!(@mail) }
      assert_not_kind_of Delivery::Cloudflare::TransientError, error
      assert_match "403", error.message
    end
  end

  test "deliver! raises a TransientError on a rate limit or 5xx, so the job retries" do
    stub_http(response(429, "rate limited")) do
      assert_raises(Delivery::Cloudflare::TransientError) { @delivery.deliver!(@mail) }
    end
    stub_http(response(503, "unavailable")) do
      assert_raises(Delivery::Cloudflare::TransientError) { @delivery.deliver!(@mail) }
    end
  end

  test "deliver! turns a network failure into a TransientError" do
    original = Net::HTTP.instance_method(:request)
    Net::HTTP.define_method(:request) { |_req| raise Net::OpenTimeout }
    assert_raises(Delivery::Cloudflare::TransientError) { @delivery.deliver!(@mail) }
  ensure
    Net::HTTP.define_method(:request, original)
  end

  test "deliver! raises when the account id or token is missing" do
    assert_raises(Delivery::Cloudflare::Error) do
      Delivery::Cloudflare.new({}).deliver!(@mail)
    end
  end

  # Guard: the suite must never send real email through Cloudflare, even
  # if a live token leaks into the test env (dotenv, CI secrets, …).
  test "the test environment uses :test delivery, not :cloudflare" do
    assert_equal :test, ActionMailer::Base.delivery_method
  end

  private

  def response(code, body)
    Struct.new(:code, :body).new(code.to_s, body)
  end

  # Swap Net::HTTP#request for the block, capturing the outgoing request
  # and returning the canned response. Minitest 6 dropped Object#stub.
  def stub_http(canned)
    original = Net::HTTP.instance_method(:request)
    captured = {}
    Net::HTTP.define_method(:request) do |req|
      captured[:host] = address
      captured[:path] = req.path
      captured[:authorization] = req["Authorization"]
      captured[:body] = req.body
      canned
    end
    yield captured
    captured
  ensure
    Net::HTTP.define_method(:request, original)
  end
end
