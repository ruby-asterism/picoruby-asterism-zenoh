# Host test of Asterism::Zenoh on mruby (rake test): talks over TCP to
# listener.rb, which runs as another process.
#
#   mruby test_zenoh.rb PORT PICO_VERSION
#
# Prints one line per failed check and a summary; exits with 1 on failure.
port = ARGV[0]
pico_version = ARGV[1]
Z = Asterism::Zenoh
# Deprecated calls raise here, so nothing uses an old form by accident; the
# checks of the old forms switch to :warn around themselves.
Asterism.deprecations = :raise
$checks = 0
$fails = 0

def check(cond, what)
  $checks += 1
  return if cond
  $fails += 1
  puts "FAIL: #{what}"
end

def raises(klass, what)
  yield
  check(false, "#{what}: nothing raised")
rescue klass
  check(true, what)
rescue => e
  check(false, "#{what}: #{e.class}: #{e.message} instead of #{klass}")
end

# Polls the session until the block is true or the time is up.
def wait_for(s, sec = 3)
  t = Time.now
  until yield
    return false if Time.now - t > sec
    s.poll
    usleep 5000
  end
  true
end

# ---- constants and arguments ------------------------------------------------
check(Z::PICO_VERSION == pico_version, "PICO_VERSION #{Z::PICO_VERSION.inspect}, pinned #{pico_version}")
check(Z::CONNECT_TIMEOUT_MS == 3000, "CONNECT_TIMEOUT_MS")
check(Z::SEND_TIMEOUT_MS == 3000, "SEND_TIMEOUT_MS")
check(Z::PEER == true, "PEER")
check(Z::MAX_PEERS == 3, "MAX_PEERS #{Z::MAX_PEERS}")
check(!Object.const_defined?(:Zenoh), "no top-level Zenoh")
check(Z::VERSION == "0.4.0", "VERSION #{Z::VERSION}")
check(Z::BACKEND == :zenoh_pico && Z::BACKEND_VERSION == Z::PICO_VERSION, "BACKEND")
check(Z::PEER_SUPPORTED == Z::PEER && Z::DEFAULT_TIMEOUT == 2.0, "PEER_SUPPORTED, DEFAULT_TIMEOUT")
check(Z::Error.superclass == Asterism::Error && Asterism::Error.superclass == StandardError, "error tree")
check(Z::ClosedError.superclass == Z::Error, "ClosedError < Zenoh::Error")
check(Asterism::DeprecationError.superclass == Asterism::Error, "DeprecationError < Asterism::Error")
raises(ArgumentError, "config: on the boards") { Z::Session.open("tcp/127.0.0.1:1", config: {}) }
raises(ArgumentError, "connect_timeout: on the boards") { Z::Session.open("tcp/127.0.0.1:1", connect_timeout: 1) }
raises(ArgumentError, "open(nil) in client mode") { Z::Session.open(nil) }
raises(ArgumentError, "unknown mode") { Z::Session.open("tcp/127.0.0.1:1", mode: :router) }
t = Time.now
begin
  Z::Session.open("tcp/127.0.0.1:1")
  check(false, "open with nobody listening: nothing raised")
rescue Z::Error => e
  check(e.code.is_a?(Integer) && e.code < 0, "open with nobody listening: Error#code #{e.code.inspect}")
end
check(Time.now - t < Z::CONNECT_TIMEOUT_MS / 1000.0 + 2, "open gives up within the connect limit")

# ---- session ----------------------------------------------------------------
s = Z::Session.open("tcp/127.0.0.1:#{port}", mode: :peer)
check(s.poll, "poll on an open session")
check(!s.closed?, "not closed")
check(s.connection_count == 1, "connection_count #{s.connection_count}")
raises(Asterism::DeprecationError, "peers raises when deprecations raise") { s.peers }
Asterism.deprecations = :warn
Asterism.reset_deprecations
check(s.peers == 1 && s.peers == 1, "peers still answers (deprecated)")
check(Asterism.deprecated_names == ["Session#peers"], "peers warned once: #{Asterism.deprecated_names.inspect}")
Asterism.deprecations = :raise
zid = s.zid
check(zid.is_a?(String) && zid.size >= 2 && zid.bytes.all? { |b| (48..57).include?(b) || (97..102).include?(b) }, "zid #{zid.inspect}")
raises(ArgumentError, "bad key") { s.subscribe("pz/bad//key") }
raises(ArgumentError, "depth 0") { s.subscribe("pz/x", 0) }
raises(ArgumentError, "depth: 0") { s.subscribe("pz/x", depth: 0) }
raises(ArgumentError, "depth given twice") { s.subscribe("pz/x", 2, depth: 2) }
raises(ArgumentError, "timeout given twice") { s.get("pz/x", timeout: 1, timeout_ms: 1000) }
raises(ArgumentError, "timeout below 1 ms") { s.get("pz/x", timeout: 0.0001) }
raises(TypeError, "payload not a String") { s.put("pz/x", 1) }

