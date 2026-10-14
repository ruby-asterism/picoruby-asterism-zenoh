# Test only (host_test/build_config.rb): a platform default namespace for
# the host test, set from Ruby (PZTest.default_namespace = "room/a"). It
# defines picoruby_zenoh_default_namespace, which replaces the gem's weak
# one, as a platform would (the Family mruby browser build).
MRuby::Gem::Specification.new('pz-test-ns-hook') do |spec|
  spec.license = 'MIT'
  spec.authors = ['Katsuhiko Kageyama']
  spec.summary = 'host test: the default namespace hook of picoruby-asterism-zenoh'
end
