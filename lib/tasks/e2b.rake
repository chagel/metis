namespace :e2b do
  desc "Build the E2B template with pi baked in (needs E2B_API_KEY). Usage: rake e2b:template[name]"
  task :template, [ :name ] => :environment do |_task, args|
    name = args.fetch(:name, "metis-pi")
    pi_package = "@earendil-works/pi-coding-agent@#{PiAgent::SUPPORTED_PI_VERSION}"

    puts "Building E2B template '#{name}' with #{pi_package}..."

    # The MCP connector bridge (pi-mcp-adapter) is baked in alongside pi.
    # Keep the version in sync with bin/setup and docker/pi-runtime/Dockerfile.
    # `gh` is installed from GitHub's apt source so the agent can act on
    # GitHub as the operator via the per-turn GH_TOKEN env var (see
    # app/services/agent/runtime/base.rb + docs/connectors.md). The
    # apt setup needs root; run_cmd defaults to user `user`, so pass it.
    install_gh = <<~SH.strip.gsub(/\s+/, " ")
      install -m 0755 -d /etc/apt/keyrings &&
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg
        > /etc/apt/keyrings/githubcli-archive-keyring.gpg &&
      chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg &&
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main"
        > /etc/apt/sources.list.d/github-cli.list &&
      apt-get update && apt-get install -y --no-install-recommends gh &&
      rm -rf /var/lib/apt/lists/*
    SH

    # The @googleworkspace/cli package ships both glibc and musl Linux binaries.
    # Its platform detector picks glibc by default, but the e2b base image
    # (Debian bookworm) only has GLIBC 2.36 while the prebuilt glibc binary
    # requires GLIBC 2.39, causing a hard crash on every gws call. Patch
    # platform.js to always prefer musl on Linux (statically linked, no glibc
    # dependency) then force-reinstall the binary.
    fix_gws_musl = <<~'SH'.strip.gsub(/\s+/, " ")
      node -e "
        const fs = require('fs');
        const p = '/usr/local/lib/node_modules/@googleworkspace/cli/platform.js';
        let src = fs.readFileSync(p, 'utf8');
        src = src.replace(
          /\/\/ On Linux[\s\S]*?if \(rawOs === 'Linux'\) \{[\s\S]*?\}\s*\}/,
          \"// On Linux, prefer musl to avoid glibc version issues\n  if (rawOs === 'Linux') { osType = 'unknown-linux-musl'; }\"
        );
        fs.writeFileSync(p, src);
      " &&
      rm -f /usr/local/lib/node_modules/@googleworkspace/cli/bin/.version &&
      node /usr/local/lib/node_modules/@googleworkspace/cli/install.js
    SH

    template = E2B::Template.new(file_context_path: Rails.root.to_s)
                            .from_node_image
                            .apt_install([ "curl", "gnupg" ])
                            .run_cmd(install_gh, user: "root")
                            .npm_install(pi_package, g: true)
                            # The Google Workspace CLI (gws) — how the agent
                            # reaches Gmail, Calendar, and Drive. Reads its
                            # bearer from GOOGLE_WORKSPACE_CLI_TOKEN, which
                            # Agent::Runtime::Base#sandbox_env exports per
                            # turn from the user's Google OauthGrant. The
                            # `gws-*` skills shipped in .pi/skills/ guide the
                            # agent. npm fetches the matching prebuilt
                            # binary from the project's GitHub Releases.
                            .npm_install("@googleworkspace/cli", g: true)
                            # Force the musl (statically-linked) binary — see
                            # fix_gws_musl comment above.
                            .run_cmd(fix_gws_musl, user: "root")
                            # Explicit user: pi extensions install into the user's
                            # home; running as root would write to /root/.pi and
                            # pi at runtime (user `user`) wouldn't find them.
                            # Also workaround for E2B builder leaving user state
                            # unresolved after a prior `user: "root"` step.
                            .run_cmd("pi install npm:pi-mcp-adapter@2.7.0", user: "user")
                            # Bake the repo's .pi/skills/ tree into the image.
                            # Agent::Runtime::E2b#provision copies this into
                            # the conversation workspace on a fresh sandbox
                            # (one sandbox-local cp instead of ~300 per-file
                            # upload RPCs over the wire). Rebuild the template
                            # whenever this tree changes.
                            .copy(".pi/skills", "/opt/metis/repo-skills", user: "root")

    # tags must be a non-null array — the E2B v3 build API rejects null.
    info = E2B::Template.build(template, name: name, tags: [], on_build_logs: ->(line) { puts line })

    puts
    puts "Built E2B template '#{name}' (template_id: #{info.template_id})."
    puts "Point Metis at it:  export METIS_E2B_TEMPLATE=#{name}"
  end
end
