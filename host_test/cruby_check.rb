# The mruby side of `rake test_cruby`: a client of cruby_router.rb's
# zenoh-c router. Checks what zenoh-pico reads from zenoh-c (encoding,
# attachment, the router's timestamp) and sends the other way through a
# declared publisher and session.put; cruby_router.rb prints what it got
# and the Rakefile compares.
#
#   mruby cruby_check.rb PORT
Z = Asterism::Zenoh
port = ARGV[0]
$fails = 0

def check(cond, what)
  return if cond
  $fails += 1
  puts "FAIL: #{what}"
end

s = Z::Session.open("tcp/127.0.0.1:#{port}")
sub = s.subscribe("x/cruby/**")
pub = s.publisher("x/pico/p", encoding: "image/png")
seen = {}
t = Time.now
while Time.now - t < 5 && seen.size < 2
  s.poll
  sub.each_sample { |sm| seen[sm.key] ||= sm }
  usleep 20_000
end
a = seen["x/cruby/a"]
b = seen["x/cruby/b"]
check(a && a.payload == "jpeg" && a.attachment == "\x05" && a.encoding == "image/jpeg", "from zenoh-c: #{a.inspect}")
check(b && b.encoding == "zenoh/bytes" && b.attachment.nil?, "from zenoh-c without an encoding: #{b.inspect}")
ts = a && a.timestamp
check(ts.is_a?(Z::Timestamp), "the router stamped the sample: #{ts.inspect}")
if ts.is_a?(Z::Timestamp)
  check((ts.to_time.to_i - Time.now.to_i).abs < 60, "the router's time is now: #{ts.to_time}")
  check(b.timestamp.is_a?(Z::Timestamp) && b.timestamp.id == ts.id, "one router, one clock ID")
end
# A reply larger than a batch comes in fragments: 12,000 bytes fit the
# reassembly buffer (Z_FRAG_MAX_SIZE 16384), 20,000 do not (dropped: no
# reply, the get ends).
{ "x/big" => 12_000, "x/huge" => nil }.each do |key, size|
  g = s.get(key)
  t = Time.now
  until g.done? || Time.now - t > 3
    s.poll
    usleep 20_000
  end
  rs = g.each_result
  if size
    check(rs.size == 1 && rs[0].payload.bytesize == size, "#{size} bytes from zenoh-c: #{rs.map { _1.payload.to_s.bytesize }}")
  else
    check(rs.empty? && g.done?, "a reply past Z_FRAG_MAX_SIZE is dropped: #{rs.map { _1.payload.to_s.bytesize }}")
  end
end
pub.put("p1", attachment: "\x01")
pub.put("p2", encoding: "text/csv")
s.put("x/pico/s", "s1", encoding: "application/cdr")
s.put("x/pico/n", "s2")
g = s.get("x/q")
t = Time.now
until g.done? || Time.now - t > 3
  s.poll
  usleep 20_000
end
rs = g.each_result
check(rs.size == 1 && rs[0].payload == "ans" && rs[0].encoding == "text/plain", "reply from zenoh-c: #{rs.inspect}")
t = Time.now
while Time.now - t < 1
  s.poll
  usleep 20_000
end
pub.close
s.close
puts "cruby_check: #{$fails} failed"
exit($fails == 0 ? 0 : 1)
