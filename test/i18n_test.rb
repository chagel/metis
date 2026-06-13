require "test_helper"

# Guardrail for the i18n extraction: the English baseline must be complete.
# Defined keys are checked here; referenced keys are caught at render time
# by config.i18n.raise_on_missing_translations (test env).
class I18nTest < ActiveSupport::TestCase
  LOCALE_FILES = Rails.root.glob("config/locales/*.en.yml").freeze

  def each_leaf(node, prefix = [], &blk)
    case node
    when Hash
      node.each { |key, value| each_leaf(value, prefix + [ key ], &blk) }
    else
      blk.call(prefix.join("."), node)
    end
  end

  test "every app-defined en translation has a non-blank value" do
    blank = []
    LOCALE_FILES.each do |file|
      tree = YAML.unsafe_load_file(file).fetch("en")
      each_leaf(tree) do |key, value|
        blank << "#{file.basename}: en.#{key}" if value.nil? || (value.respond_to?(:strip) && value.strip.empty?)
      end
    end

    assert_empty blank, "Blank/nil en translations:\n#{blank.join("\n")}"
  end

  test "the extracted namespaces are loaded into the backend" do
    I18n.backend.send(:init_translations) unless I18n.backend.initialized?
    en = I18n.backend.send(:translations).fetch(:en)

    %i[common flash activerecord helpers].each do |namespace|
      assert en.key?(namespace), "expected #{namespace}.* keys to be loaded"
    end
  end
end
