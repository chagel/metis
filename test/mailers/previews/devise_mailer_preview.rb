# Preview Devise's emails in development at /rails/mailers/devise_mailer.
# Builds an in-memory user — nothing is persisted.
class DeviseMailerPreview < ActionMailer::Preview
  def reset_password_instructions
    user = User.new(email: "you@example.com")
    Devise::Mailer.reset_password_instructions(user, "preview-token")
  end
end
