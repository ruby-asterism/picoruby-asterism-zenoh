# mruby build for the host test (rake test): a plain host build with this
# gem and the few core gems the test scripts use. The build name "host"
# selects zenoh-pico's POSIX platform (see mrbgem.rake).
MRuby::Build.new("host") do |conf|
  conf.toolchain :gcc
  conf.enable_debug
  conf.cc.flags << "-O1"

  conf.gem core: "mruby-bin-mruby"
  conf.gem core: "mruby-sleep"
  conf.gem core: "mruby-time"
  conf.gem core: "mruby-string-ext"
  conf.gem core: "mruby-array-ext"
  conf.gem core: "mruby-kernel-ext"
  conf.gem core: "mruby-sprintf"
  conf.gem core: "mruby-exit"
  conf.gem core: "mruby-io"
  conf.gem core: "mruby-enum-ext"
  conf.gem File.expand_path("..", __dir__)
end
