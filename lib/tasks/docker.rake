require_relative "support/pi_image_fingerprint"

namespace :docker do
  def self.pi_image_fingerprint(arch:)
    PiImageFingerprint.call(
      pi_version: PiAgent::SUPPORTED_PI_VERSION, arch: arch, root: Rails.root
    )
  end

  # Go-style arch ("arm64", "amd64") of the daemon a build would land on —
  # the local one, or the remote when docker_host is set. Matches the value
  # `docker image inspect --format {{.Architecture}}` reports.
  def self.daemon_arch(docker_host: nil)
    env = docker_host ? { "DOCKER_HOST" => docker_host } : {}
    arch = IO.popen(env, [ "docker", "version", "--format", "{{.Server.Arch}}" ], err: File::NULL, &:read).to_s.strip
    abort "[docker] could not reach the docker daemon#{" at #{docker_host}" if docker_host}" if arch.empty?
    arch
  end

  def self.build_pi_image(name, fingerprint:, docker_host: nil)
    # Context is the repo root (not docker/pi-runtime) so the Dockerfile can
    # COPY .pi/extensions into the image; .dockerignore keeps storage/ etc. out.
    # With docker_host set the CLI ships that context to the remote daemon and
    # builds there, natively — no emulation, and no image to upload afterwards.
    env = docker_host ? { "DOCKER_HOST" => docker_host } : {}
    ok = system(
      env,
      "docker", "build",
      "--build-arg", "PI_VERSION=#{PiAgent::SUPPORTED_PI_VERSION}",
      "--label", "metis.fingerprint=#{fingerprint}",
      "--file", "docker/pi-runtime/Dockerfile",
      "--tag", name,
      Rails.root.to_s
    )
    abort "docker build failed" unless ok
  end

  def self.remote_pi_fingerprint(name, docker_host:)
    IO.popen(
      { "DOCKER_HOST" => docker_host },
      [ "docker", "image", "inspect", name, "--format", '{{index .Config.Labels "metis.fingerprint"}}' ],
      err: File::NULL, &:read
    ).to_s.strip
  end

  desc "Build the pi runtime image for Agent::Runtime::Docker. Usage: rake docker:image[name]"
  task :image, [ :name ] => :environment do |_task, args|
    name = args.fetch(:name, "metis-pi")
    arch = daemon_arch
    puts "Building Docker image '#{name}' with pi #{PiAgent::SUPPORTED_PI_VERSION} for #{arch}..."
    build_pi_image(name, fingerprint: pi_image_fingerprint(arch: arch))

    puts
    puts "Built Docker image '#{name}'."
    puts "Point Metis at it:  export METIS_DOCKER_IMAGE=#{name}"
    puts "                    export METIS_AGENT_RUNTIME=docker"
  end

  desc "Build metis-pi on the host iff its fingerprint changed. Usage: rake docker:sync_pi_image[host,name]"
  # No :environment prerequisite on purpose — this runs from the kamal
  # pre-deploy hook, where booting Rails would decrypt credentials with the
  # deploy shell's RAILS_MASTER_KEY and fail. We only need PiAgent (loaded by
  # Bundler.require) and Rails.root (set when config/application loads), neither
  # of which needs initializers to run.
  #
  # The build runs on the host's own daemon over DOCKER_HOST=ssh://. The
  # deployer's arch is not the host's — a linux/amd64 workstation deploying to
  # an arm64 server — and a cross-arch metis-pi is a silent failure (see
  # pi_image_fingerprint). Building where the image will run makes the arch
  # right by construction, and drops the save|gzip|ssh|load upload entirely.
  task :sync_pi_image, [ :host, :name ] do |_task, args|
    require "dotenv"
    Dotenv.load(".env.deploy") if File.exist?(".env.deploy")

    host = args[:host].presence || ENV["KAMAL_JOB_IP"].presence
    abort "[sync_pi_image] no host: pass rake \"docker:sync_pi_image[HOST]\" or set KAMAL_JOB_IP" unless host
    ssh_user = ENV["KAMAL_SSH_USER"].presence || "ubuntu"
    name = args[:name].presence || ENV["METIS_DOCKER_IMAGE"].presence || "metis-pi"
    docker_host = "ssh://#{ssh_user}@#{host}"

    arch = daemon_arch(docker_host: docker_host)
    fingerprint = pi_image_fingerprint(arch: arch)

    remote = remote_pi_fingerprint(name, docker_host: docker_host)
    if remote == fingerprint
      puts "[sync_pi_image] #{name} up to date on #{host} (#{arch}, #{fingerprint[0, 12]}) — skipping."
      next
    end

    puts "[sync_pi_image] drift on #{host} (have #{remote.presence&.first(12) || 'none'}, want #{fingerprint[0, 12]}) — building on #{host} for #{arch}…"
    build_pi_image(name, fingerprint: fingerprint, docker_host: docker_host)
    puts "[sync_pi_image] synced #{name} on #{host} (#{arch}, #{fingerprint[0, 12]})."
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
