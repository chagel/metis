# Daytona snapshots are immutable and unique by name, and the API has no
# replace — so a pi bump can only reuse the configured name by deleting
# first. Extracted from daytona.rake because that delete is destructive and
# has to tell "the snapshot is absent" apart from "the API did not answer":
# treating an auth failure or an outage as absence skips the delete and
# creates into a name that is still taken.
#
# Lives under lib/tasks (outside autoload_lib) alongside PiImageFingerprint —
# it is build tooling, not app code.
module DaytonaSnapshot
  # Deletion is asynchronous: the name stays taken for a few seconds after
  # the call returns, and creating into it fails with "already exists".
  DELETE_ATTEMPTS = 30
  DELETE_INTERVAL = 2

  class DeletionTimeout < StandardError; end

  module_function

  def replace(client, name, out: $stdout, sleeper: method(:sleep))
    existing = find(client, name)
    return out.puts "No existing snapshot '#{name}' to replace." if existing.nil?

    id = existing["id"] || existing[:id]
    state = existing["state"] || existing[:state]
    out.puts "Deleting snapshot '#{name}' (id: #{id}, state: #{state})..."
    client.snapshot.delete(id)
    wait_for_deletion(client, name, out: out, sleeper: sleeper)
  end

  # Only a 404 means absent. Every other Daytona error — auth, rate limit,
  # timeout, 5xx — propagates, so the caller aborts instead of continuing
  # into create with a stale snapshot still holding the name.
  def find(client, name)
    client.snapshot.get(name)
  rescue ::Daytona::NotFoundError
    nil
  end

  def wait_for_deletion(client, name, attempts: DELETE_ATTEMPTS, interval: DELETE_INTERVAL,
                        out: $stdout, sleeper: method(:sleep))
    attempts.times do
      return out.puts "Deleted." if find(client, name).nil?
      sleeper.call(interval)
    end
    raise DeletionTimeout, "snapshot '#{name}' still exists #{attempts * interval}s after delete"
  end
end
