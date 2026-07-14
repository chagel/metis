require "test_helper"

# The xurl binary is pinned per runtime path as a literal (the Metis-owned
# OAuth material is injected into a generated ~/.xurl, so an unvalidated
# xurl bump can silently break the X connector — see docs/connectors.md).
# This guards the five copies against drifting apart.
class XurlPinTest < ActiveSupport::TestCase
  PIN = "1.2.2".freeze

  PATHS = {
    "docker/pi-runtime/Dockerfile" => /^ARG XURL_VERSION=(\S+)/,
    "Dockerfile.dev" => /^ARG XURL_VERSION=(\S+)/,
    "lib/tasks/e2b.rake" => %r{xurl/releases/download/v([\d.]+)/},
    "lib/tasks/daytona.rake" => %r{xurl/releases/download/v([\d.]+)/},
    "bin/setup" => %r{xurl/releases/download/v([\d.]+)/}
  }.freeze

  test "every runtime path pins the same xurl version" do
    PATHS.each do |file, pattern|
      pinned = Rails.root.join(file).read[pattern, 1]
      assert_equal PIN, pinned, "#{file} pins xurl #{pinned.inspect} — keep all paths at #{PIN}."
    end
  end
end
