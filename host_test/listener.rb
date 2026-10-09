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
# - queries on pz/q/** get one reply: "re:<payload>:<params>:<queryable key>", with the
#   query's attachment; a query on pz/q/burst/** gets BURST replies at once
#   (pz/q/burst/k<i>, payload i)
# - holds the liveliness token pz/alive/a, and BURST tokens pz/lv/t<i>
port = ARGV[0]
BURST = 40

# The queryable's key that the binding puts on each query (read by
# Query#reply; this build has no instance_variable_get).
class Asterism::Zenoh::Query
  def test_queryable_key
    @asterism_queryable_key
  end
end

s = Asterism::Zenoh::Session.open(nil, mode: :peer, listen: "tcp/127.0.0.1:#{port}")
sub = s.subscribe("pz/in/**", depth: 64)
qa = s.queryable("pz/q/**")
tok = s.liveliness("pz/alive/a")
burst = []
BURST.times { |i| burst << s.liveliness("pz/lv/t#{i}") }
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
    # The queryable's own key rides on each query (0.4.0); echo it back.
    own = q.test_queryable_key
    if q.key == "pz/q/burst/**"
      BURST.times { |i| q.reply("pz/q/burst/k#{i}", i.to_s) }
    else
      q.reply(q.key, "re:#{q.payload}:#{q.params}:#{own}", attachment: q.attachment)
    end
  end
  usleep 2000
end
tok.close
burst.each(&:close)
s.close
puts "listener done"
