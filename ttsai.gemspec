# frozen_string_literal: true

require_relative 'lib/ttsai/version'

Gem::Specification.new do |spec|
  spec.name = 'ttsai'
  spec.version = TTSAi::VERSION
  spec.authors = ['TTS.ai']
  spec.email = ['hello@tts.ai']

  spec.summary = 'Official Ruby SDK for the TTS.ai REST API'
  spec.description = 'Text-to-speech, voice cloning, transcription, voice listing — works with Rails, Sinatra, Jekyll, or plain Ruby. Mirrors the Python/JS/PHP/Go SDK method shapes.'
  spec.homepage = 'https://tts.ai'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.0.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/ttsaigit/tts-ruby'
  spec.metadata['changelog_uri'] = 'https://github.com/ttsaigit/tts-ruby/releases'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/ttsaigit/tts-ruby/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*', 'README.md', 'LICENSE']
  spec.require_paths = ['lib']

  # Uses only stdlib — no runtime gem dependencies.
  spec.add_development_dependency 'minitest', '~> 5.20'
  spec.add_development_dependency 'rake', '~> 13.0'
  # WEBrick was removed from stdlib in Ruby 3.0+; we use it in tests for a
  # local stub server. Test-only — runtime SDK doesn't need it.
  spec.add_development_dependency 'webrick', '~> 1.8'
end
