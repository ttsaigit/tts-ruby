# frozen_string_literal: true

require_relative 'ttsai/version'
require_relative 'ttsai/errors'
require_relative 'ttsai/client'

# TTS.ai Ruby SDK.
#
#   tts = TTSAi::Client.new(ENV.fetch('TTSAI_API_KEY'))
#   File.binwrite('out.mp3', tts.generate('Hello world.'))
#
# See https://github.com/ttsaigit/tts-ruby for full docs.
module TTSAi
end
