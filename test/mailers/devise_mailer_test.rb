require "test_helper"

class DeviseMailerTest < ActionMailer::TestCase
  test "Devise emails are sent through the job queue, not inline" do
    user = User.create!(email: "async@example.com", password: "password123")

    assert_enqueued_emails 1 do
      user.send_reset_password_instructions
    end
  end

  test "reset password email uses our sender, branded layout, and the reset link" do
    user = User.create!(email: "reset@example.com", password: "password123")

    mail = Devise::Mailer.reset_password_instructions(user, "tok-abc123")

    assert_equal [ "reset@example.com" ], mail.to
    # From the deployment sender (must be a verified domain), not Devise's
    # please-change-me placeholder.
    assert_equal "Metis <noreply@example.com>", mail[:from].formatted.first

    # Decode quoted-printable so the link's "=" isn't mangled to "=3D".
    body = mail.text_part.body.decoded
    assert_match "Reset your password", body
    assert_match "reset_password_token=tok-abc123", body
    # Branded layout (layouts/mailer) is applied via config.parent_mailer.
    assert_match "Your AI agent workspace", body
  end
end
