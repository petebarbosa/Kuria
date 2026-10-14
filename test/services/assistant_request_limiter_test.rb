require "test_helper"

class AssistantRequestLimiterTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @other_user = users(:family_member)
    @redis = Redis.new
    @redis.del(AssistantRequestLimiter.redis_key_for(@user))
    @redis.del(AssistantRequestLimiter.redis_key_for(@other_user))
  end

  teardown do
    @redis.del(AssistantRequestLimiter.redis_key_for(@user))
    @redis.del(AssistantRequestLimiter.redis_key_for(@other_user))
  end

  # Builds a limiter sharing the test Redis connection, with an explicit limit
  # so boundary behavior is deterministic and fast.
  def limiter(limit: 100)
    AssistantRequestLimiter.new(redis: @redis, limit: limit)
  end

  test "returns admission metadata for an accepted request" do
    result = limiter(limit: 4).admit(@user)

    assert result.allowed?
    assert_nil result.reason
    assert_equal 4, result.limit
    assert_equal 3, result.remaining
    assert result.retry_after.positive?
    assert result.retry_after <= AssistantRequestLimiter::WINDOW_SECONDS
    assert_kind_of Time, result.reset_at
  end

  test "allows requests up to the limit and rejects the next" do
    subject = limiter(limit: 3)

    3.times { assert subject.admit(@user).allowed? }

    rejected = subject.admit(@user)
    assert_not rejected.allowed?
    assert_equal :limit_exceeded, rejected.reason
    assert_equal 3, rejected.limit
    assert_equal 0, rejected.remaining
    assert rejected.retry_after.positive?
  end

  test "counts down remaining requests as they are admitted" do
    subject = limiter(limit: 3)

    assert_equal 2, subject.admit(@user).remaining
    assert_equal 1, subject.admit(@user).remaining
    assert_equal 0, subject.admit(@user).remaining
    assert_equal 0, subject.admit(@user).remaining
  end

  test "rejected requests do not increment the accepted count" do
    subject = limiter(limit: 2)
    key = AssistantRequestLimiter.redis_key_for(@user)

    2.times { subject.admit(@user) }
    5.times { subject.admit(@user) }

    assert_equal "2", @redis.get(key)
  end

  test "limits are isolated per user" do
    subject = limiter(limit: 2)

    2.times { assert subject.admit(@user).allowed? }
    assert_not subject.admit(@user).allowed?

    other_result = subject.admit(@other_user)
    assert other_result.allowed?
    assert_equal 1, other_result.remaining
  end

  test "sets an expiration on the counter that later admissions do not extend" do
    subject = limiter(limit: 5)
    key = AssistantRequestLimiter.redis_key_for(@user)

    subject.admit(@user)
    first_ttl = @redis.ttl(key)
    assert first_ttl.positive?
    assert first_ttl <= AssistantRequestLimiter::WINDOW_SECONDS

    3.times { subject.admit(@user) }
    later_ttl = @redis.ttl(key)
    assert later_ttl.positive?
    assert_operator later_ttl, :<=, first_ttl
  end

  test "reset_at and retry_after agree" do
    subject = limiter(limit: 1)
    subject.admit(@user)

    rejected = subject.admit(@user)

    assert_in_delta Time.current + rejected.retry_after, rejected.reset_at, 1.5
    assert_equal @redis.ttl(AssistantRequestLimiter.redis_key_for(@user)), rejected.retry_after
  end

  test "window expiry resets the admission" do
    subject = limiter(limit: 1)
    key = AssistantRequestLimiter.redis_key_for(@user)

    assert subject.admit(@user).allowed?
    assert_not subject.admit(@user).allowed?

    # Simulate the TTL elapsing.
    @redis.del(key)

    assert subject.admit(@user).allowed?
  end

  test "admits exactly the limit under concurrent access" do
    subject = limiter(limit: 10)

    results = Array.new(50) do
      Thread.new { subject.admit(@user).allowed? }
    end.map(&:value)

    assert_equal 10, results.count(true)
    assert_equal 40, results.count(false)
    assert_equal 10, @redis.get(AssistantRequestLimiter.redis_key_for(@user)).to_i
  end

  test "requires a user" do
    assert_raises(ArgumentError) { limiter(limit: 1).admit(nil) }
  end

  test "defaults to 100 requests per hour" do
    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: nil do
      assert_equal 100, AssistantRequestLimiter.configured_limit
    end
  end

  test "reads a positive configured limit" do
    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "5" do
      assert_equal 5, AssistantRequestLimiter.configured_limit
    end
  end

  test "treats blank configuration as the default" do
    [ nil, "", "   " ].each do |blank|
      with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: blank do
        assert_equal 100, AssistantRequestLimiter.configured_limit
      end
    end
  end

  test "rejects invalid configuration instead of degrading to unlimited" do
    [ "0", "-1", "abc", "1.5", "1e3" ].each do |invalid|
      with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: invalid do
        assert_raises(AssistantRequestLimiter::ConfigurationError) do
          AssistantRequestLimiter.configured_limit
        end
      end
    end
  end

  test "enforces the configured limit in managed mode" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)

    with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "2" do
      subject = AssistantRequestLimiter.new(redis: @redis)

      2.times { assert subject.admit(@user).allowed? }
      assert_not subject.admit(@user).allowed?
    end
  end

  test "enforces the configured limit in self-hosted mode" do
    with_self_hosting do
      with_env_overrides ASSISTANT_REQUESTS_PER_HOUR: "2" do
        subject = AssistantRequestLimiter.new(redis: @redis)

        2.times { assert subject.admit(@user).allowed? }
        assert_not subject.admit(@user).allowed?
      end
    end
  end

  test "fails closed when Redis is unavailable" do
    failing = Redis.new
    failing.stubs(:eval).raises(Redis::CannotConnectError.new("connection refused"))

    result = AssistantRequestLimiter.new(redis: failing, limit: 5).admit(@user)

    assert_not result.allowed?
    assert_equal :unavailable, result.reason
    assert_equal 5, result.limit
    assert_equal 0, result.remaining
  end

  test "outage results do not expose connection details" do
    failing = Redis.new
    failing.stubs(:eval).raises(Redis::CannotConnectError.new("connection refused"))

    result = AssistantRequestLimiter.new(redis: failing, limit: 5).admit(@user)

    assert_no_match(/redis:\/\//, result.inspect)
  end

  test "class level admit returns the same result shape" do
    result = AssistantRequestLimiter.admit(@user, redis: @redis, limit: 2)

    assert_respond_to result, :allowed?
    assert_equal 2, result.limit
  end

  test "preflight allows a request within the allowance without consuming it" do
    subject = limiter(limit: 3)

    result = subject.check(@user)

    assert result.allowed?
    assert_nil result.reason
    assert_equal 3, result.limit
    assert_equal 3, result.remaining
    assert_nil @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "preflight does not consume the allowance on repeated calls" do
    subject = limiter(limit: 2)

    5.times { assert subject.check(@user).allowed? }

    assert_nil @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "preflight reports the remaining allowance without changing it" do
    subject = limiter(limit: 3)
    2.times { subject.admit(@user) }

    result = subject.check(@user)

    assert result.allowed?
    assert_equal 1, result.remaining
    assert_equal "2", @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "preflight rejects once the allowance is exhausted without incrementing" do
    subject = limiter(limit: 2)
    2.times { subject.admit(@user) }

    rejected = subject.check(@user)

    assert_not rejected.allowed?
    assert_equal :limit_exceeded, rejected.reason
    assert_equal 0, rejected.remaining
    assert rejected.retry_after.positive?
    assert_equal "2", @redis.get(AssistantRequestLimiter.redis_key_for(@user))
  end

  test "preflight is isolated per user" do
    subject = limiter(limit: 1)
    subject.admit(@user)

    assert_not subject.check(@user).allowed?
    assert subject.check(@other_user).allowed?
  end

  test "preflight fails closed when Redis is unavailable" do
    failing = Redis.new
    failing.stubs(:get).raises(Redis::CannotConnectError.new("connection refused"))

    result = AssistantRequestLimiter.new(redis: failing, limit: 5).check(@user)

    assert_not result.allowed?
    assert_equal :unavailable, result.reason
    assert_equal 5, result.limit
  end

  test "class level check returns the same result shape" do
    result = AssistantRequestLimiter.check(@user, redis: @redis, limit: 2)

    assert_respond_to result, :allowed?
    assert_equal 2, result.limit
  end

  test "requires a user for preflight" do
    assert_raises(ArgumentError) { limiter(limit: 1).check(nil) }
  end
end
