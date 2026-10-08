# The other side of the host test (rake test runs it as its own process):
# a listening peer that echoes and answers, so test_zenoh.rb can drive a
# real session over TCP. zenoh-pico is single-threaded here, so the two
# sides cannot share one process: opening a session waits for the other
# side's handshake, which only runs while that side polls.
#
#   mruby listener.rb PORT
#
# - put on pz/in/<name> comes back as pz/out/<name>, same payload and
#   attachment; pz/in/stop closes this side
# - queries on pz/q/** get one reply: "re:<payload>:<params>", with the
#   query's attachment
# - holds the liveliness token pz/alive/a
port = ARGV[0]
s = Asterism::Zenoh::Session.open(nil, mode: :peer, listen: "tcp/127.0.0.1:#{port}")
sub = s.subscribe("pz/in/**", 64)
qa = s.queryable("pz/q/**")
tok = s.liveliness("pz/alive/a")
puts "ready #{s.zid}"

stop = false
deadline = Time.now + 120
until stop || Time.now > deadline
  s.poll
  sub.each_pending do |key, payload, att|
    name = key.split("/").last
    if name == "stop"
      stop = true
    else
      s.put("pz/out/#{name}", payload, attachment: att)
    end
  end
  qa.each_pending do |q|
    q.reply(q.key, "re:#{q.payload}:#{q.params}", attachment: q.attachment)
  end
  usleep 2000
end
tok.close
s.close
puts "listener done"
