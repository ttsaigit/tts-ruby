# frozen_string_literal: true

module TTSAi
  # Base error for all TTS.ai SDK exceptions. The `body` attribute carries the
  # parsed JSON response so callers can read structured fields
  # (credits_needed, credits_remaining, max_length, upgrade.cta_url, etc.).
  class Error < StandardError
    attr_reader :status_code, :body, :error_code

    def initialize(message, status_code: nil, body: nil)
      super(message)
      @status_code = status_code
      @body = body
      @error_code = body.is_a?(Hash) ? body['error'] : nil
    end
  end

  class AuthenticationError < Error; end

  class RateLimitError < Error
    attr_reader :retry_after

    def initialize(message, status_code: 429, body: nil, retry_after: nil)
      super(message, status_code: status_code, body: body)
      @retry_after = retry_after
    end
  end

  class InsufficientCreditsError < Error
    def credits_needed
      body.is_a?(Hash) ? body['credits_needed'] : nil
    end

    def credits_remaining
      body.is_a?(Hash) ? body['credits_remaining'] : nil
    end
  end

  class ModelNotFoundError < Error; end
  class ValidationError < Error; end
  class ServerError < Error; end
  class TimeoutError < Error; end
end
