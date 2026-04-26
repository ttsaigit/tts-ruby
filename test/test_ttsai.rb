# frozen_string_literal: true

require 'minitest/autorun'
require 'webrick'
require 'json'
require 'ttsai'

# Tiny stub server for testing without hitting api.tts.ai. Spins up on a
# random port, takes a hash of `path → handler` blocks, exposes `.base_url`.
class StubServer
  attr_reader :base_url, :requests

  def initialize(handlers)
    @handlers = handlers
    @requests = []
    @server = WEBrick::HTTPServer.new(
      Port: 0, Logger: WEBrick::Log.new(File.open(File::NULL, 'w'), 0),
      AccessLog: []
    )
    @handlers.each do |path, handler|
      @server.mount_proc(path) do |req, res|
        @requests << { path: req.path, method: req.request_method, body: req.body, headers: req.header }
        handler.call(req, res)
      end
    end
    @thread = Thread.new { @server.start }
    @base_url = "http://127.0.0.1:#{@server.config[:Port]}"
  end

  def stop
    @server.shutdown
    @thread.join
  end
end


class TestClientConstruction < Minitest::Test
  def test_requires_api_key
    assert_raises(ArgumentError) { TTSAi::Client.new('') }
    assert_raises(ArgumentError) { TTSAi::Client.new(nil) }
  end

  def test_strips_trailing_slash_from_base_url
    c = TTSAi::Client.new('sk-tts-test', base_url: 'https://example.com///')
    # Verify via a successful request
    server = StubServer.new(
      '/v1/speech/models/' => ->(_req, res) { res.body = '{}'; res['content-type'] = 'application/json' }
    )
    c2 = TTSAi::Client.new('sk-tts-test', base_url: server.base_url + '/')
    assert_equal({}, c2.list_models)
  ensure
    server&.stop
  end
end


class TestErrorMapping < Minitest::Test
  def test_error_carries_body_and_code
    e = TTSAi::Error.new('msg', status_code: 429, body: { 'error' => 'rate_limit_exceeded' })
    assert_equal 429, e.status_code
    assert_equal 'rate_limit_exceeded', e.error_code
  end

  def test_insufficient_credits_extracts_counts
    e = TTSAi::InsufficientCreditsError.new('need credits',
                                             status_code: 402,
                                             body: { 'credits_needed' => 5000, 'credits_remaining' => 100 })
    assert_equal 5000, e.credits_needed
    assert_equal 100, e.credits_remaining
  end

  def test_rate_limit_stores_retry_after
    e = TTSAi::RateLimitError.new('slow', retry_after: 30)
    assert_equal 30, e.retry_after
  end
end


class TestRequestPaths < Minitest::Test
  def setup
    @server = StubServer.new(
      '/v1/tts/' => ->(req, res) {
        @last_post_body = req.body
        @last_auth = req.header['authorization']&.first
        res['content-type'] = 'application/json'
        res.body = '{"uuid":"abc","status":"queued"}'
      },
      '/v1/speech/results/' => ->(_req, res) {
        res['content-type'] = 'application/json'
        res.body = '{"uuid":"abc","status":"completed","result_url":"https://cdn/test.wav"}'
      },
      '/v1/voices/' => ->(_req, res) {
        res['content-type'] = 'application/json'
        res.body = '{"voices":[{"id":"af_bella","language":"en"}],"total":1}'
      },
      '/v1/speech/models/' => ->(_req, res) {
        res['content-type'] = 'application/json'
        res.body = '{"tts_models":[],"instructions_supported_models":["qwen3-tts"]}'
      },
      '/v1/speech/subtitles/' => ->(_req, res) {
        res['content-type'] = 'application/json'
        res.body = '{"format":"srt","content":"1\\n00:00:00,000 --> 00:00:01,000\\nhi\\n"}'
      },
    )
    @client = TTSAi::Client.new('sk-tts-test', base_url: @server.base_url)
  end

  def teardown
    @server&.stop
  end

  def test_generate_async_posts_expected_body
    job = @client.generate_async('hi', voice: 'af_bella', model: 'kokoro')
    assert_equal 'abc', job['uuid']
    body = JSON.parse(@last_post_body)
    assert_equal 'hi', body['text']
    assert_equal 'af_bella', body['voice']
    assert_equal 'Bearer sk-tts-test', @last_auth
  end

  def test_poll_result_returns_completed
    res = @client.poll_result('abc', interval: 0.05, timeout: 2)
    assert_equal 'completed', res['status']
    assert_equal 'https://cdn/test.wav', res['result_url']
  end

  def test_list_voices_returns_array
    voices = @client.list_voices
    assert_equal 1, voices.size
    assert_equal 'af_bella', voices.first['id']
  end

  def test_list_models_returns_full_payload
    payload = @client.list_models
    assert_includes payload['instructions_supported_models'], 'qwen3-tts'
  end

  def test_subtitles_query_string
    res = @client.subtitles('uuid', format: 'srt')
    assert_equal 'srt', res['format']
    last = @server.requests.find { |r| r[:path] == '/v1/speech/subtitles/' }
    refute_nil last
  end
end


class TestErrorResponses < Minitest::Test
  def test_402_raises_insufficient_credits
    server = StubServer.new(
      '/v1/tts/' => ->(_req, res) {
        res.status = 402
        res['content-type'] = 'application/json'
        res.body = '{"error":"insufficient_credits","message":"need 5000","credits_needed":5000,"credits_remaining":100}'
      }
    )
    client = TTSAi::Client.new('sk', base_url: server.base_url)
    err = assert_raises(TTSAi::InsufficientCreditsError) do
      client.generate_async('hi')
    end
    assert_equal 5000, err.credits_needed
    assert_equal 100, err.credits_remaining
  ensure
    server&.stop
  end

  def test_429_raises_rate_limit
    server = StubServer.new(
      '/v1/tts/' => ->(_req, res) {
        res.status = 429
        res['retry-after'] = '30'
        res['content-type'] = 'application/json'
        res.body = '{"error":"rate_limit_exceeded","message":"slow"}'
      }
    )
    client = TTSAi::Client.new('sk', base_url: server.base_url, max_retries: 0)
    err = assert_raises(TTSAi::RateLimitError) do
      client.generate_async('hi')
    end
    assert_equal 30, err.retry_after
  ensure
    server&.stop
  end

  def test_401_raises_authentication
    server = StubServer.new(
      '/v1/tts/' => ->(_req, res) {
        res.status = 401
        res['content-type'] = 'application/json'
        res.body = '{"error":"unauthorized","message":"bad key"}'
      }
    )
    client = TTSAi::Client.new('sk-bad', base_url: server.base_url, max_retries: 0)
    assert_raises(TTSAi::AuthenticationError) do
      client.generate_async('hi')
    end
  ensure
    server&.stop
  end
end
