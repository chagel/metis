namespace :runtime do
  # Every remote runtime bakes pi into a provider artifact, so every one
  # builds it with <runtime>:image. This is the entry point that picks the
  # right one, so "rebuild the pi image after a bump" is a single command
  # whatever the deployment runs.
  #
  # REPLACE=1 is read by the provider task that needs it (daytona snapshots
  # are immutable by name); docker tags and E2B templates overwrite in place.
  #
  # microsandbox is the one runtime without its own build: it runs docker's
  # OCI image, pulled from a registry rather than a local daemon.
  BUILD_TASKS = { "microsandbox" => "docker:image" }.freeze

  desc "Build the configured runtime's pi image. Usage: rake runtime:image[name] — REPLACE=1 to rebuild over an existing one"
  task :image, [ :name ] => :environment do |_task, args|
    kind = Rails.application.config.x.agent.runtime.to_s

    if kind == "local"
      abort "[runtime] local runs the pi on this host's PATH — " \
            "npm i -g @earendil-works/pi-coding-agent@#{PiAgent::SUPPORTED_PI_VERSION}"
    end

    build = BUILD_TASKS.fetch(kind) { "#{kind}:image" }
    abort "[runtime] no #{build} task for runtime #{kind.inspect}" unless Rake::Task.task_defined?(build)

    name = args[:name].presence || Agent::Runtime.image_ref.presence || "metis-pi"

    puts "[runtime] #{kind} -> #{build}[#{name}]"
    Rake::Task[build].invoke(name)

    if kind == "microsandbox"
      puts
      puts "[runtime] microsandbox pulls from an OCI registry, not the local daemon —"
      puts "          push '#{name}' somewhere the worker can pull it from."
    end
  end
end
