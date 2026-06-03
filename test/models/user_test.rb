require "test_helper"

class UserTest < ActiveSupport::TestCase
  def create_user
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", password: "password123")
  end

  def github_auth(uid:, email:)
    OmniAuth::AuthHash.new(provider: "github", uid: uid.to_s,
                           info: { email: email, nickname: "x" })
  end

  test "from_omniauth refuses to create a brand-new account when signup is disallowed" do
    assert_no_difference("User.count") do
      assert_raises(User::SignupNotAllowed) do
        User.from_omniauth(github_auth(uid: "no-signup", email: "stranger@example.com"), allow_signup: false)
      end
    end
  end

  test "from_omniauth signs in an existing user even when signup is disallowed" do
    user = create_user
    user.identities.create!(provider: "github", uid: "known-1")

    returned = User.from_omniauth(github_auth(uid: "known-1", email: user.email), allow_signup: false)
    assert_equal user, returned
  end

  test "a new user gets a personal team owned by them" do
    user = create_user

    assert user.personal_team, "personal team created at signup"
    assert user.personal_team.personal?
    assert_equal "owner", user.memberships.find_by(team: user.personal_team).role
  end

  test "personal_team is the user's team-of-one" do
    user = create_user

    assert_equal [ user ], user.personal_team.members
  end

  test "destroying a user destroys its memberships" do
    user = create_user

    assert_difference("Membership.count", -1) { user.destroy }
  end

  test "display_label falls back to email when display_name is blank" do
    user = create_user
    assert_equal user.email, user.display_label

    user.update!(display_name: "Mike Chen")
    assert_equal "Mike Chen", user.display_label
  end

  test "initials are derived from display name when set, email otherwise" do
    user = User.new(email: "alex.kim@example.com")
    assert_equal "AK", user.initials

    user.display_name = "Mike Chen"
    assert_equal "MC", user.initials

    user.display_name = "q"
    assert_equal "Q", user.initials
  end

  test "profile_update context requires a display name" do
    user = create_user
    user.display_name = ""
    refute user.valid?(:profile_update)
    assert_includes user.errors[:display_name], "can't be blank"
  end

  test "normalizes profile string fields: trims whitespace, blanks become nil" do
    user = User.create!(
      email: "u-#{SecureRandom.hex(4)}@example.com", password: "password123",
      display_name: "  Mike  ", timezone: "  Tokyo  ",
      language: "  en  ", preferred_model: "  "
    )
    assert_equal "Mike", user.display_name
    assert_equal "Tokyo", user.timezone
    assert_equal "en", user.language
    assert_nil user.preferred_model
  end

  test "timezone must be a known Rails-friendly zone name" do
    user = create_user
    user.timezone = "Mars/Olympus"
    refute user.valid?

    # The validator is `inclusion: ActiveSupport::TimeZone.all.map(&:name)`
    # — i.e. the curated Rails-friendly names rendered by
    # `time_zone_select`. IANA names like "America/Los_Angeles" arrive
    # only via ProfilesController#detect_timezone, which canonicalizes
    # before persisting.
    user.timezone = "Pacific Time (US & Canada)"
    assert user.valid?
  end

  test "preferred_model must be in the catalog" do
    user = create_user
    user.preferred_model = "no-such-model"
    refute user.valid?

    user.preferred_model = seed_catalog_model
    assert user.valid?
  end

  test "preferred_model accepts the configured fallback before the catalog is seeded" do
    original = Rails.application.config.x.agent.model
    Rails.application.config.x.agent.model = "gpt-5.5"
    user = create_user
    user.preferred_model = "gpt-5.5"

    assert user.valid?
  ensure
    Rails.application.config.x.agent.model = original
  end

  test "placeholder_email? matches the metis synth suffix and GitHub's noreply, anchored" do
    assert User.placeholder_email?("90943+chagel@users.noreply.github.com")
    assert User.placeholder_email?("42+mgc@github.users.noreply.metis")

    # Real addresses that happen to contain the legacy substring must
    # NOT be treated as placeholders — they are real emails users
    # registered with and backfill would silently overwrite them.
    refute User.placeholder_email?("alex@users.noreply.corp.com")
    refute User.placeholder_email?("me+users.noreply.test@gmail.com")
    refute User.placeholder_email?("real@example.com")
  end

  test "backfill_real_email swallows uniqueness collisions so sign-in proceeds" do
    User.create!(email: "taken@example.com", password: "password123")
    placeholder = User.create!(
      email: "888+mgc@users.noreply.github.com", password: "password123"
    )
    auth = mock_auth(email: "taken@example.com")

    assert_nothing_raised { User.backfill_real_email(placeholder, auth) }
    assert_equal "888+mgc@users.noreply.github.com", placeholder.reload.email
  end

  test "backfill_real_email swallows a Devise-invalid email so sign-in proceeds" do
    placeholder = User.create!(
      email: "999+mgc@users.noreply.github.com", password: "password123"
    )
    auth = mock_auth(email: "not-an-email")

    assert_nothing_raised { User.backfill_real_email(placeholder, auth) }
    assert_equal "999+mgc@users.noreply.github.com", placeholder.reload.email
  end

  test "from_omniauth race-recovers to the winner's user without leaving an orphan User" do
    # Simulate the late half of the concurrent-first-sign-in race: the
    # winner has already committed an Identity for (provider, uid). The
    # loser's from_omniauth call now: misses Identity.find_by (the test
    # forces the timing by pre-creating the identity), enters the
    # transaction, builds a new User with a different email, hits the
    # unique index on identities.uid, rolls back, retries — second
    # pass finds the winner's identity and returns the winner.
    winner = User.create!(email: "winner-#{SecureRandom.hex(4)}@example.com", password: "password123")
    winner.identities.create!(provider: "github", uid: "race-1")
    auth = mock_auth(provider: "github", uid: "race-1", email: "loser-#{SecureRandom.hex(4)}@example.com")

    result = nil
    assert_no_difference("User.count", "the loser's User must not be persisted") do
      assert_no_difference("Team.count", "the loser's personal Team must not be persisted") do
        result = User.from_omniauth(auth)
      end
    end

    assert_equal winner, result, "race recovery must return the winner's user"
  end

  test "from_omniauth caches the provider's avatar URL on first sign-in" do
    auth = mock_auth(provider: "github", uid: "av-1",
                     email: "ava-#{SecureRandom.hex(4)}@example.com",
                     image: "https://avatars.example.com/u/123.png")
    user = User.from_omniauth(auth)
    assert_equal "https://avatars.example.com/u/123.png", user.avatar_url
  end

  test "backfill_avatar_url refreshes the cached URL on subsequent sign-in" do
    auth = mock_auth(provider: "github", uid: "av-2",
                     email: "ava-#{SecureRandom.hex(4)}@example.com",
                     image: "https://avatars.example.com/old.png")
    user = User.from_omniauth(auth)
    assert_equal "https://avatars.example.com/old.png", user.avatar_url

    fresh = mock_auth(provider: "github", uid: "av-2",
                      email: auth.info.email,
                      image: "https://avatars.example.com/new.png")
    User.from_omniauth(fresh)
    assert_equal "https://avatars.example.com/new.png", user.reload.avatar_url
  end

  test "backfill_avatar_url does not override an uploaded avatar" do
    user = create_user
    user.avatar.attach(
      io: File.open(Rails.root.join("test/fixtures/files/sample.png")),
      filename: "sample.png", content_type: "image/png"
    )
    auth = mock_auth(image: "https://avatars.example.com/u/999.png")
    User.backfill_avatar_url(user, auth)

    assert_nil user.avatar_url
    assert user.avatar.attached?
  end

  test "avatar rejects an oversized blob" do
    user = create_user
    user.avatar.attach(
      io: StringIO.new("x" * (User::AVATAR_MAX_BYTES + 1)),
      filename: "huge.png", content_type: "image/png"
    )
    refute user.valid?
    assert user.errors[:avatar].any? { |msg| msg.include?("under") }
  end

  test "avatar rejects an unsupported content type" do
    user = create_user
    user.avatar.attach(
      io: StringIO.new("not really a tiff"),
      filename: "weird.tiff", content_type: "image/tiff"
    )
    refute user.valid?
    assert user.errors[:avatar].any? { |msg| msg.include?("JPEG") }
  end

  private

  def mock_auth(provider: "github", uid: "1", email: nil, nickname: "mgc", image: nil)
    OmniAuth::AuthHash.new(provider: provider, uid: uid.to_s,
                           info: { email: email, nickname: nickname, image: image })
  end
end
