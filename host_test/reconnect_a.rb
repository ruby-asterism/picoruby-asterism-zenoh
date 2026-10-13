# The side that stays (rake test_reconnect): a client of the router at
# ARGV[0] declares a liveliness token, a subscriber and a queryable, then
# polls while the router restarts. It prints "ready", "lost" and "back"
# (with milliseconds since start), answers queries on rc/q, and ends on the
# value "stop" on rc/x with a summary line "summary <received> <answered>".
Z = Asterism::Zenoh
t0 = Time.now
ms = -> { ((Time.now - t0) * 1000).round }
s = Z::Session.open(ARGV[0])
tok = s.liveliness("rc/a")
sub = s.subscribe("rc/x")
qa = s.queryable("rc/q")
got = []
answered = 0
state = :up
puts "ready auto_reconnect=#{Z::AUTO_RECONNECT}"
$stdout.flush
until Time.now - t0 > 90
  alive = s.poll
  unless alive
    puts "closed #{ms.call}"
    $stdout.flush
    break
  end
  now = s.reconnecting? ? :reconnecting : :up
  if now != state
    puts(now == :reconnecting ? "lost #{ms.call}" : "back #{ms.call}")
    $stdout.flush
    state = now
    # While reconnecting a put is dropped, a get raises (not ClosedError).
    if now == :reconnecting
      s.put("rc/y", "dropped")
      begin
        s.get("rc/nobody", timeout: 0.1)
        puts "get while reconnecting: nothing raised"
      rescue Z::ClosedError => e
        puts "get while reconnecting: ClosedError #{e.message}"
      rescue Z::Error => e
        puts "get while reconnecting: #{e.class} (#{e.message})"
      end
      begin
        late = s.liveliness("rc/late")
        puts "token while reconnecting: declared"
      rescue Z::Error => e
        puts "token while reconnecting: #{e.class} (#{e.message})"
      end
      $stdout.flush
    end
  end
  qa.each_pending.each do |q|
    q.reply("rc/q", "answer")
    q.finish
    answered += 1
  end
  sub.each_pending.each { |e| got << e[1] }
  break if got.include?("stop")
  usleep 5000
end
puts "summary #{got.size} #{answered} #{tok.closed? ? 'token-closed' : 'token-open'}"
s.close
