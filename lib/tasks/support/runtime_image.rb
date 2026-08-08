# Which build a runtime's pi image comes from, and what else that runtime
# needs before the image it is configured with is actually refreshed.
# Extracted from runtime.rake so the dispatch and the registry rules are
# testable without booting Rake.
module RuntimeImage
  # microsandbox is the one runtime without a build of its own: it runs
  # docker's OCI image, pulled from a registry rather than a local daemon.
  BUILD_TASKS = { "microsandbox" => "docker:image" }.freeze

  # ...and therefore the one runtime for which building is only half a
  # refresh — the worker pulls the ref, so the ref has to be pushed.
  PUSHES = %w[microsandbox].freeze

  module_function

  def build_task(kind) = BUILD_TASKS.fetch(kind) { "#{kind}:image" }

  def push?(kind) = PUSHES.include?(kind)

  # A bare `metis-pi` is a local docker tag; pushing it would resolve to
  # docker.io/library/metis-pi and be denied. Docker's own rule: the first
  # path segment is a registry only if it looks like a host.
  def registry_ref?(ref)
    host, slash, _rest = ref.to_s.partition("/")
    slash.present? && (host.include?(".") || host.include?(":") || host == "localhost")
  end
end
