require "test_helper"
require "tmpdir"

class Agent::SessionTreeTest < ActiveSupport::TestCase
  setup { @dir = Dir.mktmpdir }
  teardown { FileUtils.rm_rf(@dir) }

  ENTRIES = [
    { "type" => "session", "id" => "s0" },
    { "type" => "message", "id" => "u1", "parentId" => "s0", "message" => { "role" => "user", "content" => [ { "type" => "text", "text" => "q1" } ] } },
    { "type" => "message", "id" => "a1", "parentId" => "u1", "message" => { "role" => "assistant", "content" => [ { "type" => "text", "text" => "a1" } ] } },
    { "type" => "message", "id" => "u2", "parentId" => "a1", "message" => { "role" => "user", "content" => [ { "type" => "text", "text" => "q2" } ] } },
    { "type" => "message", "id" => "a2", "parentId" => "u2", "message" => { "role" => "assistant", "content" => [ { "type" => "text", "text" => "a2" } ] } }
  ].freeze

  def write_session(entries = ENTRIES)
    file = File.join(@dir, "2026-01-01T00-00-00-000Z_sess.jsonl")
    File.write(file, entries.map(&:to_json).join("\n") + "\n")
    file
  end

  def ids(file) = File.readlines(file).map { |line| JSON.parse(line)["id"] }

  test "truncating before user index 1 keeps only the first turn" do
    file = write_session
    assert Agent::SessionTree.truncate_before_user(session_dir: @dir, user_index: 1)
    assert_equal %w[s0 u1 a1], ids(file)
  end

  test "truncating before user index 0 keeps only the header" do
    file = write_session
    assert Agent::SessionTree.truncate_before_user(session_dir: @dir, user_index: 0)
    assert_equal %w[s0], ids(file)
  end

  test "an index past the last user entry keeps everything (a clone)" do
    file = write_session
    refute Agent::SessionTree.truncate_before_user(session_dir: @dir, user_index: 2)
    assert_equal %w[s0 u1 a1 u2 a2], ids(file)
  end

  test "a nil index keeps everything" do
    file = write_session
    refute Agent::SessionTree.truncate_before_user(session_dir: @dir, user_index: nil)
    assert_equal 5, ids(file).size
  end

  test "no session file is a safe no-op" do
    refute Agent::SessionTree.truncate_before_user(session_dir: @dir, user_index: 1)
  end

  test "an unparseable transcript bails without rewriting" do
    file = File.join(@dir, "2026-01-01T00-00-00-000Z_sess.jsonl")
    File.write(file, "not json\n")
    refute Agent::SessionTree.truncate_before_user(session_dir: @dir, user_index: 0)
    assert_equal "not json\n", File.read(file)
  end
end
