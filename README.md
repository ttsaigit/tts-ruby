# tts-ruby

Official **Ruby SDK** for the [TTS.ai](https://tts.ai) REST API. Text-to-speech, voice cloning, transcription, voice listing — works with Rails, Sinatra, Jekyll, GitHub Pages workflows, or plain Ruby.

```ruby
require 'ttsai'

tts = TTSAi::Client.new(ENV.fetch('TTSAI_API_KEY'))
audio = tts.generate('Hello world.', voice: 'af_bella', model: 'kokoro')
File.binwrite('out.mp3', audio)
```

## Install

```bash
gem install ttsai
```

Or add to your Gemfile:

```ruby
gem 'ttsai'
```

Requires Ruby 3.0+. **No runtime gem dependencies** — uses only `net/http`, `json`, `uri`, and `securerandom` from the standard library.

## Get an API key

Sign up at [tts.ai/account/#api-keys](https://tts.ai/account/#api-keys). Use:
- **`sk-tts-...`** secret keys server-side (this SDK)
- **`pk-tts-...`** publishable keys for browser embeds (use [`narrator.js`](https://github.com/ttsaigit/narrator-js))

## Methods

```ruby
# Synchronous generate (queues + polls until audio is ready)
audio = tts.generate(text,
  voice:          'af_bella',
  model:          'kokoro',
  format:         'mp3',                  # mp3 | wav | flac | ogg
  language:       'en',                   # ISO code; auto-detect if nil
  speed:          1.0,                    # 0.5..2.0
  instructions:   'say it sarcastically', # qwen3-tts only
  pronunciations: { 'GIF' => 'jiff' },
  exaggeration:   0.7                     # any extra kwarg → forwarded to GPU
)

# Async — returns {'uuid' => '...', ...}, poll yourself
job = tts.generate_async(text, voice: 'af_bella')
result = tts.poll_result(job['uuid'], interval: 1.0, timeout: 600)

# Transcription
job = tts.transcribe('/path/to/audio.mp3', model: 'faster-whisper')
result = tts.poll_result(job['uuid'])

# Voice cloning — server smart-trims long reference audio automatically
job = tts.clone_voice('/path/to/reference.wav', 'Read this in their voice.',
                      model: 'chatterbox', boost: 0.7)

# Catalog
voices = tts.list_voices(model: 'kokoro', language: 'en')
models = tts.list_models

# Subtitles for a completed job
srt = tts.subtitles(job['uuid'], format: 'srt')   # or 'vtt'
```

## Errors

```ruby
begin
  audio = tts.generate(text)
rescue TTSAi::InsufficientCreditsError => e
  puts "Need #{e.credits_needed}; have #{e.credits_remaining}"
rescue TTSAi::RateLimitError => e
  sleep e.retry_after || 30
  retry
rescue TTSAi::AuthenticationError
  # bad API key
rescue TTSAi::ValidationError => e
  # 400 — read e.body for upgrade hints (max_length, cta_url, etc.)
rescue TTSAi::ServerError
  # 5xx after retries
end
```

All exceptions inherit from `TTSAi::Error` and expose `status_code`, `error_code`, and `body` for the parsed JSON response.

## Rails example

```ruby
# config/initializers/ttsai.rb
TTSAI_CLIENT = TTSAi::Client.new(Rails.application.credentials.ttsai_api_key)

# app/controllers/speak_controller.rb
class SpeakController < ApplicationController
  def show
    audio = TTSAI_CLIENT.generate(params[:text], voice: 'af_bella')
    send_data audio, type: 'audio/mpeg', disposition: 'inline'
  end
end
```

## Jekyll / Sites Generator example

```ruby
# Convert all blog posts to audio at build time, write *.mp3 alongside *.md
require 'ttsai'

tts = TTSAi::Client.new(ENV.fetch('TTSAI_API_KEY'))
Dir.glob('_posts/*.md').each do |post|
  next if File.exist?(post.sub('.md', '.mp3'))

  text = File.read(post).split("---\n", 3).last  # strip front-matter
  File.binwrite(post.sub('.md', '.mp3'), tts.generate(text))
end
```

## Configuration

```ruby
tts = TTSAi::Client.new('sk-tts-...',
  base_url:    'https://api.tts.ai',     # override for self-hosted
  timeout:     180,                       # seconds
  max_retries: 2,                         # retries on 5xx + connection errors
  user_agent:  'my-app/1.0'
)
```

## Sister SDKs

- Python: [`pip install ttsai`](https://pypi.org/project/ttsai/)
- JavaScript / Node: [`npm install @ttsainpm/ttsai`](https://www.npmjs.com/package/@ttsainpm/ttsai)
- PHP: [`composer require ttsai/ttsai`](https://github.com/ttsaigit/tts-php)
- Go: [`go get github.com/ttsaigit/tts-go`](https://github.com/ttsaigit/tts-go)
- Browser embeds: [`narrator.js`](https://github.com/ttsaigit/narrator-js), [`tts-widget`](https://github.com/ttsaigit/tts-widget)

All five expose the same methods + return shapes so porting between languages is mechanical.

## License

Apache-2.0. See `LICENSE`.
