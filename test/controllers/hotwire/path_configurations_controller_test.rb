require "test_helper"

class Hotwire::PathConfigurationsControllerTest < ActionDispatch::IntegrationTest
  test "serves the ios rules unauthenticated" do
    get hotwire_ios_path_configuration_path(format: :json)

    assert_response :success
    config = JSON.parse(response.body)
    assert_equal [ ".*" ], config["rules"].first["patterns"]
    modal = config["rules"].find { |r| r["patterns"] == [ "/new$", "/edit$" ] }
    assert_equal "modal", modal["properties"]["context"]
  end
end
