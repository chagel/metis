namespace :daytona do
  desc "Build the Daytona snapshot with pi baked in (needs DAYTONA_API_KEY). Usage: rake daytona:snapshot[name]"
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

    # xurl (pinned) + the xurl-mcp wrapper — the X connector's stdio MCP
    # bridge. No build context here, so the wrapper rides in as base64.
    # Keep the version in sync with bin/setup, Dockerfile.dev,
    # docker/pi-runtime/Dockerfile, and e2b.rake.
    wrapper = [ File.read(Rails.root.join("docker/pi-runtime/xurl-mcp")) ].pack("m0")
    install_xurl =
      "curl -fsSL \"https://github.com/xdevplatform/xurl/releases/download/v1.2.2/" \
      "xurl_Linux_$(uname -m | sed s/aarch64/arm64/).tar.gz\" | tar -xz -C /usr/local/bin xurl && " \
      "echo #{wrapper} | base64 -d > /usr/local/bin/xurl-mcp && chmod 0755 /usr/local/bin/xurl-mcp"

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
                              "pi install npm:pi-mcp-adapter@2.7.0",
                              install_xurl
                            )

    client = Agent::Runtime::Daytona.client
    response = client.snapshot.create(image, name: name, on_logs: ->(line) { puts line })

    puts
    puts "Built Daytona snapshot '#{name}' (id: #{response['id'] || response[:id]})."
    puts "Point Metis at it:  export METIS_DAYTONA_SNAPSHOT=#{name}"
  end
end
