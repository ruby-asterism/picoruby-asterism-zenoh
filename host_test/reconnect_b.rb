# The newcomer (rake test_reconnect): after the router restarted, checks
# that what reconnect_a.rb declared before the restart is there again.
Z = Asterism::Zenoh
s = Z::Session.open(ARGV[0])
ok = true
def wait_done(s, g)
  t = Time.now
  until g.done? || Time.now - t > 3
    s.poll
    usleep 5000
  end
end
g = s.liveliness_get("rc/a", timeout: 2.0)
wait_done(s, g)
toks = g.each_reply
puts "token: #{toks.size}"
ok &&= toks.size == 1
g = s.liveliness_get("rc/late", timeout: 2.0)
wait_done(s, g)
puts "late token: #{g.each_reply.size}"
g = s.get("rc/q", timeout: 2.0)
wait_done(s, g)
r = g.each_reply
puts "query: #{r.map { |e| e[1] }.inspect}"
ok &&= r.size == 1 && r[0][1] == "answer"
3.times { s.poll; usleep 20_000 }
s.put("rc/x", "hello")
s.put("rc/x", "stop")
10.times { s.poll; usleep 20_000 }
s.close
exit(ok ? 0 : 1)
