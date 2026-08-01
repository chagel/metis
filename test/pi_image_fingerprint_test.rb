require "test_helper"
require Rails.root.join("lib/tasks/support/pi_image_fingerprint")

# metis-pi is built for whichever daemon the build lands on, and a cross-arch
# image fails only at turn time (pi exits `exec format error`, the turn reports
# Agent::Adapters::BootTimeout). The arch therefore has to be part of what
# docker:sync_pi_image compares against the host's label, or an image built on
# an amd64 deployer reads as "up to date" on an arm64 host forever.
class PiImageFingerprintTest < ActiveSupport::TestCase
  def fingerprint(arch: "arm64", pi_version: "1.2.3", root: Rails.root)
    PiImageFingerprint.call(pi_version: pi_version, arch: arch, root: root)
  end

  test "differs by target arch" do
    assert_not_equal fingerprint(arch: "arm64"), fingerprint(arch: "amd64")
  end

  test "differs by pi version" do
    assert_not_equal fingerprint(pi_version: "1.2.3"), fingerprint(pi_version: "1.2.4")
  end

  test "is stable for the same inputs" do
    assert_equal fingerprint, fingerprint
  end

  test "covers the Dockerfile and the extensions tree" do
    Dir.mktmpdir do |dir|
      root = Pathname.new(dir)
      root.join("docker/pi-runtime").mkpath
      root.join(".pi/extensions/adapter").mkpath
      root.join("docker/pi-runtime/Dockerfile").write("FROM debian\n")
      extension = root.join(".pi/extensions/adapter/index.js")
      extension.write("one\n")

      before = fingerprint(root: root)
      extension.write("two\n")
      assert_not_equal before, fingerprint(root: root), "extension edits must change the fingerprint"

      extension.write("one\n")
      root.join("docker/pi-runtime/Dockerfile").write("FROM ubuntu\n")
      assert_not_equal before, fingerprint(root: root), "Dockerfile edits must change the fingerprint"
    end
  end
end
