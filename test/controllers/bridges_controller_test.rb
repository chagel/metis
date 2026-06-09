require "test_helper"

class BridgesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "br-#{SecureRandom.hex(4)}@example.com", password: "password123")
    sign_in @user
  end

  def team = @user.personal_team

  test "index lists the team's devices" do
    team.devices.create!(user: @user, name: "macbook")
    get bridges_path
    assert_response :success
    assert_select ".conn-list .conn-name", text: /macbook/
  end

  test "index empty state" do
    get bridges_path
    assert_response :success
    assert_select ".pane-empty"
  end

  test "create enrolls a device and shows the token once" do
    assert_difference -> { team.devices.count }, 1 do
      post bridges_path, params: { device: { name: "laptop", agent_kind: "pi" } }
    end
    assert_response :success
    # The plaintext token appears once in the response, never persisted.
    assert_match(/mbd_/, response.body)
    assert_not_nil team.devices.find_by(name: "laptop")
  end

  test "create rejects a blank name" do
    assert_no_difference -> { team.devices.count } do
      post bridges_path, params: { device: { name: "" } }
    end
    assert_response :unprocessable_entity
  end

  test "destroy revokes a device" do
    device = team.devices.create!(user: @user, name: "macbook")
    assert_difference -> { team.devices.count }, -1 do
      delete bridge_path(device)
    end
    assert_redirected_to bridges_path
  end

  test "scopes to the current team — cannot revoke another team's device" do
    other_owner = User.create!(email: "ot-#{SecureRandom.hex(4)}@example.com", password: "password123")
    foreign = other_owner.personal_team.devices.create!(user: other_owner, name: "theirs")
    assert_no_difference -> { Device.count } do
      delete bridge_path(foreign)
    end
    assert_response :not_found
  end
end
