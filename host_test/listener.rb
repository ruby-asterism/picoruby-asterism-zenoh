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
#
# For the namespace checks, two more listening sessions:
# - PORT+1, namespace room/a: put on pz/in/<name> comes back as
#   pz/out/<name> with "a:" before the payload; queries on pz/q/** get
#   "a:<key as seen>"; holds the token pz/alive/a
# - PORT+2, no namespace (it sees the keys as they are on the wire): a put
#   on room/a/pz/in/<name> comes back on room/a/pz/out/<name> with
#   "p:<key as seen>"; queries on room/a/pz/q/** get "p:<key as seen>";
#   holds the tokens room/a/pz/alive/p and room/b/pz/alive/q; watches **.
#   <name> "exact" puts on room/a (the namespace itself) and on
#   room/b/pz/out/x, then on room/a/pz/out/done. <name> "ask" sends the
#   gets room/a/pz/tq/k and **, and when both are done puts
#   "replies=<keys>;tokens=<keys watched>" on room/a/pz/out/report.
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
la = Asterism::Zenoh::Session.open(nil, mode: :peer, listen: "tcp/127.0.0.1:#{port.to_i + 1}", namespace: "room/a")
la_sub = la.subscribe("pz/in/**", depth: 64)
la_qa = la.queryable("pz/q/**")
la_tok = la.liveliness("pz/alive/a")
lp = Asterism::Zenoh::Session.open(nil, mode: :peer, listen: "tcp/127.0.0.1:#{port.to_i + 2}")
lp_sub = lp.subscribe("room/a/pz/in/**", depth: 64)
lp_qa = lp.queryable("room/a/pz/q/**")
lp_toks = [lp.liveliness("room/a/pz/alive/p"), lp.liveliness("room/b/pz/alive/q")]
lp_watch = lp.liveliness_watch("**", depth: 64)
lp_seen = []
lp_gets = nil
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
  la.poll
  la_sub.each_pending { |key, payload, _| la.put("pz/out/#{key.split("/").last}", "a:#{payload}") }
  la_qa.each_pending { |q| q.reply(q.key, "a:#{q.key}") }
  lp.poll
  lp_watch.each_pending { |key, alive| lp_seen << key if alive }
  lp_sub.each_pending do |key, _, _|
    name = key.split("/").last
    if name == "exact"
      lp.put("room/a", "x")
      lp.put("room/b/pz/out/x", "x")
      lp.put("room/a/pz/out/done", "")
    elsif name == "ask"
      lp_gets = [lp.get("room/a/pz/tq/k", timeout: 1.0), lp.get("**", timeout: 1.0)]
    else
      lp.put("room/a/pz/out/#{name}", "p:#{key}")
    end
  end
  lp_qa.each_pending do |q|
    # The ** of "ask" reaches this session's own queryable too; no reply.
    q.reply(q.key, "p:#{q.key}") unless q.key.include?("*")
  end
  if lp_gets && lp_gets.all? { |g| g.done? }
    keys = []
    lp_gets.each { |g| g.each_reply { |k, _, _| keys << k } }
    lp.put("room/a/pz/out/report", "replies=#{keys.join(",")};tokens=#{lp_seen.join(",")}")
    lp_gets = nil
  end
  usleep 2000
end
la_tok.close
lp_toks.each(&:close)
la.close
lp.close
tok.close
burst.each(&:close)
s.close
puts "listener done"
