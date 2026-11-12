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

        # Session.open(locator = nil, mode: :client, listen: nil, config: nil, namespace: nil) -> Session.
        # With a block: yields the session, closes it when the block ends
        # (also on an exception) and returns the block's value.
        # config: a Hash of TLS settings (and "namespace") only, under their zenoh names
        # ("transport/link/tls/root_ca_certificate_base64",
        # "connect_certificate_base64", "connect_private_key_base64",
        # "enable_mtls", "verify_name_on_connect"), for a tls/ locator; the
        # certificates and the key are base64 of their PEM, as CRuby takes
        # them. TLS links are built on ESP-IDF, and on POSIX hosts that turn them
        # on (TLS). The CRuby
        # binding's other keywords (config_file:, scouting:, timestamping:,
        # connect_timeout:) and other config: keys raise ArgumentError here.
        # namespace: puts "<namespace>/" in front of every key the session
        # sends and takes it off every key it receives (zenoh-c's
        # "namespace" setting, which config: takes too); nil: the
        # platform's default (none, or the browser build's room); "": none.
        def open(locator = nil, mode: nil, listen: nil, config: nil, namespace: nil, **opts)
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
          if config.is_a?(Hash) && (config.key?("namespace") || config.key?(:namespace))
            from_config = config.key?("namespace") ? config["namespace"] : config[:namespace]
            if !namespace.nil? && namespace != from_config
              raise ArgumentError, "Session.open: namespace: and config: \"namespace\" differ"
            end
            namespace = from_config
            rest = {}
            config.each { |k, v| rest[k] = v unless k.to_s == "namespace" }
            config = rest
          end
          tls = config.nil? ? nil : tls_settings(config)
          tls = nil if tls && tls.empty?
          s = __asterism_open(locator, mode: mode, listen: listen, tls: tls, namespace: namespace)
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

module Asterism
  module Zenoh
    # A received sample, from Subscriber#each_sample: the members CRuby's
    # Sample starts with, in the same order (Sample.new(key, payload,
    # attachment) works on both). payload and attachment are Strings
    # (attachment nil when there was none); kind :put or :delete; encoding
    # the name zenoh prints ("zenoh/bytes" when the sender gave none,
    # "image/jpeg", ...); timestamp a Timestamp, or nil (zenoh only stamps
    # samples when the sender or a router does). The CRuby-only members
    # (priority, congestion_control, express, reliability, source_zid) are
    # not here.
    class Sample
      attr_reader :key, :payload, :attachment, :kind, :encoding, :timestamp

      def initialize(key, payload, attachment = nil, kind = :put, encoding = nil, timestamp = nil)
        @key = key
        @payload = payload
        @attachment = attachment
        @kind = kind
        @encoding = encoding
        @timestamp = timestamp
      end

      # The payload as text (Strings carry no encoding here).
      def text
        payload.dup
      end

      def put?
        kind == :put
      end

      def delete?
        kind == :delete
      end

      def to_h
        { key: key, payload: payload, attachment: attachment, kind: kind, encoding: encoding, timestamp: timestamp }
      end

      def deconstruct_keys(_keys)
        to_h
      end

      def ==(other)
        other.is_a?(self.class) && to_h == other.to_h
      end

      def to_s
        "#{key}: #{payload}"
      end
    end

    # A reply to a get, from Get#each_result: the members of a Sample, and
    # error (always false here: zenoh-pico's error replies are counted in
    # Get#errors, not kept) and replier_zid (nil here).
    class Reply < Sample
      def error
        false
      end

      def replier_zid
        nil
      end

      def ok?
        true
      end

      def error?
        false
      end

      def to_h
        h = super
        h[:error] = false
        h
      end
    end

    # The time zenoh put on a sample (zenoh's HLC: a router stamps what
    # passes through it, by default). ntp64: seconds since 1970 in the upper
    # 32 bits, the fraction in the lower 32. id: the Zenoh ID of the clock
    # (hex, as Session#zid).
    class Timestamp
      include Comparable

      attr_reader :ntp64, :id

      def initialize(ntp64, id)
        @ntp64 = ntp64
        @id = id
      end

      # A Time (where Time has at(seconds, microseconds)).
      def to_time
        sec = ntp64 >> 32
        usec = ((ntp64 & 0xffffffff) * 1_000_000) >> 32
        Time.at(sec, usec)
      end

      # By time, then by ID. (With < and >: mruby's Integer#<=> compares
      # through Float, which cannot tell two NTP64 times 1 apart.)
      def <=>(other)
        return nil unless other.is_a?(Timestamp)
        return -1 if ntp64 < other.ntp64
        return 1 if ntp64 > other.ntp64
        id <=> other.id
      end

      def ==(other)
        other.is_a?(Timestamp) && ntp64 == other.ntp64 && id == other.id
      end

      def hash
        [ntp64, id].hash
      end

      def eql?(other)
        self == other
      end

      def to_s
        "#{ntp64}/#{id}"
      end

      def inspect
        "#<Asterism::Zenoh::Timestamp #{self}>"
      end
    end
  end
end
