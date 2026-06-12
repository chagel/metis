ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Tests never reach GitHub — every omniauth callback uses a mock_auth
# set up by the test (or returns OmniAuth's default invalid_credentials).
OmniAuth.config.test_mode = true

module ActiveSupport
  class TestCase
    # Single-process until the suite is large enough to benefit. Parallel
    # workers share the filesystem but not DB id sequences, which races
    # tests that touch per-record scratch paths (Agent::Workspace).
    # Keep the threshold well above the current suite size to defer that
    # work — bump again when we're ready to fix the races.
    parallelize(workers: :number_of_processors, threshold: 5000)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Replace a singleton method on `target` (typically a class) with `replacement`
    # for the duration of the block, then restore. Minitest 6 dropped Object#stub,
    # so tests that fake out an external boundary use this instead.
    def with_stub(target, method_name, replacement)
      original = target.method(method_name)
      target.singleton_class.send(:define_method, method_name, replacement)
      yield
    ensure
      target.singleton_class.send(:define_method, method_name, original)
    end

    # Run a block with the deployment registration gate set to `mode`
    # (:invite_only / :open). Test defaults to :open, so gate tests flip it.
    def with_registration_mode(mode)
      previous = Rails.application.config.x.registration_mode
      Rails.application.config.x.registration_mode = mode
      yield
    ensure
      Rails.application.config.x.registration_mode = previous
    end

    # SQL statements issued by the block, schema/transaction bookkeeping
    # excluded. For N+1 regression tests: cache hits count by default —
    # the query cache can span requests here, and a cached N+1 is still
    # one statement per row.
    def count_queries(include_cached: true, &block)
      count = 0
      counter = lambda do |_name, _start, _finish, _id, payload|
        next if %w[SCHEMA TRANSACTION].include?(payload[:name])
        count += 1 if include_cached || !payload[:cached]
      end
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end

    # Run a block with the invite-only domain allowlist set (default empty).
    # Domains are stored downcased, as the initializer does at boot.
    def with_allowed_domains(*domains)
      previous = Rails.application.config.x.allowed_domains
      Rails.application.config.x.allowed_domains = domains.map(&:downcase).freeze
      yield
    ensure
      Rails.application.config.x.allowed_domains = previous
    end

    # The bridge tests' standard fixture: a one-step delegated workflow
    # run, dispatched and parked on awaiting_local. Expects the test's
    # setup to have created @user / @team.
    LOCAL_STEP = { "name" => "impl", "prompt" => "implement", "run" => "local" }.freeze

    def dispatch_run(steps = [ LOCAL_STEP ])
      run = WorkflowRun.start(team: @team, user: @user, steps: steps)
      WorkflowAdvanceJob.perform_now(run.id)
      run.reload
    end

    # Idempotently create one enabled catalog model and return its key —
    # for tests needing a valid preferred_model now that the catalog is
    # DB-backed (Agent::Catalog has no hardcoded fallback).
    def seed_catalog_model(provider: "anthropic", key: "claude-opus-4-8")
      record = LlmProvider.find_or_create_by!(key: provider) { |p| p.label = provider.titleize }
      record.llm_models.find_or_create_by!(key: key) { |m| m.label = key }
      key
    end
  end
end
