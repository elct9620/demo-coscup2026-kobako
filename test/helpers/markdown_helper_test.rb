# frozen_string_literal: true

require "test_helper"

# Tests for MarkdownHelper — the sanitized Markdown pipeline the generation log
# renders through.  The load-bearing cases are the XSS ones: log content is
# LLM-authored and crosses into the page as HTML, so the sanitize layer must
# neutralise it independently of the renderer's own escaping.
class MarkdownHelperTest < ActionView::TestCase
  test "renders inline emphasis as HTML" do
    assert_includes render_markdown("Here is **bold** text."), "<strong>bold</strong>"
  end

  test "syntax-highlights a fenced ruby block with class-based Rouge markup" do
    html = render_markdown("```ruby\nEvent.count\n```")

    assert_includes html, '<pre class="code-block">'
    assert_match(/<span class="[a-z]+">/, html) # Rouge tokenised the code
    assert_match(/Event/, html)
  end

  test "escapes raw HTML in the source rather than emitting it" do
    html = render_markdown("<script>alert('xss')</script>")

    assert_not_includes html, "<script>"
  end

  test "strips javascript: link protocols" do
    html = render_markdown("[click](javascript:alert(1))")

    assert_not_includes html, "javascript:"
  end

  test "blank source renders nothing" do
    assert_equal "", render_markdown("")
    assert_equal "", render_markdown(nil)
  end

  test "highlight_code wraps a standalone script in the shared code-block markup" do
    html = highlight_code("Event.count")

    assert_includes html, '<pre class="code-block">'
    assert_match(/<span class="[a-z]+">/, html) # Rouge tokenised the script
    assert_match(/Event/, html)
  end

  test "highlight_code renders nothing for blank input" do
    assert_equal "", highlight_code("")
    assert_equal "", highlight_code(nil)
  end

  # The endpoint script is LLM-authored and re-enters as HTML output, so this
  # path needs the same XSS guarantee as render_markdown.
  test "highlight_code neutralises HTML injected through the script" do
    html = highlight_code("`</code><script>alert('xss')</script>`")

    assert_not_includes html, "<script>"
  end
end
