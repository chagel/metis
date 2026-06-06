namespace :docker do
  desc "Build the pi runtime image for Agent::Runtime::Docker. Usage: rake docker:image[name]"
  task :image, [ :name ] => :environment do |_task, args|
    name = args.fetch(:name, "metis-pi")
    pi_version = PiAgent::SUPPORTED_PI_VERSION

    puts "Building Docker image '#{name}' with pi #{pi_version}..."

    # Context is the repo root (not docker/pi-runtime) so the Dockerfile can
    # COPY .pi/extensions into the image; .dockerignore keeps storage/ etc. out.
    ok = system(
      "docker", "build",
      "--build-arg", "PI_VERSION=#{pi_version}",
      "--file", "docker/pi-runtime/Dockerfile",
      "--tag", name,
      Rails.root.to_s
    )
    abort "docker build failed" unless ok

    puts
    puts "Built Docker image '#{name}'."
    puts "Point Metis at it:  export METIS_DOCKER_IMAGE=#{name}"
    puts "                    export METIS_AGENT_RUNTIME=docker"
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
