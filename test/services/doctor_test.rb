require "test_helper"

class DoctorTest < ActiveSupport::TestCase
  def doctor(env = {}, delivery_method: :test)
    Doctor.new(env: env, delivery_method: delivery_method)
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

  test "unknown runtime fails" do
    assert_equal :fail, check(doctor({ "METIS_AGENT_RUNTIME" => "podman" }), "Agent", "runtime").status
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
