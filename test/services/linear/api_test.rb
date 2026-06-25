require "test_helper"

class Linear::ApiTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :body)

  # Stub the HTTPS client so api.projects exercises real parsing without a
  # network call — the response object only needs #code and #body.
  def with_response(api, response, &block)
    transport = Object.new
    transport.define_singleton_method(:request) { |_req| response }
    with_stub(api, :https_client, ->(_uri) { transport }, &block)
  end

  test "projects returns id/name pairs sorted by name, case-insensitively" do
    api = Linear::Api.new("tok")
    body = { data: { projects: { nodes: [
      { id: "b", name: "Zeta" }, { id: "a", name: "alpha" }
    ] } } }.to_json

    result = nil
    with_response(api, Response.new("200", body)) { result = api.projects }

    assert_equal [ { "id" => "a", "name" => "alpha" }, { "id" => "b", "name" => "Zeta" } ], result
  end

  test "a non-200 response raises Error" do
    api = Linear::Api.new("tok")
    with_response(api, Response.new("401", "unauthorized")) do
      assert_raises(Linear::Api::Error) { api.projects }
    end
  end

  test "a graphql errors payload raises Error" do
    api = Linear::Api.new("tok")
    body = { errors: [ { message: "bad query" } ] }.to_json
    with_response(api, Response.new("200", body)) do
      assert_raises(Linear::Api::Error) { api.projects }
    end
  end
end
