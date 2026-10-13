# Admission gate for the authenticated Assistant request boundary.
#
# Controllers call `admit_assistant_request!` after authentication,
# authorization, and (where applicable) model validation, but before persisting
# a Chat/Message or enqueuing provider work. Each accepted request is
# attributed to the authenticated user — never to request parameters — and
# counted exactly once by AssistantRequestLimiter.
#
# The default rejection response is the web shape: a retry-later flash aimed
# back at the chat surface. Api::V1::BaseController overrides both the
# attribution and the response with the JSON 429/503 envelope.
module AssistantRequestLimitable
  extend ActiveSupport::Concern

  private
    # The authenticated user this request is attributed to. Web requests use
    # the session user; the API overrides this with the token/key owner.
    def assistant_request_user
      Current.user
    end

    # Returns true when the request may proceed to provider work. On rejection
    # it renders the controller-family response and returns false, so the
    # action performs no storage mutation, enqueue, or provider call.
    def admit_assistant_request!
      result = AssistantRequestLimiter.admit(assistant_request_user)
      return true if result.allowed?

      render_assistant_request_rejection(result)
      false
    end

    # Web rejection: a clear retry-later flash. A Redis outage is reported as a
    # 503 so a caller can distinguish "try later" from their own quota, and the
    # service failure is never detailed to the client.
    def render_assistant_request_rejection(result)
      if result.reason == :unavailable
        redirect_back fallback_location: assistant_request_fallback_location,
          alert: "AI is temporarily unavailable. Please try again later.",
          status: :service_unavailable
      else
        redirect_back fallback_location: assistant_request_fallback_location,
          alert: assistant_request_limit_alert(result)
      end
    end

    def assistant_request_limit_alert(result)
      "You've reached the hourly AI request limit. Try again in #{assistant_request_retry_minutes(result)}."
    end

    def assistant_request_retry_minutes(result)
      seconds = result.retry_after.to_i
      [ (seconds / 60.0).ceil, 1 ].max
    end

    def assistant_request_fallback_location
      chats_path
    end
end
