require "test_helper"

class HunchTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "h-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
  end

  def hunch(**attrs)
    Hunch.create!({ user: @user, team: @team, title: "Brief", body: "Body", why_now: "Soon",
                    evidence: [ { "title" => "Src", "url" => "https://example.com" } ] }.merge(attrs))
  end

  test "use records the outcome" do
    item = hunch
    item.use!
    assert item.used?
    assert item.outcome_at
  end

  test "dismiss keeps the optional reason" do
    item = hunch
    item.dismiss!("Not relevant")
    assert item.dismissed?
    assert_equal "Not relevant", item.dismiss_reason
  end

  test "expire_stale! expires only ready hunches past the TTL" do
    old = hunch(created_at: (Hunch::TTL + 1.day).ago)
    used = hunch(created_at: (Hunch::TTL + 1.day).ago, status: :used)
    fresh = hunch

    Hunch.expire_stale!
    assert old.reload.expired?
    assert used.reload.used?
    assert fresh.reload.ready?
  end

  test "prompt carries the work, why now and sources" do
    prompt = hunch.prompt
    assert_match "**Brief**", prompt
    assert_match "Soon", prompt
    assert_match "[Src](https://example.com)", prompt
  end
end
