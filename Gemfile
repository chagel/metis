source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3"
# Framework-default translations (datetime, number, errors, support) for
# non-English locales — Rails ships these for `en` only.
gem "rails-i18n"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"

# Authentication
gem "devise"
# GitHub sign-in (Devise omniauthable) — uses the same GitHub App as
# the connector. omniauth-rails_csrf_protection turns the authorize
# request into a POST so it carries the CSRF token.
gem "omniauth-github"
# Google sign-in (Devise omniauthable) — same OAuth client drives the
# Google Workspace connectors (Gmail, Drive, Calendar, …).
gem "omniauth-google-oauth2"
gem "omniauth-rails_csrf_protection"

# Render Markdown message content to HTML (GFM-compliant, native tables)
gem "commonmarker"

# Standard library; bundled gem in Ruby 4+ that we use to stream CSV
# artifact previews row by row.
gem "csv"

# Pagination — used for endless scrolling of the sidebar conversation list
gem "pagy", "~> 43.5"

gem "pi-agent-rb", "~> 0.1.8", require: "pi_agent"

# E2B secure cloud sandboxes — the isolated runtime for the agent
gem "e2b"

# Daytona elastic-sandbox runtime.
gem "daytona", github: "chagel/daytona-sdk"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 2.0"
# libvips driver for image_processing — image_processing lists it only as an
# optional dep, so the variant processor (Rails 8 default :vips) needs it here.
gem "ruby-vips", "~> 2.0"
# S3 (and S3-compatible: R2, MinIO) backend for Active Storage in production.
gem "aws-sdk-s3", require: false

# LLM observability: export per-turn token/cost traces to Langfuse (or any
# OTLP backend) over OpenTelemetry. Required lazily by
# config/initializers/observability.rb only when METIS_LANGFUSE_ENABLED is
# set, so a deployment that leaves it off pays nothing.
gem "opentelemetry-sdk", require: false
gem "opentelemetry-exporter-otlp", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
end
