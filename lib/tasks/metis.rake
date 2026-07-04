namespace :metis do
  desc "Configuration checklist — reports what's set, missing, or defaulted"
  task :doctor do
    # bin/dev (foreman) and Docker Compose inject .env; a bare rake run
    # doesn't. Load it before Rails boots so the doctor diagnoses the
    # same environment the app actually runs in.
    if File.exist?(".env") && ENV.fetch("RAILS_ENV", "development") == "development"
      require "dotenv"
      Dotenv.load(".env")
    end
    Rake::Task["environment"].invoke

    doctor = Doctor.new
    puts doctor.report
    abort unless doctor.ok?
  end
end
