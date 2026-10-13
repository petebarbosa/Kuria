class AssistantRequestLimiter
  # Raised when ASSISTANT_REQUESTS_PER_HOUR is present but not a positive
  # integer. Invalid configuration fails loudly rather than degrading to an
  # unlimited allowance by accident.
  class ConfigurationError < StandardError; end

  # Explicit, enforced default for every deployment mode (managed and
  # self-hosted). Overridable with ASSISTANT_REQUESTS_PER_HOUR.
  DEFAULT_HOURLY_LIMIT = 100

  # Fixed one-hour window, in seconds.
  WINDOW_SECONDS = 1.hour.to_i

  CONFIG_KEY = "ASSISTANT_REQUESTS_PER_HOUR"

  # Single atomic admission: either the request is counted and accepted, or it
  # is rejected without touching the accepted count. KEYS[1] is the per-user
  # counter, ARGV[1] the limit, ARGV[2] the window in seconds.
  ADMISSION_SCRIPT = <<~LUA
    local current = tonumber(redis.call("GET", KEYS[1]) or "0")
    local limit = tonumber(ARGV[1])
    if current >= limit then
      local ttl = redis.call("TTL", KEYS[1])
      if ttl < 0 then ttl = tonumber(ARGV[2]) end
      return { 0, current, ttl }
    end
    local count = redis.call("INCR", KEYS[1])
    if count == 1 then
      redis.call("EXPIRE", KEYS[1], ARGV[2])
    end
    local ttl = redis.call("TTL", KEYS[1])
    if ttl < 0 then ttl = tonumber(ARGV[2]) end
    return { 1, count, ttl }
  LUA

  # Outcome of an admission attempt.
  #   allowed?     - whether the request may proceed to provider work
  #   limit        - configured hourly allowance
  #   remaining    - requests left in the current window (0 once at the limit)
  #   retry_after  - seconds until the window resets, or nil when unavailable
  #   reset_at     - Time the window resets, or nil when unavailable
  #   reason       - nil when allowed, :limit_exceeded or :unavailable otherwise
  Result = Data.define(:allowed, :limit, :remaining, :retry_after, :reset_at, :reason) do
    def allowed?
      allowed
    end
  end

  def self.admit(user, redis: nil, limit: nil)
    new(redis: redis, limit: limit).admit(user)
  end

  def self.configured_limit
    raw = ENV[CONFIG_KEY]
    return DEFAULT_HOURLY_LIMIT if raw.nil? || raw.strip.empty?

    value = begin
      Integer(raw.strip, 10)
    rescue ArgumentError
      nil
    end

    unless value&.positive?
      raise ConfigurationError, "#{CONFIG_KEY} must be a positive integer"
    end

    value
  end

  def self.redis_key_for(user)
    "assistant_request_limit:#{user.id}"
  end

  def initialize(redis: nil, limit: nil)
    @redis = redis
    @limit = limit
  end

  def admit(user)
    raise ArgumentError, "a user is required" if user.nil?

    window_limit = limit
    allowed, count, ttl = redis.eval(
      ADMISSION_SCRIPT,
      keys: [ self.class.redis_key_for(user) ],
      argv: [ window_limit, WINDOW_SECONDS ]
    )

    accepted = allowed.to_i == 1
    ttl = ttl.to_i

    Result.new(
      allowed: accepted,
      limit: window_limit,
      remaining: accepted ? [ window_limit - count.to_i, 0 ].max : 0,
      retry_after: ttl,
      reset_at: Time.current + ttl,
      reason: accepted ? nil : :limit_exceeded
    )
  rescue Redis::BaseError => e
    # Fail closed: a Redis outage must never widen the allowance. Log only the
    # error class so no connection details or credentials reach the logs.
    Rails.logger.warn("[AssistantRequestLimiter] Redis unavailable (#{e.class}); failing closed")
    unavailable_result
  end

  private
    def redis
      @redis ||= Redis.new
    end

    def limit
      @limit ||= self.class.configured_limit
    end

    def unavailable_result
      Result.new(
        allowed: false,
        limit: limit,
        remaining: 0,
        retry_after: nil,
        reset_at: nil,
        reason: :unavailable
      )
    end
end
