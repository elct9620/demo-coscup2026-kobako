# frozen_string_literal: true

# Presents one generation-log Message as a Markdown source string, so the whole
# log — assistant prose, tool calls, and sandbox results — flows through a single
# Markdown pipeline and shares one consistent look.
#
# Routing by role / shape:
#   - tool call (the agent's input)  → each script fenced as a ```ruby block
#   - tool result (sandbox return)   → the returned value fenced as a ```ruby block
#   - assistant prose                → the content verbatim (already Markdown)
#
# Code-ish turns are fenced so the renderer gives them the shaded code-block
# treatment that, until now, only the tool input had — this is what unifies the
# log's appearance.  Results are shown as Ruby rather than pseudo-JSON because
# that is what the mruby sandbox actually returns (display-only; the tools keep
# returning their structured Hash, see InspectQueryTool / SubmitEndpointTool).
class LogEntryPresenter
  EMPTY = "(empty)"

  def initialize(message)
    @message = message
  end

  # @return [String] Markdown source for this log entry
  def to_markdown
    return tool_calls_markdown if tool_call?
    return fenced_ruby(content) if tool_result?

    content
  end

  private

  def tool_call?
    @message.to_llm.tool_call?
  end

  def tool_result?
    @message.role.to_s == "tool"
  end

  def content
    @message.content.presence || EMPTY
  end

  # Mirror the historical partial: prefer the clean :script argument, falling
  # back to the raw arguments JSON when a tool has no script (string- or
  # symbol-keyed arguments both resolve via with_indifferent_access).
  def tool_calls_markdown
    @message.tool_calls.map { |tc| fenced_ruby(script_of(tc)) }.join("\n\n")
  end

  def script_of(tool_call)
    tool_call.arguments.with_indifferent_access[:script] || tool_call.arguments.to_json
  end

  def fenced_ruby(code)
    "```ruby\n#{code}\n```"
  end
end
