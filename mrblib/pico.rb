# What only the mruby / PicoRuby binding (zenoh-pico) adds in Ruby: the
# backend constants, the gem's version, and Session.open with a block and
# a clear error for the CRuby-only keywords; config: takes the TLS settings.
module Asterism
  module Zenoh
    # The gem's version (the same as asterism-zenoh's from 0.4.0 on).
    VERSION = "0.4.1"
    # Which Zenoh implementation is underneath (:zenoh_c on CRuby).
    BACKEND = :zenoh_pico
    # Its version (PICO_VERSION here, C_VERSION on CRuby).
    BACKEND_VERSION = PICO_VERSION

    class Session
      # The zenoh configuration keys config: takes here: the TLS settings
      # of a tls/ locator (what Asterism::Credentials hands CRuby too).
      TLS_PREFIX = "transport/link/tls/"
      TLS_KEYS = %w[root_ca_certificate_base64 connect_certificate_base64 connect_private_key_base64
                    enable_mtls verify_name_on_connect].freeze

      class << self
        alias_method :__asterism_open, :open

        # Session.open(locator = nil, mode: :client, listen: nil, config: nil) -> Session.
        # With a block: yields the session, closes it when the block ends
        # (also on an exception) and returns the block's value.
        # config: a Hash of TLS settings only, under their zenoh names
        # ("transport/link/tls/root_ca_certificate_base64",
        # "connect_certificate_base64", "connect_private_key_base64",
        # "enable_mtls", "verify_name_on_connect"), for a tls/ locator; the
        # certificates and the key are base64 of their PEM, as CRuby takes
        # them. TLS links are built on ESP-IDF only (TLS). The CRuby
        # binding's other keywords (config_file:, scouting:, timestamping:,
        # connect_timeout:) and other config: keys raise ArgumentError here.
        def open(locator = nil, mode: nil, listen: nil, config: nil, **opts)
          unless opts.empty?
            names = opts.keys.map { |k| "#{k}:" }.join(", ")
            why = if opts.key?(:config_file)
                    "no zenoh configuration files on zenoh-pico builds"
                  elsif opts.key?(:connect_timeout)
                    "the connect time limit is fixed at build time (CONNECT_TIMEOUT_MS = #{CONNECT_TIMEOUT_MS} ms)"
                  else
                    "CRuby (asterism-zenoh) only"
                  end
            raise ArgumentError, "Session.open: #{names} not supported by the zenoh-pico binding (#{why})"
          end
          tls = config.nil? ? nil : tls_settings(config)
          tls = nil if tls && tls.empty?
          s = __asterism_open(locator, mode: mode, listen: listen, tls: tls)
          return s unless block_given?
          begin
            yield s
          ensure
            s.close
          end
        end

        # config: -> [name, value, ...] for the binding. @api private
        def tls_settings(config)
          unless config.is_a?(Hash)
            raise ArgumentError, "Session.open: config: must be a Hash on the zenoh-pico binding (TLS settings only)"
          end
          out = []
          config.each do |k, v|
            key = k.to_s
            name = key.start_with?(TLS_PREFIX) ? key[TLS_PREFIX.size, key.size - TLS_PREFIX.size] : nil
            unless name && TLS_KEYS.include?(name)
              raise ArgumentError, "Session.open: config: #{key} is not supported by the zenoh-pico binding (TLS settings only)"
            end
            out << name
            out << (v == true ? "true" : (v == false ? "false" : v.to_s))
          end
          out
        end
      end
    end
  end
end
