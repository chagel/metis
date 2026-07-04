require "test_helper"

class DeviseOauthButtonsTest < ActionDispatch::IntegrationTest
  test "sign-in hides OAuth buttons when providers are not configured" do
    with_stub(GithubApp::Config, :configured?, -> { false }) do
      with_stub(GoogleApp::Config, :configured?, -> { false }) do
        get new_user_session_path
        assert_response :success

        assert_select "button", text: /Sign in with GitHub/, count: 0
        assert_select "button", text: /Sign in with Google/, count: 0
        assert_select ".auth-or", count: 0
      end
    end
  end

  test "registration hides OAuth buttons when providers are not configured" do
    with_stub(GithubApp::Config, :configured?, -> { false }) do
      with_stub(GoogleApp::Config, :configured?, -> { false }) do
        get new_user_registration_path
        assert_response :success

        assert_select "button", text: /Sign up with GitHub/, count: 0
        assert_select "button", text: /Sign up with Google/, count: 0
        assert_select ".auth-or", count: 0
      end
    end
  end

  test "sign-in renders only configured OAuth providers" do
    with_stub(GithubApp::Config, :configured?, -> { false }) do
      with_stub(GoogleApp::Config, :configured?, -> { true }) do
        get new_user_session_path
        assert_response :success

        assert_select "button", text: /Sign in with GitHub/, count: 0
        assert_select "button", text: /Sign in with Google/, count: 1
      end
    end
  end

  test "native sign-in swaps Google for the marker link and forces remember me" do
    with_stub(GoogleApp::Config, :configured?, -> { true }) do
      get new_user_session_path, headers: { "User-Agent" => "Hotwire Native iOS" }
      assert_response :success

      assert_select "a.auth-oauth[href='/users/auth/google/native_start']", count: 1
      assert_select "input[type=hidden][name='user[remember_me]'][value='1']", count: 1
      assert_select ".auth-check", count: 0
    end
  end
end
