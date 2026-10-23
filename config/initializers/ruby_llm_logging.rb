# RubyLLM's debug and stream-debug output includes prompts, request and
# response bodies, tool results and completed assistant text, and its warn and
# error paths can include provider error bodies and backtraces. Kuria's
# assistant traffic carries user prompts and financial data, so the gem's
# global logger emits a fixed label and severity only: no message, progname,
# payload or exception text ever reaches the log stream.
#
# The formatter is installed on the logger instance RubyLLM caches at boot.
# RubyLLM.logger memoizes its logger, so a later `RubyLLM.config.logger`
# assignment cannot reroute gem output around this sanitizer.
module RubyLlmLogging
  LABEL = "RubyLLM"

  def self.call(severity, _time, _progname, _message)
    "[#{LABEL}] #{severity}\n"
  end
end

RubyLLM.logger.formatter = RubyLlmLogging
