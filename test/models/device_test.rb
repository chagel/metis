require "test_helper"

class DeviceTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "dev-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
  end

  def new_device(**attrs)
    @team.devices.create!({ user: @user, name: "macbook" }.merge(attrs))
  end

  test "mints a plaintext token on create and stores only its digest" do
    device = new_device
    assert device.plaintext_token.present?
    assert device.plaintext_token.start_with?("mbd_")
    assert_equal Device.digest(device.plaintext_token), device.token_digest
  end

  test "authenticate resolves a token to its device" do
    device = new_device
    assert_equal device, Device.authenticate(device.plaintext_token)
    assert_nil Device.authenticate("mbd_wrong")
    assert_nil Device.authenticate(nil)
  end

  test "online? and the online scope track the presence window" do
    fresh = new_device
    fresh.update_column(:last_seen_at, 5.seconds.ago)
    stale = new_device
    stale.update_column(:last_seen_at, 5.minutes.ago)
    never = new_device

    assert fresh.online?
    assert_not stale.online?
    assert_not never.online?
    assert_equal [ fresh ], @team.devices.online.to_a
  end

  test "seen! stamps last_seen_at" do
    device = new_device
    assert_nil device.last_seen_at
    device.seen!
    assert device.online?
  end

  test "token_digest is unique" do
    digest = new_device.token_digest
    dup = @team.devices.new(user: @user, name: "other", token_digest: digest)
    assert_not dup.valid?
    assert_includes dup.errors[:token_digest], "has already been taken"
  end

  test "name is required" do
    assert_not @team.devices.new(user: @user, name: "").valid?
  end
end
