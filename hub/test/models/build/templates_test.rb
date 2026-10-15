require "test_helper"

class Build::TemplatesTest < ActiveSupport::TestCase
  test "accepts bounded metadata and preserves path query and fragment" do
    entry = template(path: "/settings?tab=profile#details")
    assert_equal [ entry ], Build::Templates.parse(JSON.generate(version: 1, templates: [ entry ]))
    assert_equal [], Build::Templates.parse('{"version":1,"templates":[]}')
  end

  test "counts Unicode text by codepoints and rejects ASCII controls" do
    entry = template.merge("name" => "🌱" * 120, "description" => "A journal.\u0085")
    assert_equal [ entry ], parse([ entry ])
    assert_raises(Build::Templates::InvalidManifest) { parse([ entry.merge("name" => "🌱" * 121) ]) }
    assert_raises(Build::Templates::InvalidManifest) { parse([ entry.merge("name" => "Name\u007f") ]) }
  end

  test "rejects reserved duplicate or malformed identifiers and unknown fields" do
    [ "default", "Uppercase", "-leading", "double--dash", "x" * 65 ].each do |id|
      assert_raises(Build::Templates::InvalidManifest) { parse([ template(id:) ]) }
    end
    assert_raises(Build::Templates::InvalidManifest) { parse([ template, template ]) }
    assert_raises(Build::Templates::InvalidManifest) { parse([ template.merge("extra" => true) ]) }
    assert_raises(Build::Templates::InvalidManifest) { parse(Array.new(13) { |index| template(id: "page-#{index}") }) }
  end

  test "rejects metadata versions and field or document limits" do
    [ "invalid", '{"version":2,"templates":[]}', '{"version":1,"templates":null}',
      '{"version":1,"templates":[],"hub":{}}', " " * (16.kilobytes + 1) ].each do |source|
      assert_raises(Build::Templates::InvalidManifest) { Build::Templates.parse(source) }
    end
    [ { "name" => "n" * 121 }, { "category" => "c" * 81 },
      { "description" => "d" * 501 }, { "description" => "" },
      { "name" => "Name\nwith controls" } ].each do |fields|
      assert_raises(Build::Templates::InvalidManifest) { parse([ template.merge(fields) ]) }
    end
  end

  test "rejects external ambiguous traversal and reserved routes" do
    [ "https://example.com/", "//example.com/", "/\\evil", "/a/../b", "/a/%2e%2e/b",
      "/__replica", "/__replica/preview", "/%5f%5freplica/preview", "/%252e%252e",
      "/%2fexample.com", "/%invalid", "/space here", "/encoded%20space",
      "/%00", "/%ff", "/#{'a' * 2048}",
      "/.replica-internal/page", "/%2ereplica-internal/page" ].each do |path|
      assert_raises(Build::Templates::InvalidManifest, path) { parse([ template(path:) ]) }
    end
  end

  test "bounds browser-serialized destinations and accepts encoded start-page compatible routes" do
    [ "/#{'é' * 341}a", "/?q=#{'é' * 340}aaaa", "/?q=#{'`' * 2044}",
      "/?filter[state]=open", "/caf%C3%A9", "/a%7Cb", "/#/x%5B1%5D", "/a^b" ].each do |path|
      assert_equal [ template(path:) ], parse([ template(path:) ]), path
    end

    [ "/#{'é' * 341}aa", "/?q=#{'é' * 340}aaaaa", "/?q=#{'é' * 400}",
      "/?q=#{"'" * 682}", "/a|b", "/#/x[1]", "/#/issues?filter[state]=open",
      "/#a^b", "/#%invalid" ].each do |path|
      assert_raises(Build::Templates::InvalidManifest, path) { parse([ template(path:) ]) }
    end
  end

  private

  def parse(templates)
    Build::Templates.parse(JSON.generate(version: 1, templates:))
  end

  def template(id: "welcome", path: "/#/welcome")
    { "id" => id, "name" => "Welcome", "category" => "Editorial",
      "description" => "A journal.", "path" => path }
  end
end