# ---- put / subscribe ----------------------------------------------------------
sub = s.subscribe("pz/out/**")
usleep 300_000
s.poll
s.put("pz/in/x", "hello \xff", attachment: "\x01\x02")
s.put("pz/in/y", "plain")
check(wait_for(s) { sub.pending == 2 }, "two echoes (pending #{sub.pending})")
got = sub.each_pending
check(got == [["pz/out/x", "hello \xff", "\x01\x02"], ["pz/out/y", "plain", nil]], "echoes #{got.inspect}")
check(sub.received == 2 && sub.pending == 0, "counts after each_pending")
s.put("pz/in/z", "blk")
check(wait_for(s) { sub.pending == 1 }, "block form")
seen = []
n = sub.each_pending { |k, v, att| seen << [k, v, att] }
check(n == 1 && seen == [["pz/out/z", "blk", nil]], "block form #{n} #{seen.inspect}")

# A full ring drops the oldest.
small = s.subscribe("pz/out/d", depth: 2)
usleep 300_000
s.poll
5.times { |i| s.put("pz/in/d", i.to_s) }
check(wait_for(s) { small.received == 5 }, "five received (#{small.received})")
check(small.pending == 2 && small.dropped == 3, "pending #{small.pending} dropped #{small.dropped}")
check(small.each_pending.map { |e| e[1] } == %w[3 4], "the newest two kept")
small.close
check(small.closed?, "subscriber closed")
sub.each_pending # the d echoes landed here too

# ---- get / queryable ------------------------------------------------------------
g = s.get("pz/q/one", timeout: 2.0, params: "a=1", payload: "body", attachment: "qa")
check(wait_for(s) { g.done? }, "get done")
replies = g.each_reply
check(replies == [["pz/q/one", "re:body:a=1:pz/q/**", "qa"]], "reply (and the queryable's key on the query) #{replies.inspect}")
Asterism.deprecations = :warn
Asterism.reset_deprecations
g3 = s.get("pz/q/two", 2000, "b=2", "old")
g4 = s.get("pz/q/three", 2.0)
check(wait_for(s) { g3.done? && g4.done? }, "positional gets done")
check(g3.each_reply == [["pz/q/two", "re:old:b=2:pz/q/**", nil]], "positional get still works")
names = Asterism.deprecated_names
check(names.size == 2 && names[0].include?("positional argument") && names[1].include?("Float"),
      "positional time warned, Float separately: #{names.inspect}")
Asterism.deprecations = :raise
check(g.errors == 0, "no error replies")
g2 = s.get("pz/nobody/here", timeout_ms: 1000)
check(wait_for(s, 4) { g2.done? }, "get with nobody to answer ends")
check(g2.each_reply == [], "no replies")
raises(ArgumentError, "bad target") { s.get("pz/q/x", timeout_ms: 100, target: :bogus) }

# ---- liveliness ---------------------------------------------------------------
# Not checked here: liveliness_get between two zenoh-pico peers gets no
# reply and its Get never turns done? (found with this test, 2026-10-08;
# through a router it answers). The watch below covers the tokens.
w = s.liveliness_watch("pz/alive/**")
check(wait_for(s) { w.pending >= 1 }, "watch reports the token alive now")
check(w.each_pending == [["pz/alive/a", true]], "watch: a up")

# ---- the listener goes away ------------------------------------------------------
s.put("pz/in/stop", "")
check(wait_for(s, 6) { w.pending >= 1 || s.closed? }, "token gone or session closed")
check(wait_for(s, 6) { !s.poll }, "poll false once the listener has gone")
check(s.closed?, "closed? after the listener has gone")
raises(Z::ClosedError, "put on a closed session") { s.put("pz/in/x", "y") }
s.close
s.close
check(s.connection_count == 0, "no connections after close")
v = Z::Session.open(nil, mode: :peer, listen: "tcp/127.0.0.1:#{port}") { |s2| s2.closed? ? :closed : :open }
check(v == :open, "open with a block returns the block's value")

puts "#{$checks} checks, #{$fails} failed"
exit($fails == 0 ? 0 : 1)
