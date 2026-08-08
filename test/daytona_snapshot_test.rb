require "test_helper"
require Rails.root.join("lib/tasks/support/daytona_snapshot")

# The replace path deletes before it creates. Its one dangerous failure mode
# is reading an API failure as "no such snapshot": that skips the delete and
# creates into a name the old snapshot still holds.
class DaytonaSnapshotTest < ActiveSupport::TestCase
  # Answers get(name) from a scripted queue — a Hash or nil to return, an
  # exception class or instance to raise — and records deletes.
  class FakeSnapshots
    attr_reader :deleted, :gets

    def initialize(*script)
      @script = script.flatten(1)
      @deleted = []
      @gets = 0
    end

    def get(_name)
      @gets += 1
      answer = @script.length > 1 ? @script.shift : @script.first
      raise answer.new("boom") if answer.is_a?(Class)
      answer || raise(Daytona::NotFoundError.new("not found", status_code: 404))
    end

    def delete(id) = @deleted << id
  end

  class FakeClient
    attr_reader :snapshot
    def initialize(snapshot) = @snapshot = snapshot
  end

  def replace(snapshots, name: "metis-pi", sleeper: ->(_) { })
    out = StringIO.new
    DaytonaSnapshot.replace(FakeClient.new(snapshots), name, out: out, sleeper: sleeper)
    out.string
  end

  test "a missing snapshot is nothing to replace" do
    snapshots = FakeSnapshots.new(nil)

    assert_match(/No existing snapshot/, replace(snapshots))
    assert_empty snapshots.deleted
  end

  test "an existing snapshot is deleted by id" do
    snapshots = FakeSnapshots.new({ "id" => "snap-1", "state" => "active" }, nil)

    output = replace(snapshots)

    assert_equal [ "snap-1" ], snapshots.deleted
    assert_match(/Deleting snapshot 'metis-pi' \(id: snap-1, state: active\)/, output)
    assert_match(/Deleted\./, output)
  end

  test "an API failure propagates instead of reading as absence" do
    [ Daytona::AuthenticationError, Daytona::RateLimitError, Daytona::TimeoutError, Daytona::DaytonaError ].each do |error|
      snapshots = FakeSnapshots.new(error)

      assert_raises(error) { replace(snapshots) }
      assert_empty snapshots.deleted, "#{error} must not fall through to the delete/create path"
    end
  end

  test "an API failure while polling deletion propagates" do
    snapshots = FakeSnapshots.new({ "id" => "snap-1" }, Daytona::DaytonaError)

    assert_raises(Daytona::DaytonaError) { replace(snapshots) }
    assert_equal [ "snap-1" ], snapshots.deleted
  end

  test "deletion is polled until the name frees up" do
    snapshots = FakeSnapshots.new({ "id" => "snap-1" }, { "id" => "snap-1" }, { "id" => "snap-1" }, nil)
    slept = []

    output = replace(snapshots, sleeper: ->(interval) { slept << interval })

    assert_equal [ 2, 2 ], slept
    assert_match(/Deleted\./, output)
  end

  test "polling gives up rather than creating into a name that is still taken" do
    snapshots = FakeSnapshots.new({ "id" => "snap-1" })

    error = assert_raises(DaytonaSnapshot::DeletionTimeout) do
      DaytonaSnapshot.wait_for_deletion(FakeClient.new(snapshots), "metis-pi",
        attempts: 3, interval: 2, out: StringIO.new, sleeper: ->(_) { })
    end

    assert_match(/still exists 6s after delete/, error.message)
    assert_equal 3, snapshots.gets
  end
end
