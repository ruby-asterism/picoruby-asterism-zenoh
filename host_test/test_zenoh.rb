# Host test of Asterism::Zenoh on mruby (rake test): talks over TCP to
# listener.rb, which runs as another process.
#
#   mruby test_zenoh.rb PORT PICO_VERSION
#
# Prints one line per failed check and a summary; exits with 1 on failure.
port = ARGV[0]
pico_version = ARGV[1]
Z = Asterism::Zenoh
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
raises(ArgumentError, "open(nil) in client mode") { Z::Session.open(nil) }
raises(ArgumentError, "unknown mode") { Z::Session.open("tcp/127.0.0.1:1", mode: :router) }
t = Time.now
raises(Z::Error, "open with nobody listening") { Z::Session.open("tcp/127.0.0.1:1") }
check(Time.now - t < Z::CONNECT_TIMEOUT_MS / 1000.0 + 2, "open gives up within the connect limit")

# ---- session ----------------------------------------------------------------
s = Z::Session.open("tcp/127.0.0.1:#{port}", mode: :peer)
check(s.poll, "poll on an open session")
check(!s.closed?, "not closed")
check(s.peers == 1, "peers #{s.peers}")
zid = s.zid
check(zid.is_a?(String) && zid.size >= 2 && zid.bytes.all? { |b| (48..57).include?(b) || (97..102).include?(b) }, "zid #{zid.inspect}")
raises(ArgumentError, "bad key") { s.subscribe("pz/bad//key") }
raises(ArgumentError, "depth 0") { s.subscribe("pz/x", 0) }
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
small = s.subscribe("pz/out/d", 2)
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
g = s.get("pz/q/one", 2000, "a=1", "body", attachment: "qa")
check(wait_for(s) { g.done? }, "get done")
replies = g.each_reply
check(replies == [["pz/q/one", "re:body:a=1", "qa"]], "reply #{replies.inspect}")
check(g.errors == 0, "no error replies")
g2 = s.get("pz/nobody/here", 1000)
check(wait_for(s, 4) { g2.done? }, "get with nobody to answer ends")
check(g2.each_reply == [], "no replies")
raises(ArgumentError, "bad target") { s.get("pz/q/x", 100, nil, nil, target: :bogus) }

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
raises(Z::Error, "put on a closed session") { s.put("pz/in/x", "y") }
s.close
s.close
check(s.peers == 0, "no peers after close")

puts "#{$checks} checks, #{$fails} failed"
exit($fails == 0 ? 0 : 1)
