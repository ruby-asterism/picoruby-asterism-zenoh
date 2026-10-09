# What only the mruby / PicoRuby binding (zenoh-pico) adds in Ruby: the
# backend constants, the gem's version, and Session.open with a block and
# a clear error for the CRuby-only keywords.
module Asterism
  module Zenoh
    # The gem's version (the same as asterism-zenoh's from 0.4.0 on).
    VERSION = "0.4.0"
    # Which Zenoh implementation is underneath (:zenoh_c on CRuby).
    BACKEND = :zenoh_pico
    # Its version (PICO_VERSION here, C_VERSION on CRuby).
    BACKEND_VERSION = PICO_VERSION

    class Session
      class << self
        alias_method :__asterism_open, :open

        # Session.open(locator = nil, mode: :client, listen: nil) -> Session.
        # With a block: yields the session, closes it when the block ends
        # (also on an exception) and returns the block's value. The CRuby
        # binding's other keywords (config:, config_file:, scouting:,
        # timestamping:, connect_timeout:) raise ArgumentError here.
        def open(locator = nil, mode: nil, listen: nil, **opts)
          unless opts.empty?
            names = opts.keys.map { |k| "#{k}:" }.join(", ")
            why = if opts.key?(:config) || opts.key?(:config_file)
                    "no zenoh configuration (and no TLS) on zenoh-pico builds"
                  elsif opts.key?(:connect_timeout)
                    "the connect time limit is fixed at build time (CONNECT_TIMEOUT_MS = #{CONNECT_TIMEOUT_MS} ms)"
                  else
                    "CRuby (asterism-zenoh) only"
                  end
            raise ArgumentError, "Session.open: #{names} not supported by the zenoh-pico binding (#{why})"
          end
          s = __asterism_open(locator, mode: mode, listen: listen)
          return s unless block_given?
          begin
            yield s
          ensure
            s.close
          end
        end
      end
    end
  end
end
