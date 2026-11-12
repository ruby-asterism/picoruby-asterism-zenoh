# The CRuby side of `rake test_cruby` (run with CRuby and asterism-zenoh):
# a zenoh-c router (routers stamp what passes through them by default) and
# a client session on it, against host_test/cruby_check.rb (mruby).
#
#   ruby -I<asterism-zenoh>/lib cruby_router.rb PORT
#
# - puts x/cruby/a ("jpeg", image/jpeg, attachment "\x05") and x/cruby/b
#   (no encoding) again and again, until it has heard from the other side
# - answers queries on x/q with "ans" (text/plain)
# - prints one "got <key> <payload> <attachment> <encoding> <stamped>" line
#   per sample on x/pico/** and "done" after four (or the time limit)
require "asterism/zenoh"
Z = Asterism::Zenoh
port = ARGV[0]
r = Z::Session.open(config: { "mode" => "router", "listen/endpoints" => ["tcp/127.0.0.1:#{port}"],
                              "scouting/multicast/enabled" => false })
c = Z::Session.open("tcp/127.0.0.1:#{port}")
sub = c.subscribe("x/pico/**")
qa = c.queryable("x/q")
puts "ready"
$stdout.flush
deadline = Time.now + 20
got = 0
while Time.now < deadline && got < 4
  sub.each_sample do |sm|
    puts "got #{sm.key} #{sm.payload} #{sm.attachment.inspect} #{sm.encoding} #{!sm.timestamp.nil?}"
    got += 1
  end
  qa.each_pending { |q| q.reply("x/q", "ans", encoding: "text/plain") }
  if got == 0
    c.put("x/cruby/a", "jpeg", encoding: "image/jpeg", attachment: "\x05")
    c.put("x/cruby/b", "plain")
  end
  $stdout.flush
  sleep 0.1
end
puts "done"
$stdout.flush
c.close
r.close
