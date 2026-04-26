# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'securerandom'
require_relative 'version'
require_relative 'errors'

module TTSAi
  # Synchronous Ruby client for the TTS.ai REST API.
  #
  # Mirrors the Python (ttsai), JS (@ttsainpm/ttsai), PHP (ttsai/ttsai), and
  # Go (github.com/ttsaigit/tts-go) SDKs so cross-language porting is mechanical:
  #
  #   tts = TTSAi::Client.new('sk-tts-...')
  #   audio = tts.generate('Hello world.', voice: 'af_bella', model: 'kokoro')
  #   File.binwrite('out.mp3', audio)
  class Client
    DEFAULT_BASE_URL = 'https://api.tts.ai'
    DEFAULT_TIMEOUT  = 180
    MAX_RETRIES      = 2

    def initialize(api_key, base_url: DEFAULT_BASE_URL, timeout: DEFAULT_TIMEOUT,
                   max_retries: MAX_RETRIES, user_agent: nil)
      raise ArgumentError, 'api_key is required (use sk-tts-... or pk-tts-...)' if api_key.nil? || api_key.empty?

      @api_key = api_key
      @base_url = base_url.sub(%r{/+$}, '')
      @timeout = timeout
      @max_retries = max_retries
      @user_agent = user_agent || "tts-ruby/#{VERSION} (+https://tts.ai)"
    end

    # Synchronous generate — submits a TTS request, polls until the audio is
    # ready, downloads the file, returns the bytes.
    def generate(text, voice: 'af_bella', model: 'kokoro', format: 'mp3',
                 language: nil, speed: nil, instructions: nil,
                 pronunciations: nil, **extra)
      job = generate_async(text, voice: voice, model: model, format: format,
                           language: language, speed: speed,
                           instructions: instructions, pronunciations: pronunciations, **extra)
      result = poll_result(job['uuid'])
      raise ServerError, "tts job #{job['uuid']} completed without a result_url" if result['result_url'].nil? || result['result_url'].empty?

      fetch_url(result['result_url'])
    end

    # Submit a TTS request and return the queued job (with uuid for polling).
    def generate_async(text, voice: 'af_bella', model: 'kokoro', format: 'mp3',
                       language: nil, speed: nil, instructions: nil,
                       pronunciations: nil, **extra)
      body = { 'text' => text, 'voice' => voice, 'model' => model, 'format' => format }
      body['language'] = language if language
      body['speed'] = speed if speed
      body['instructions'] = instructions if instructions
      body['pronunciations'] = pronunciations if pronunciations && !pronunciations.empty?
      extra.each { |k, v| body[k.to_s] = v }
      json_request(:post, '/v1/tts/', body)
    end

    # Poll a job UUID until it reaches a terminal state.
    def poll_result(uuid, interval: 1.0, timeout: 600)
      deadline = Time.now + timeout
      while Time.now < deadline
        data = json_request(:get, "/v1/speech/results/?uuid=#{URI.encode_www_form_component(uuid)}")
        case data['status']
        when 'completed'
          return data
        when 'failed'
          raise ServerError.new(data['message'] || data['error'] || 'tts job failed', status_code: 500, body: data)
        end
        sleep interval
      end
      raise TimeoutError, "Job #{uuid} did not complete within #{timeout}s"
    end

    # Submit an audio file for transcription. Returns a queued job.
    def transcribe(audio_path, model: 'faster-whisper', **extra)
      raise ArgumentError, "audio file not found: #{audio_path}" unless File.exist?(audio_path)

      fields = { 'model' => model.to_s }
      extra.each { |k, v| fields[k.to_s] = v.to_s }
      multipart_request('/v1/transcribe/', fields, file: audio_path)
    end

    # Voice cloning. Returns a queued job; poll for the synthesised audio URL.
    def clone_voice(audio_path, text, model: 'chatterbox', language: nil,
                    boost: nil, **extra)
      raise ArgumentError, "reference audio not found: #{audio_path}" unless File.exist?(audio_path)

      fields = { 'text' => text, 'model' => model.to_s }
      fields['language'] = language if language
      fields['boost'] = boost.to_s if boost
      extra.each { |k, v| fields[k.to_s] = v.to_s }
      multipart_request('/v1/voice-clone/', fields, reference_audio: audio_path)
    end

    # Voice catalog. Optionally filter by model and/or language.
    def list_voices(model: nil, language: nil)
      qs = {}
      qs['model'] = model if model
      qs['language'] = language if language
      path = qs.empty? ? '/v1/voices/' : "/v1/voices/?#{URI.encode_www_form(qs)}"
      data = json_request(:get, path)
      data['voices'] || []
    end

    # Full /v1/speech/models/ payload (TTS + clone + enhance lists, plus
    # `instructions_supported_models`).
    def list_models
      json_request(:get, '/v1/speech/models/')
    end

    # SRT or VTT subtitles for a completed TTS job.
    def subtitles(uuid, format: 'srt')
      qs = URI.encode_www_form(uuid: uuid, format: format)
      json_request(:get, "/v1/speech/subtitles/?#{qs}")
    end

    private

    def json_request(method, path, body = nil)
      headers = {
        'Authorization' => "Bearer #{@api_key}",
        'User-Agent' => @user_agent,
        'Accept' => 'application/json',
      }
      payload = nil
      if body
        headers['Content-Type'] = 'application/json'
        payload = JSON.dump(body)
      end
      execute(method, path, headers, payload)
    end

    def multipart_request(path, fields, files = {})
      boundary = "----TTSAiBoundary#{SecureRandom.hex(8)}"
      headers = {
        'Authorization' => "Bearer #{@api_key}",
        'User-Agent' => @user_agent,
        'Accept' => 'application/json',
        'Content-Type' => "multipart/form-data; boundary=#{boundary}",
      }
      payload = build_multipart(fields, files, boundary)
      execute(:post, path, headers, payload)
    end

    def build_multipart(fields, files, boundary)
      io = String.new(encoding: Encoding::BINARY)
      fields.each do |k, v|
        io << "--#{boundary}\r\n"
        io << %(Content-Disposition: form-data; name="#{k}"\r\n\r\n)
        io << v.to_s
        io << "\r\n"
      end
      files.each do |name, file_path|
        filename = File.basename(file_path)
        io << "--#{boundary}\r\n"
        io << %(Content-Disposition: form-data; name="#{name}"; filename="#{filename}"\r\n)
        io << "Content-Type: application/octet-stream\r\n\r\n"
        io << File.binread(file_path)
        io << "\r\n"
      end
      io << "--#{boundary}--\r\n"
      io
    end

    def execute(method, path, headers, payload)
      uri = URI.parse(@base_url + path)
      attempt = 0
      last_error = nil
      while attempt <= @max_retries
        begin
          response = perform_request(uri, method, headers, payload)
        rescue Net::OpenTimeout, Net::ReadTimeout => e
          last_error = TimeoutError.new("Request timed out after #{@timeout}s: #{e.message}")
          attempt += 1
          break if attempt > @max_retries

          sleep(2**attempt)
          next
        rescue StandardError => e
          last_error = Error.new("Network error: #{e.message}")
          attempt += 1
          break if attempt > @max_retries

          sleep(2**attempt)
          next
        end

        if response.code.to_i.between?(200, 299)
          return response.body.empty? ? {} : JSON.parse(response.body)
        end

        if response.code.to_i >= 500 && attempt < @max_retries
          attempt += 1
          sleep(2**attempt)
          next
        end

        raise map_error(response)
      end
      raise(last_error || Error.new('Request failed'))
    end

    def perform_request(uri, method, headers, payload)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = @timeout
      http.read_timeout = @timeout

      request_class = {
        get: Net::HTTP::Get,
        post: Net::HTTP::Post,
        delete: Net::HTTP::Delete,
      }[method]
      raise ArgumentError, "unsupported method: #{method}" unless request_class

      request = request_class.new(uri.request_uri)
      headers.each { |k, v| request[k] = v }
      request.body = payload if payload
      http.request(request)
    end

    def map_error(response)
      status = response.code.to_i
      body =
        begin
          JSON.parse(response.body) if response.body && !response.body.empty?
        rescue JSON::ParserError
          nil
        end
      message = (body.is_a?(Hash) && (body['message'] || body['error'])) || response.body || "HTTP #{status}"
      case status
      when 401
        AuthenticationError.new(message, status_code: status, body: body)
      when 402
        InsufficientCreditsError.new(message, status_code: status, body: body)
      when 429
        retry_after = response['retry-after']&.to_i
        RateLimitError.new(message, status_code: status, body: body, retry_after: retry_after)
      when 400
        if body.is_a?(Hash) && body['error'] == 'invalid_model'
          ModelNotFoundError.new(message, status_code: status, body: body)
        else
          ValidationError.new(message, status_code: status, body: body)
        end
      else
        if status >= 500
          ServerError.new(message, status_code: status, body: body)
        else
          Error.new(message, status_code: status, body: body)
        end
      end
    end

    def fetch_url(url)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      response = http.get(uri.request_uri, 'User-Agent' => @user_agent)
      raise ServerError.new("Audio download failed (HTTP #{response.code})", status_code: response.code.to_i) if response.code.to_i >= 400

      response.body
    end
  end
end
