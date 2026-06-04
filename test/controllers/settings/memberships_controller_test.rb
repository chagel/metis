require "test_helper"

class Settings::MembershipsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @owner = User.create!(email: "owner@example.com", password: "password123")
    @team = Team.create!(name: "Acme")
    @owner.memberships.create!(team: @team, role: :owner)
    @member = User.create!(email: "member@example.com", password: "password123")
    @member_ship = @team.memberships.create!(user: @member, role: :member)
  end

  def act_as(user, team)
    sign_in user
    post switch_team_path(team), headers: { "HTTP_REFERER" => root_path }
  end

  test "an admin can promote a member to admin" do
    act_as(@owner, @team)
    patch team_membership_path(@member_ship), params: { membership: { role: "admin" } }
    assert_redirected_to team_path
    assert @member_ship.reload.admin?
  end

  test "the owner role cannot be reassigned through update" do
    owner_ship = @team.memberships.find_by(user: @owner)
    act_as(@owner, @team)
    patch team_membership_path(owner_ship), params: { membership: { role: "member" } }
    assert_redirected_to team_path
    assert owner_ship.reload.owner?
  end

  test "an owner role cannot be granted through update" do
    act_as(@owner, @team)
    patch team_membership_path(@member_ship), params: { membership: { role: "owner" } }
    assert_redirected_to team_path
    assert @member_ship.reload.member?
  end

  test "a plain member cannot manage memberships" do
    act_as(@member, @team)
    patch team_membership_path(@member_ship), params: { membership: { role: "admin" } }
    assert_redirected_to team_path
    assert @member_ship.reload.member?
  end

  test "an admin can remove a member" do
    act_as(@owner, @team)
    assert_difference -> { @team.memberships.count }, -1 do
      delete team_membership_path(@member_ship)
    end
  end

  test "the owner cannot be removed" do
    owner_ship = @team.memberships.find_by(user: @owner)
    act_as(@owner, @team)
    assert_no_difference -> { @team.memberships.count } do
      delete team_membership_path(owner_ship)
    end
  end

  test "you cannot remove yourself with destroy" do
    @team.memberships.find_by(user: @owner)
    admin = User.create!(email: "admin@example.com", password: "password123")
    admin_ship = @team.memberships.create!(user: admin, role: :admin)
    act_as(admin, @team)
    assert_no_difference -> { @team.memberships.count } do
      delete team_membership_path(admin_ship)
    end
    assert_redirected_to team_path
  end

  test "the owner can transfer ownership and steps down to admin" do
    act_as(@owner, @team)
    post transfer_team_membership_path(@member_ship)
    assert_redirected_to team_path
    assert @member_ship.reload.owner?
    assert @team.memberships.find_by(user: @owner).admin?
  end

  test "a non-owner cannot transfer ownership" do
    admin = User.create!(email: "admin@example.com", password: "password123")
    @team.memberships.create!(user: admin, role: :admin)
    act_as(admin, @team)
    post transfer_team_membership_path(@member_ship)
    assert_redirected_to team_path
    assert @member_ship.reload.member?
  end

  test "a member can leave the team and drops back to their personal workspace" do
    act_as(@member, @team)
    assert_difference -> { @team.memberships.count }, -1 do
      delete leave_team_memberships_path
    end
    assert_redirected_to team_path
    follow_redirect!
    assert_select "a[href=?]", new_team_path # back in the personal workspace
  end

  test "the owner cannot leave without transferring or deleting" do
    act_as(@owner, @team)
    assert_no_difference -> { @team.memberships.count } do
      delete leave_team_memberships_path
    end
    assert_redirected_to team_path
  end
end
