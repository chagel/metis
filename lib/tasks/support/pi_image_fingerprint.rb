require "digest"

# Content fingerprint of everything baked into metis-pi: the pinned pi
# version, the target CPU arch, the Dockerfile (which carries the pinned
# pi-mcp-adapter / gws / toolchain), and the .pi/extensions tree. Stamped on
# the image as a label so a host can be asked "do you already have this exact
# image?" — drives docker:sync_pi_image and the kamal pre-deploy hook. Bump
# any input → new fingerprint → rebuild.
#
# Lives under lib/tasks (outside autoload_lib) because sync_pi_image runs
# without :environment — see the task for why.
module PiImageFingerprint
  module_function

  # arch is hashed because an image built for the wrong architecture is
  # otherwise indistinguishable from a correct one by content alone: it loads
  # onto the host, reports a matching fingerprint, and every pi container then
  # dies with `exec format error` — which a turn surfaces only as the
  # 30s Agent::Adapters::BootTimeout.
  def call(pi_version:, arch:, root:)
    root = Pathname.new(root.to_s)
    parts = [ pi_version, arch, File.read(root.join("docker/pi-runtime/Dockerfile")) ]
    Dir.glob(root.join(".pi/extensions/**/*")).sort.each do |path|
      next unless File.file?(path)
      parts << path.delete_prefix(root.to_s) << File.read(path)
    end
    Digest::SHA256.hexdigest(parts.join("\x00"))
  end
end
