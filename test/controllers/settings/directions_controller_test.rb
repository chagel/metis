require "test_helper"

class Settings::DirectionsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "dc-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @team = @user.personal_team
    sign_in @user
  end

  test "create adds a direction and the foresight routine" do
    post directions_path, params: { direction: { title: "Proactive agents", brief: "New research" } }

    assert_redirected_to directions_path
    assert_equal [ "Proactive agents" ], Direction.for(@user, @team).pluck(:title)
    assert Foresight.routine_for(@user, @team)
  end

  test "index shows each direction with its outcomes" do
    direction = Direction.create!(user: @user, team: @team, title: "Payments")
    Hunch.create!(user: @user, team: @team, direction: direction, title: "T", body: "B", status: :used)
    get directions_path

    assert_response :success
    assert_select ".direction-row .conn-name", text: /Payments/
    assert_select ".direction-row .routine-meta", text: /1 used · 0 dismissed · 1 hunches/
  end

  test "toggle pauses and resumes" do
    direction = Direction.create!(user: @user, team: @team, title: "Payments")
    patch toggle_direction_path(direction)
    assert direction.reload.paused?
  end

  test "a blank title re-renders with an error" do
    post directions_path, params: { direction: { title: " " } }
    assert_response :unprocessable_content
  end
end
