namespace :metis do
  desc "Configuration checklist — reports what's set, missing, or defaulted"
  task doctor: :environment do
    doctor = Doctor.new
    puts doctor.report
    abort unless doctor.ok?
  end
end
