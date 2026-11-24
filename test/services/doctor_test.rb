require "test_helper"

class DoctorTest < ActiveSupport::TestCase
  def doctor(env = {}, delivery_method: :test, pi_version: PiAgent::SUPPORTED_PI_VERSION,
             docker_image: ->(_name) { nil })
    Doctor.new(env: env, delivery_method: delivery_method, pi_version: -> { pi_version },
      docker_image: docker_image)
  end

  # What docker:image stamps on the image it builds, as the doctor reads it
  # back: the label, plus the arch of the daemon it is sitting on.
  def image_metadata(built_for: "arm64", daemon_arch: "arm64", pi_version: PiAgent::SUPPORTED_PI_VERSION)
    { present: true, daemon_arch: daemon_arch,
      fingerprint: PiImageFingerprint.call(pi_version: pi_version, arch: built_for, root: Rails.root) }
  end

  def check(doctor, section, name)
    doctor.sections.fetch(section).find { |c| c.name == name }
  end

  test "report renders every section and a summary" do
    report = doctor.report
    %w[Core Email Agent Storage Access Connectors Observability].each do |section|
      assert_includes report, section
    end
    assert_match(/problems?|warnings?|All good\./, report)
  end

  test "providers pass with a key, warn on bare local, fail on bare sandbox runtime" do
    with_key = doctor({ "ANTHROPIC_API_KEY" => "sk-x" })
    assert_equal :ok, check(with_key, "Agent", "providers").status
    assert_includes check(with_key, "Agent", "providers").detail, "anthropic"
    assert_equal :warn, check(doctor, "Agent", "providers").status
    assert_equal :fail, check(doctor({ "METIS_AGENT_RUNTIME" => "docker" }), "Agent", "providers").status
  end

  test "e2b runtime requires its API key" do
    env = { "METIS_AGENT_RUNTIME" => "e2b" }
    assert_equal :fail, check(doctor(env), "Agent", "runtime").status
    assert_equal :ok, check(doctor(env.merge("E2B_API_KEY" => "k")), "Agent", "runtime").status
  end

  test "pi fails when the local runtime has no binary, warns when it drifts from the pin" do
    absent = doctor(pi_version: nil)
    assert_equal :fail, check(absent, "Agent", "pi").status
    assert_includes check(absent, "Agent", "pi").detail, PiAgent::SUPPORTED_PI_VERSION

    assert_equal :warn, check(doctor(pi_version: "0.1.0"), "Agent", "pi").status
    assert_equal :ok, check(doctor, "Agent", "pi").status
  end

  test "pi passes on docker only when the image on the daemon matches the current tree" do
    env = { "METIS_AGENT_RUNTIME" => "docker" }

    current = check(doctor(env, docker_image: ->(_) { image_metadata }), "Agent", "pi")
    assert_equal :ok, current.status
    assert_includes current.detail, PiAgent::SUPPORTED_PI_VERSION
    assert_includes current.detail, Agent::Runtime::Docker.image_ref
  end

  test "pi warns when the docker image was built from an older pin — the drift a gem bump leaves" do
    env = { "METIS_AGENT_RUNTIME" => "docker" }
    stale = ->(_) { image_metadata(pi_version: "0.83.0") }

    drifted = check(doctor(env, docker_image: stale), "Agent", "pi")
    assert_equal :warn, drifted.status
    assert_includes drifted.detail, "runtime:image"

    # A cross-arch image is the same defect: built, labelled, and wrong.
    cross = check(doctor(env, docker_image: ->(_) { image_metadata(built_for: "amd64") }), "Agent", "pi")
    assert_equal :warn, cross.status

    unlabelled = ->(_) { { present: true, daemon_arch: "arm64", fingerprint: "" } }
    assert_includes check(doctor(env, docker_image: unlabelled), "Agent", "pi").detail, "unlabelled"
  end

  test "pi fails when the docker daemon has no such image, and is unverified without a daemon" do
    env = { "METIS_AGENT_RUNTIME" => "docker" }

    missing = check(doctor(env, docker_image: ->(_) { { present: false, daemon_arch: "arm64" } }), "Agent", "pi")
    assert_equal :fail, missing.status
    assert_includes missing.detail, "runtime:image"

    # nil is "no daemon here to ask" — unverifiable is not a failure.
    assert_equal :off, check(doctor(env, docker_image: ->(_) { nil }), "Agent", "pi").status
  end

  test "pi on a hosted runtime reports the pin as unverified, never as baked in" do
    { "e2b" => "template", "daytona" => "snapshot", "microsandbox" => "image" }.each do |kind, noun|
      pi = check(doctor({ "METIS_AGENT_RUNTIME" => kind }), "Agent", "pi")

      assert_equal :off, pi.status, "#{kind} cannot read its artifact, so it must not report :ok"
      assert_includes pi.detail, PiAgent::SUPPORTED_PI_VERSION
      assert_includes pi.detail, noun
      assert_includes pi.detail, "unverifiable"
      assert_includes pi.detail, "runtime:image"
    end
  end

  test "unknown runtime fails" do
    assert_equal :fail, check(doctor({ "METIS_AGENT_RUNTIME" => "podman" }), "Agent", "runtime").status
  end

  test "microsandbox runtime passes when the gem loads, fails when absent" do
    env = { "METIS_AGENT_RUNTIME" => "microsandbox" }

    with_stub(Agent::Runtime::Microsandbox, :load_gem, -> { }) do
      ok = check(doctor(env), "Agent", "runtime")
      assert_equal :ok, ok.status
      assert_includes ok.detail, "metis-pi"
    end

    with_stub(Agent::Runtime::Microsandbox, :load_gem, -> { raise LoadError, "no gem" }) do
      failing = check(doctor(env), "Agent", "runtime")
      assert_equal :fail, failing.status
      assert_includes failing.detail, "bundle install"
    end

    # load_gem's own translation of that LoadError.
    with_stub(Agent::Runtime::Microsandbox, :load_gem, -> { raise Agent::Error, "not installed" }) do
      assert_equal :fail, check(doctor(env), "Agent", "runtime").status
    end
  end

  test "an unrelated microsandbox failure is not mislabelled as a missing gem" do
    env = { "METIS_AGENT_RUNTIME" => "microsandbox" }

    with_stub(Agent::Runtime::Microsandbox, :load_gem, -> { raise "native ext segfaulted" }) do
      assert_raises(RuntimeError) { check(doctor(env), "Agent", "runtime") }
    end
  end

  test "the microsandbox workspace quota shows in the runtime detail when set" do
    env = { "METIS_AGENT_RUNTIME" => "microsandbox" }
    config = Rails.configuration.x.agent
    original = config.microsandbox_workspace_quota_mib

    with_stub(Agent::Runtime::Microsandbox, :load_gem, -> { }) do
      config.microsandbox_workspace_quota_mib = 16_384
      assert_includes check(doctor(env), "Agent", "runtime").detail, "16384 MiB"

      config.microsandbox_workspace_quota_mib = nil
      refute_includes check(doctor(env), "Agent", "runtime").detail, "quota"
    end
  ensure
    config.microsandbox_workspace_quota_mib = original
  end

  test "cloudflare transport reports missing credentials" do
    failing = check(doctor(delivery_method: :cloudflare), "Email", "transport")
    assert_equal :fail, failing.status
    assert_includes failing.detail, "CLOUDFLARE_ACCOUNT_ID"

    env = { "CLOUDFLARE_ACCOUNT_ID" => "a", "CLOUDFLARE_EMAIL_API_TOKEN" => "t" }
    assert_equal :ok, check(doctor(env, delivery_method: :cloudflare), "Email", "transport").status
  end

  test "partial oauth pair fails, absent pair is off" do
    assert_equal :off, check(doctor, "Connectors", "google oauth").status
    partial = check(doctor({ "GOOGLE_OAUTH_CLIENT_ID" => "id" }), "Connectors", "google oauth")
    assert_equal :fail, partial.status
    assert_includes partial.detail, "GOOGLE_OAUTH_CLIENT_SECRET"
  end

  test "x oauth is off when absent, names missing keys when partial, ok when complete" do
    assert_equal :off, check(doctor, "Connectors", "x oauth").status

    partial = check(doctor({ "X_CLIENT_ID" => "id" }), "Connectors", "x oauth")
    assert_equal :fail, partial.status
    assert_includes partial.detail, "X_CLIENT_SECRET"
    assert_includes partial.detail, "X_REDIRECT_URI"
    assert_not_includes partial.detail, "id"

    env = { "X_CLIENT_ID" => "id", "X_CLIENT_SECRET" => "s", "X_REDIRECT_URI" => "https://m/cb" }
    assert_equal :ok, check(doctor(env), "Connectors", "x oauth").status
  end

  test "langfuse enabled without keys fails" do
    assert_equal :off, check(doctor, "Observability", "langfuse").status
    assert_equal :fail, check(doctor({ "METIS_LANGFUSE_ENABLED" => "1" }), "Observability", "langfuse").status
    env = { "METIS_LANGFUSE_ENABLED" => "1", "LANGFUSE_PUBLIC_KEY" => "p", "LANGFUSE_SECRET_KEY" => "s" }
    assert_equal :ok, check(doctor(env), "Observability", "langfuse").status
  end

  test "ok? is false when any check fails" do
    assert_not doctor({ "METIS_AGENT_RUNTIME" => "e2b" }).ok?
    assert doctor({
      "ANTHROPIC_API_KEY" => "sk-x", "CLOUDFLARE_ACCOUNT_ID" => "a", "CLOUDFLARE_EMAIL_API_TOKEN" => "t"
    }).ok?
  end

  test "encryption check fails without crashing when keys are missing" do
    # config.primary_key raises when unset; the doctor must report :fail,
    # not abort with a stack trace, in the keyless env it diagnoses. Test
    # env hardcodes the keys, so override the predicate for one assertion.
    config = ActiveRecord::Encryption.config
    config.define_singleton_method(:has_primary_key?) { false }
    begin
      assert_equal :fail, check(doctor, "Core", "encryption").status
    ensure
      config.singleton_class.send(:remove_method, :has_primary_key?)
    end
  end

  test "report never includes secret values" do
    env = { "ANTHROPIC_API_KEY" => "sk-secret-123", "LANGFUSE_SECRET_KEY" => "lf-secret" }
    assert_not_includes doctor(env).report, "sk-secret-123"
    assert_not_includes doctor(env).report, "lf-secret"
  end
end
