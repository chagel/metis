require "test_helper"
require "rake"
require Rails.root.join("lib/tasks/support/runtime_image")

# runtime:image is the single refresh command, so its dispatch has to name a
# task that exists for every runtime, and "refreshed" has to mean the artifact
# the runtime actually pulls — for microsandbox that is a registry ref, not a
# local docker tag.
class RuntimeImageTest < ActiveSupport::TestCase
  REMOTE_RUNTIMES = %w[docker e2b daytona microsandbox].freeze

  test "every remote runtime dispatches to a build task the repo defines" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("docker:image")


    REMOTE_RUNTIMES.each do |kind|
      build = RuntimeImage.build_task(kind)
      assert Rake::Task.task_defined?(build),
        "runtime #{kind} dispatches to #{build}, which no rakefile defines"
    end
  end

  test "each runtime builds under its own name, microsandbox borrows docker's" do
    assert_equal "e2b:image", RuntimeImage.build_task("e2b")
    assert_equal "daytona:image", RuntimeImage.build_task("daytona")
    assert_equal "docker:image", RuntimeImage.build_task("docker")
    assert_equal "docker:image", RuntimeImage.build_task("microsandbox")
  end

  test "only microsandbox needs a push to be refreshed" do
    assert RuntimeImage.push?("microsandbox")
    (REMOTE_RUNTIMES - [ "microsandbox" ]).each do |kind|
      assert_not RuntimeImage.push?(kind), "#{kind} builds in place — nothing to push"
    end
  end

  test "a bare tag is not a pushable ref" do
    assert_not RuntimeImage.registry_ref?("metis-pi")
    assert_not RuntimeImage.registry_ref?("metis-pi:0.84.1")
    assert_not RuntimeImage.registry_ref?("chagel/metis-pi"), "docker.io/<owner> is not the worker's registry"
    assert_not RuntimeImage.registry_ref?("")
    assert_not RuntimeImage.registry_ref?(nil)
  end

  test "a registry-qualified ref is pushable" do
    assert RuntimeImage.registry_ref?("ghcr.io/chagel/metis-pi:0.84.1")
    assert RuntimeImage.registry_ref?("registry.example.com/metis-pi")
    assert RuntimeImage.registry_ref?("localhost/metis-pi")
    assert RuntimeImage.registry_ref?("localhost:5000/metis-pi")
  end
end
