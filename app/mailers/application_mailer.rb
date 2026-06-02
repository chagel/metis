class ApplicationMailer < ActionMailer::Base
  default from: -> { Rails.application.config.x.mail.from }
  layout "mailer"
end
