# picoruby-asterism-zenoh: checks that run on a PC, without a board.
#
#   rake               fetch, build, test (the default)
#   rake zenoh:fetch   clone the zenoh-pico release pinned in ZENOH_PICO_PIN
#                      into vendor/zenoh-pico (where mrbgem.rake looks)
#   rake mruby:fetch   clone the mruby pinned in host_test/MRUBY_PIN into vendor/mruby
#   rake build         build mruby with this gem for the host (POSIX platform)
#   rake test          run host_test/test_zenoh.rb against host_test/listener.rb,
#                      two mruby processes talking over a local TCP peer link
#   rake clean         remove the build (vendor/ stays)
#
# Environment overrides: ZENOH_PICO_DIR (a zenoh-pico checkout; mrbgem.rake
# reads it too) and MRUBY_DIR (an mruby checkout). Nothing here is needed to
# use the gem: a PicoRuby / mruby build only reads mrbgem.rake.
require "fileutils"
require "rbconfig"
require "socket"
require "timeout"

ROOT = __dir__
VENDOR = File.join(ROOT, "vendor")
BUILD_DIR = File.join(ROOT, "tmp", "mruby_build")
ZENOH_PICO_DIR = ENV["ZENOH_PICO_DIR"].to_s.empty? ? File.join(VENDOR, "zenoh-pico") : File.expand_path(ENV["ZENOH_PICO_DIR"])
MRUBY_DIR = ENV["MRUBY_DIR"].to_s.empty? ? File.join(VENDOR, "mruby") : File.expand_path(ENV["MRUBY_DIR"])

# Pin files are plain `key: value` lines with # comments.
def read_pin(path)
  pin = {}
  File.readlines(path).each do |line|
    next if line.strip.empty? || line.start_with?("#")
    k, v = line.split(":", 2)
    pin[k.strip] = v.strip if v
  end
  abort "broken pin file #{path}" unless pin["repo"] && pin["commit"]
  pin
end

# Clones repo at the pinned commit into dir (shallow), or moves an existing
# clone there. Leaves the checkout detached at the commit.
def fetch_pinned(pin, dir)
  if Dir.exist?(File.join(dir, ".git"))
    head = `git -C #{dir} rev-parse HEAD 2>/dev/null`.strip
    return if head == pin["commit"]
  else
    FileUtils.mkdir_p(dir)
    sh "git", "-C", dir, "init", "-q"
    sh "git", "-C", dir, "remote", "add", "origin", pin["repo"]
  end
  sh "git", "-C", dir, "fetch", "-q", "--depth", "1", "origin", pin["commit"]
  sh "git", "-C", dir, "checkout", "-q", "--detach", pin["commit"]
  head = `git -C #{dir} rev-parse HEAD`.strip
  abort "#{dir} is at #{head}, expected #{pin['commit']}" unless head == pin["commit"]
end

def zenoh_pico_pin
  read_pin(File.join(ROOT, "ZENOH_PICO_PIN"))
end

namespace :zenoh do
  desc "Clone the pinned zenoh-pico release into vendor/zenoh-pico"
  task :fetch do
    next unless ENV["ZENOH_PICO_DIR"].to_s.empty?
    pin = zenoh_pico_pin
    fetch_pinned(pin, ZENOH_PICO_DIR)
    puts "zenoh-pico #{pin['tag']} (#{pin['commit'][0, 12]}) in #{ZENOH_PICO_DIR}"
  end
end

namespace :mruby do
  desc "Clone the mruby pinned in host_test/MRUBY_PIN into vendor/mruby"
  task :fetch do
    next unless ENV["MRUBY_DIR"].to_s.empty?
    pin = read_pin(File.join(ROOT, "host_test", "MRUBY_PIN"))
    fetch_pinned(pin, MRUBY_DIR)
    puts "mruby #{pin['commit'][0, 12]} in #{MRUBY_DIR}"
  end
end

desc "Build mruby with this gem for the host"
task build: ["zenoh:fetch", "mruby:fetch"] do
  env = { "MRUBY_CONFIG" => File.join(ROOT, "host_test", "build_config.rb"),
          "MRUBY_BUILD_DIR" => BUILD_DIR }
  env["ZENOH_PICO_DIR"] = ZENOH_PICO_DIR unless ENV["ZENOH_PICO_DIR"].to_s.empty?
  jobs = ENV["JOBS"] || "8"
  Dir.chdir(MRUBY_DIR) { sh env, RbConfig.ruby, "-S", "rake", "-j#{jobs}", "all" }
end

def mruby_bin
  bin = File.join(BUILD_DIR, "host", "bin", "mruby")
  abort "#{bin} not found (rake build)" unless File.executable?(bin)
  bin
end

def free_port
  s = TCPServer.new("127.0.0.1", 0)
  port = s.addr[1]
  s.close
  port
end

desc "Run the host test (two mruby processes over a local TCP peer link)"
task test: :build do
  bin = mruby_bin
  port = free_port
  listener = IO.popen([bin, File.join(ROOT, "host_test", "listener.rb"), port.to_s], err: [:child, :out])
  begin
    line = Timeout.timeout(10) { listener.gets }
    abort "listener did not start: #{line.inspect}" unless line&.start_with?("ready")
    puts "listener: #{line}"
    ok = system(bin, File.join(ROOT, "host_test", "test_zenoh.rb"), port.to_s, zenoh_pico_pin["tag"].to_s)
    abort "host test failed" unless ok
    # The test ends by stopping the listener (pz/in/stop).
    rest = Timeout.timeout(10) { listener.read }
    puts "listener: #{rest}" unless rest.to_s.empty?
  ensure
    begin
      Process.kill("TERM", listener.pid)
    rescue Errno::ESRCH
      nil
    end
    listener.close
  end
end

desc "Remove the host build (vendor/ stays)"
task :clean do
  FileUtils.rm_rf(File.join(ROOT, "tmp"))
end

task default: :test
