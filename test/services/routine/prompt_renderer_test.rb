require "test_helper"

class Routine
  class PromptRendererTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pr-#{SecureRandom.hex(4)}@example.com", password: "password123")
      @team = @user.personal_team
    end

    def routine(prompt, **attrs)
      @team.routines.create!({
        user: @user, name: "R-#{SecureRandom.hex(2)}", prompt: prompt,
        trigger_source: :schedule, cron: "0 9 * * *", timezone: "UTC"
      }.merge(attrs))
    end

    test "interpolates built-in vars and leaves unknown placeholders alone" do
      out = Routine::PromptRenderer.render(routine("On {{date}} for {{team}}, ping {{nobody}}"))
      assert_match @team.name, out
      assert_match(/\d{4}-\d{2}-\d{2}/, out)
      assert_match "{{nobody}}", out
    end

    test "merges custom variables from trigger_config" do
      r = routine("Channel: {{channel}}", trigger_config: { "variables" => { "channel" => "#eng" } })
      assert_equal "Channel: #eng", Routine::PromptRenderer.render(r)
    end

    test "built-in vars win over a colliding custom variable" do
      r = routine("Today is {{date}}", trigger_config: { "variables" => { "date" => "NEVER" } })
      out = Routine::PromptRenderer.render(r)
      assert_no_match(/NEVER/, out)
      assert_match(/\d{4}-\d{2}-\d{2}/, out)
    end

    test "fills event vars on the webhook path" do
      r = routine("Got {{event_type}}", trigger_source: :webhook, cron: nil, event_type: "push")
      event = WebhookEvent.new(team: @team, provider: :github, event_type: "push", payload: { "ref" => "main" })
      out = Routine::PromptRenderer.render(r, event: event)
      assert_equal "Got push", out
    end
  end
end
