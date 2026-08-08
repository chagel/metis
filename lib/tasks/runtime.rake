require_relative "support/runtime_image"

namespace :runtime do
  # Every remote runtime bakes pi into a provider artifact, so every one
  # builds it with <runtime>:image. This is the entry point that picks the
  # right one, so "rebuild the pi image after a bump" is a single command
  # whatever the deployment runs — including the registry push microsandbox
  # needs, which is part of the refresh rather than a note for the operator.
  #
  # REPLACE=1 is read by the provider task that needs it (daytona snapshots
  # are immutable by name); docker tags and E2B templates overwrite in place.

  # Checked before the build, not after: an unpushable ref would otherwise
  # cost a full image build and still leave the runtime on the old artifact.
  # `docker push metis-pi` resolves to docker.io/library/metis-pi and is
  # denied, which reads as a credentials problem rather than a bad ref.
  def self.require_pushable_ref!(ref)
    return if RuntimeImage.registry_ref?(ref)

    abort "[runtime] #{ref.inspect} is a local docker tag, and microsandbox pulls from an OCI " \
          "registry — set METIS_MICROSANDBOX_IMAGE to a pushable ref " \
          "(e.g. ghcr.io/<owner>/metis-pi:#{PiAgent::SUPPORTED_PI_VERSION}) and re-run."
  end

  def self.push_image(ref)
    puts "[runtime] pushing #{ref}..."
    abort "[runtime] docker push #{ref} failed — is the daemon logged in to that registry?" unless
      system("docker", "push", ref)
    puts "[runtime] pushed #{ref}."
  end

  desc "Build the configured runtime's pi image. Usage: rake runtime:image[name] — REPLACE=1 to rebuild over an existing one"
  task :image, [ :name ] => :environment do |_task, args|
    kind = Rails.application.config.x.agent.runtime.to_s

    if kind == "local"
      abort "[runtime] local runs the pi on this host's PATH — " \
            "npm i -g @earendil-works/pi-coding-agent@#{PiAgent::SUPPORTED_PI_VERSION}"
    end

    build = RuntimeImage.build_task(kind)
    abort "[runtime] no #{build} task for runtime #{kind.inspect}" unless Rake::Task.task_defined?(build)

    name = args[:name].presence || Agent::Runtime.image_ref.presence || "metis-pi"
    push = RuntimeImage.push?(kind)
    require_pushable_ref!(name) if push

    puts "[runtime] #{kind} -> #{build}[#{name}]#{" + push" if push}"
    Rake::Task[build].invoke(name)
    push_image(name) if push
  end
end
