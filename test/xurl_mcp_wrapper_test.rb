require "test_helper"
require "open3"
require "tmpdir"
require "timeout"

# Behavioral contract of docker/pi-runtime/xurl-mcp — the X connector's
# stdio bridge wrapper. A fake `xurl` on PATH stands in for the real
# binary so the tests observe exactly what the wrapper hands it: an
# isolated 0700 $HOME, a 0600 .xurl in xurl's multi-app YAML shape, a
# clean stdout, and no secrets in argv. See docs/connectors.md.
class XurlMcpWrapperTest < ActiveSupport::TestCase
  WRAPPER = Rails.root.join("docker/pi-runtime/xurl-mcp").to_s

  ENV_VARS = {
    "XURL_CLIENT_ID" => "cid", "XURL_CLIENT_SECRET" => "csec",
    "XURL_REDIRECT_URI" => "https://m/cb", "XURL_ACCESS_TOKEN" => "xat",
    "XURL_REFRESH_TOKEN" => "xrt", "XURL_EXPIRATION_TIME" => "1783946096"
  }.freeze

  INSPECT_XURL = <<~SH.freeze
    #!/bin/bash
    stat_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
    echo "ARGS:$*"
    echo "HOMEDIR:$HOME"
    echo "HOME_MODE:$(stat_mode "$HOME")"
    echo "FILE_MODE:$(stat_mode "$HOME/.xurl")"
    cat "$HOME/.xurl"
    cat
  SH

  def run_wrapper(env: {}, stdin: "", fake_xurl: INSPECT_XURL)
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "xurl")
      File.write(fake, fake_xurl)
      File.chmod(0o755, fake)
      full_env = ENV_VARS.merge("PATH" => "#{dir}:#{ENV["PATH"]}").merge(env)
      Open3.capture3(full_env, WRAPPER, stdin_data: stdin)
    end
  end

  test "hands xurl an isolated 0700 home with a 0600 .xurl in the multi-app shape" do
    out, _err, status = run_wrapper

    assert status.success?
    assert_includes out, "HOME_MODE:700"
    assert_includes out, "FILE_MODE:600"
    assert_includes out, "ARGS:mcp https://api.x.com/mcp"
    assert_includes out, 'client_id: "cid"'
    assert_includes out, 'default_user: "metis-user"'
    assert_includes out, 'access_token: "xat"'
    assert_includes out, 'refresh_token: "xrt"'
    assert_includes out, "expiration_time: 1783946096"
    assert_includes out, "default_app: metis"
  end

  test "relays stdin to xurl and removes the temp home on exit" do
    out, _err, status = run_wrapper(stdin: %({"jsonrpc":"2.0","id":1}\n))

    assert status.success?
    assert_includes out, %({"jsonrpc":"2.0","id":1})
    home = out[/^HOMEDIR:(.+)$/, 1]
    assert home.present?
    assert_not File.exist?(home), "temp xurl home must not outlive the process"
  end

  test "two runs get distinct temp homes" do
    first, = run_wrapper
    second, = run_wrapper

    assert_not_equal first[/^HOMEDIR:(.+)$/, 1], second[/^HOMEDIR:(.+)$/, 1]
  end

  test "a missing required variable fails on stderr without leaking secrets" do
    out, err, status = run_wrapper(env: { "XURL_ACCESS_TOKEN" => "" })

    assert_not status.success?
    assert_empty out
    assert_includes err, "XURL_ACCESS_TOKEN"
    assert_not_includes err, "csec"
  end

  test "a non-numeric expiration is rejected" do
    _out, err, status = run_wrapper(env: { "XURL_EXPIRATION_TIME" => "soon" })

    assert_not status.success?
    assert_includes err, "XURL_EXPIRATION_TIME"
  end

  test "removes the temp home when terminated mid-run" do
    sleepy = <<~SH
      #!/bin/bash
      echo "HOMEDIR:$HOME"
      trap 'exit 0' TERM
      sleep 30 & wait $!
    SH

    Dir.mktmpdir do |dir|
      fake = File.join(dir, "xurl")
      File.write(fake, sleepy)
      File.chmod(0o755, fake)
      env = ENV_VARS.merge("PATH" => "#{dir}:#{ENV["PATH"]}")

      Open3.popen2e(env, WRAPPER) do |stdin, out, wait|
        home = Timeout.timeout(10) { out.gets[/HOMEDIR:(.+)/, 1] }
        Process.kill("TERM", wait.pid)
        Timeout.timeout(10) { wait.value }
        stdin.close
        assert_not File.exist?(home), "temp xurl home must be removed on SIGTERM"
      end
    end
  end
end
