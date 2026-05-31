# frozen_string_literal: true

# Renders the generation log's Markdown to sanitized, display-safe HTML.
#
# The log content originates from the LLM, so it crosses a trust boundary into
# the page.  Two independent layers neutralise it: the Markdown renderer escapes
# raw HTML at the source (escape_html), and Rails' allowlist sanitizer scrubs the
# rendered output again — including unsafe link protocols — before it is marked
# html_safe.  Either layer stands on its own.
module MarkdownHelper
  # One shared renderer.  fenced_code_blocks turns the presenter's ```ruby
  # fences into shaded blocks, which HighlightHtmlRenderer then syntax-colours.
  MARKDOWN = Redcarpet::Markdown.new(
    HighlightHtmlRenderer.new(escape_html: true, hard_wrap: true),
    fenced_code_blocks: true,
    tables: true,
    autolink: true,
    strikethrough: true,
    no_intra_emphasis: true
  )

  # Render one log Message through the shared Markdown pipeline.
  def markdown_log_entry(message)
    render_markdown(LogEntryPresenter.new(message).to_markdown)
  end

  # Render a Markdown string as sanitized, display-safe HTML.  Rails' default
  # allowlist already keeps Rouge's <span class="…"> token markup while
  # stripping anything executable and unsafe link protocols.
  def render_markdown(source)
    return "".html_safe if source.blank?

    sanitize(MARKDOWN.render(source))
  end
end
