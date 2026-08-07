namespace :daytona do
  # Daytona snapshots are immutable and unique by name, and the API has no
  # replace — so a pi bump can only reuse the configured name by deleting
  # first. Opt-in (REPLACE=1) because it is a destructive call against a
  # shared org: existing sandboxes keep running, but none can be created
  # until the new snapshot finishes building.
  def self.replace_snapshot(client, name)
    existing = begin
      client.snapshot.get(name)
    rescue StandardError
      nil
    end
    return puts "No existing snapshot '#{name}' to replace." if existing.nil?

    id = existing["id"] || existing[:id]
    puts "Deleting snapshot '#{name}' (id: #{id}, state: #{existing["state"] || existing[:state]})..."
    client.snapshot.delete(id)
    wait_for_deletion(client, name)
  end

  # Deletion is asynchronous — the name stays taken for a few seconds after
  # the call returns, and creating into it fails with "already exists".
  def self.wait_for_deletion(client, name, attempts: 30, interval: 2)
    attempts.times do
      begin
        client.snapshot.get(name)
      rescue Daytona::NotFoundError
        return puts "Deleted."
      end
      sleep interval
    end
    abort "[daytona] snapshot '#{name}' still exists #{attempts * interval}s after delete"
  end

  desc "Build the Daytona snapshot with pi baked in (needs DAYTONA_API_KEY). " \
       "Usage: rake daytona:snapshot[name] — REPLACE=1 to rebuild over an existing one"
  task :snapshot, [ :name ] => :environment do |_task, args|
    name = args.fetch(:name, "metis-pi")
    pi_package = "@earendil-works/pi-coding-agent@#{PiAgent::SUPPORTED_PI_VERSION}"

    puts "Building Daytona snapshot '#{name}' with #{pi_package}..."

    # `gh` is installed from GitHub's apt source so the agent can act on
    # GitHub as the operator via the per-turn GH_TOKEN env var (see
    # app/services/agent/runtime/base.rb + docs/connectors.md). Keep the
    # pi-mcp-adapter and gws versions in sync with bin/setup, e2b.rake, and
    # docker/pi-runtime/Dockerfile. The sandbox runs as root (Daytona::OS_USER),
    # so `pi install` writes root's ~/.pi and run-time discovery agrees.
    install_gh = <<~SH.strip.gsub(/\s+/, " ")
      install -m 0755 -d /etc/apt/keyrings &&
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg &&
      chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg &&
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main"
        > /etc/apt/sources.list.d/github-cli.list &&
      apt-get update && apt-get install -y --no-install-recommends gh &&
      rm -rf /var/lib/apt/lists/*
    SH

    # The community Daytona SDK's snapshot builder ships only the Dockerfile
    # (no local build context), so the repo's .pi/skills/ tree is NOT baked in.
    # Runtime::Daytona#stage_skills detects the missing BAKED_REPO_SKILLS_DIR
    # and uploads skills from the host on a fresh sandbox instead.
    image = ::Daytona::Image.base("node:22-bookworm")
                            .run_commands(
                              "apt-get update && apt-get install -y --no-install-recommends curl gnupg ca-certificates",
                              install_gh,
                              "npm install -g #{pi_package}",
                              # The Google Workspace CLI (gws) — how the agent
                              # reaches Gmail, Calendar, and Drive. Reads its
                              # bearer from GOOGLE_WORKSPACE_CLI_TOKEN, exported
                              # per turn from the user's Google OauthGrant.
                              "npm install -g @googleworkspace/cli",
                              "pi install npm:pi-mcp-adapter@2.7.0"
                            )

    client = Agent::Runtime::Daytona.client
    replace_snapshot(client, name) if ENV["REPLACE"].present?
    response = client.snapshot.create(image, name: name, on_logs: ->(line) { puts line })

    puts
    puts "Built Daytona snapshot '#{name}' (id: #{response['id'] || response[:id]})."
    puts "Point Metis at it:  export METIS_DAYTONA_SNAPSHOT=#{name}"
  end
end
