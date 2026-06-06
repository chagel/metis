namespace :docker do
  # Content fingerprint of everything baked into metis-pi: the pinned pi
  # version, the Dockerfile (which carries the pinned pi-mcp-adapter / gws /
  # toolchain), and the .pi/extensions tree. Stamped as a label so a host can
  # be asked "do you already have this exact image?" — drives docker:sync_pi_image
  # and the kamal pre-deploy hook. Bump any input → new fingerprint → rebuild.
  def self.pi_image_fingerprint
    require "digest"
    root = Rails.root
    parts = [ PiAgent::SUPPORTED_PI_VERSION, File.read(root.join("docker/pi-runtime/Dockerfile")) ]
    Dir.glob(root.join(".pi/extensions/**/*")).sort.each do |path|
      next unless File.file?(path)
      parts << path.delete_prefix(root.to_s) << File.read(path)
    end
    Digest::SHA256.hexdigest(parts.join("\x00"))
  end

  def self.build_pi_image(name, fingerprint: pi_image_fingerprint)
    # Context is the repo root (not docker/pi-runtime) so the Dockerfile can
    # COPY .pi/extensions into the image; .dockerignore keeps storage/ etc. out.
    ok = system(
      "docker", "build",
      "--build-arg", "PI_VERSION=#{PiAgent::SUPPORTED_PI_VERSION}",
      "--label", "metis.fingerprint=#{fingerprint}",
      "--file", "docker/pi-runtime/Dockerfile",
      "--tag", name,
      Rails.root.to_s
    )
    abort "docker build failed" unless ok
  end

  desc "Build the pi runtime image for Agent::Runtime::Docker. Usage: rake docker:image[name]"
  task :image, [ :name ] => :environment do |_task, args|
    name = args.fetch(:name, "metis-pi")
    puts "Building Docker image '#{name}' with pi #{PiAgent::SUPPORTED_PI_VERSION}..."
    build_pi_image(name)

    puts
    puts "Built Docker image '#{name}'."
    puts "Point Metis at it:  export METIS_DOCKER_IMAGE=#{name}"
    puts "                    export METIS_AGENT_RUNTIME=docker"
  end

  desc "Build + load metis-pi on the host iff its fingerprint changed. Usage: rake docker:sync_pi_image[host,name]"
  # No :environment prerequisite on purpose — this runs from the kamal
  # pre-deploy hook, where booting Rails would decrypt credentials with the
  # deploy shell's RAILS_MASTER_KEY and fail. We only need PiAgent (loaded by
  # Bundler.require) and Rails.root (set when config/application loads), neither
  # of which needs initializers to run.
  task :sync_pi_image, [ :host, :name ] do |_task, args|
    require "dotenv"
    Dotenv.load(".env.deploy") if File.exist?(".env.deploy")

    host = args[:host].presence || ENV["KAMAL_JOB_IP"].presence
    abort "[sync_pi_image] no host: pass rake \"docker:sync_pi_image[HOST]\" or set KAMAL_JOB_IP" unless host
    ssh_user = ENV["KAMAL_SSH_USER"].presence || "ubuntu"
    name = args[:name].presence || ENV["METIS_DOCKER_IMAGE"].presence || "metis-pi"
    target = "#{ssh_user}@#{host}"
    fingerprint = pi_image_fingerprint

    remote = `ssh -o BatchMode=yes #{target} "docker image inspect #{name} --format '{{index .Config.Labels \\"metis.fingerprint\\"}}' 2>/dev/null"`.strip
    if remote == fingerprint
      puts "[sync_pi_image] #{name} up to date on #{host} (#{fingerprint[0, 12]}) — skipping."
      next
    end

    puts "[sync_pi_image] drift on #{host} (have #{remote.presence&.first(12) || 'none'}, want #{fingerprint[0, 12]}) — rebuilding…"
    build_pi_image(name, fingerprint: fingerprint)

    puts "[sync_pi_image] uploading #{name} to #{host}…"
    loaded = system("bash", "-c",
      "set -o pipefail; docker save #{name} | gzip | ssh -o BatchMode=yes #{target} 'gunzip | docker load'")
    abort "[sync_pi_image] upload failed" unless loaded
    puts "[sync_pi_image] synced #{name} to #{host} (#{fingerprint[0, 12]})."
  end

  desc "Time a file-IO-heavy workload under runc vs runsc (gVisor). Usage: rake docker:bench_runtime[name]"
  task :bench_runtime, [ :name ] => :environment do |_task, args|
    name = args.fetch(:name, "metis-pi")
    # Small-file churn + git + ripgrep — the syscall/FS-bound shape a coding
    # turn actually exercises, where gVisor's gofer overhead shows up.
    workload = "set -e; cd /tmp; git init -q r; cd r; " \
               "for i in $(seq 1 3000); do echo x > f$i; done; " \
               "git add -A; git -c user.email=b@b -c user.name=b commit -qm x; rg -c x . >/dev/null"

    puts "Benchmarking '#{name}' (3000-file git+rg workload)…"
    [ nil, "runsc" ].each do |runtime|
      rt_args = runtime ? [ "--runtime", runtime ] : []
      label = runtime || "runc (default)"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ok = system("docker", "run", "--rm", *rt_args, name, "bash", "-lc", workload,
        out: File::NULL, err: File::NULL)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      puts ok ? format("  %-18s %.2fs", label, elapsed) : "  #{label}: FAILED (runtime registered?)"
    end
  end
end
