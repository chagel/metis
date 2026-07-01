require "test_helper"

# The runtime images read PiAgent::SUPPORTED_PI_VERSION dynamically (see
# lib/tasks/docker.rake, e2b.rake, daytona.rake), but Dockerfile.dev pins pi
# as a literal ARG default — compose.yaml builds it without a build-arg. This
# guards that literal against silently drifting behind the gem's pinned pi.
class DockerfileDevPiVersionTest < ActiveSupport::TestCase
  test "Dockerfile.dev pins the pi version pi-agent-rb supports" do
    pinned = Rails.root.join("Dockerfile.dev").read[/^ARG PI_VERSION=(\S+)/, 1]

    assert_equal PiAgent::SUPPORTED_PI_VERSION, pinned,
      "Dockerfile.dev ARG PI_VERSION (#{pinned}) drifted from " \
      "PiAgent::SUPPORTED_PI_VERSION (#{PiAgent::SUPPORTED_PI_VERSION}) — bump it in lockstep."
  end
end
