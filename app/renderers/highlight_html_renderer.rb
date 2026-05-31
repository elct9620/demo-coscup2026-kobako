# frozen_string_literal: true

# Redcarpet HTML renderer that syntax-highlights fenced code blocks with Rouge.
#
# Rouge emits CLASS-based markup (`<span class="k">…`), not inline styles, for
# two deliberate reasons: the colours live in the design system's stylesheet
# (.log-prose in app/assets/tailwind/application.css, mapped to the Japanese
# traditional palette) rather than being hard-coded here, and — because Rails'
# sanitizer strips `style` attributes but keeps `class` — class markup is the
# form that survives the generation log's sanitize pass.
#
# Everything else (prose, lists, links) falls through to the stock HTML renderer,
# whose escape_html option neutralises raw HTML in the LLM-authored source.
class HighlightHtmlRenderer < Redcarpet::Render::HTML
  # Highlight +code+ as +language+ into a code-block <pre>.  Shared by Markdown
  # fenced blocks (#block_code) and any standalone code on the page — e.g. the
  # generated endpoint script (MarkdownHelper#highlight_code) — so both render
  # identically through Rouge's class-based markup.
  def self.highlight(code, language)
    lexer = Rouge::Lexer.find(language.to_s) || Rouge::Lexers::PlainText
    inner = Rouge::Formatters::HTML.new.format(lexer.lex(code.to_s))

    %(<pre class="code-block"><code class="highlight">#{inner}</code></pre>)
  end

  def block_code(code, language)
    self.class.highlight(code, language)
  end
end
