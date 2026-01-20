defmodule PureHTML.QueryTest do
  use ExUnit.Case, async: true

  alias PureHTML.Query

  describe "find/2" do
    test "finds elements by tag" do
      html = PureHTML.parse("<div><p>Hello</p><p>World</p></div>")

      assert Query.find(html, "p") == [
               {"p", [], ["Hello"]},
               {"p", [], ["World"]}
             ]
    end

    test "finds elements by class" do
      html = PureHTML.parse("<div><p class='intro'>Hello</p><p>World</p></div>")

      assert Query.find(html, ".intro") == [{"p", [{"class", "intro"}], ["Hello"]}]
    end

    test "finds elements by id" do
      html = PureHTML.parse("<div><p id='greeting'>Hello</p></div>")

      assert Query.find(html, "#greeting") == [{"p", [{"id", "greeting"}], ["Hello"]}]
    end

    test "finds elements by compound selector" do
      html =
        PureHTML.parse(
          "<div><p class='intro' id='greeting'>Hello</p><p class='intro'>World</p></div>"
        )

      assert Query.find(html, "p.intro#greeting") == [
               {"p", [{"class", "intro"}, {"id", "greeting"}], ["Hello"]}
             ]
    end

    test "finds elements by attribute existence" do
      html = PureHTML.parse("<div><a href='/link'>Link</a><span>Text</span></div>")

      assert Query.find(html, "[href]") == [{"a", [{"href", "/link"}], ["Link"]}]
    end

    test "finds elements by attribute value" do
      html = PureHTML.parse("<input type='text'><input type='password'>")

      assert Query.find(html, "[type=text]") == [{"input", [{"type", "text"}], []}]
    end

    test "finds elements by attribute prefix" do
      html =
        PureHTML.parse(
          "<a href='https://example.com'>Secure</a><a href='http://test.com'>Insecure</a>"
        )

      assert Query.find(html, "[href^=https]") == [
               {"a", [{"href", "https://example.com"}], ["Secure"]}
             ]
    end

    test "finds elements by attribute suffix" do
      html = PureHTML.parse("<a href='doc.pdf'>PDF</a><a href='doc.txt'>Text</a>")

      assert Query.find(html, "[href$=.pdf]") == [{"a", [{"href", "doc.pdf"}], ["PDF"]}]
    end

    test "finds elements by attribute substring" do
      html =
        PureHTML.parse(
          "<a href='https://example.com'>Example</a><a href='https://test.com'>Test</a>"
        )

      assert Query.find(html, "[href*=example]") == [
               {"a", [{"href", "https://example.com"}], ["Example"]}
             ]
    end

    test "finds elements with selector list" do
      html = PureHTML.parse("<div><p>Para</p><span>Span</span><a>Link</a></div>")

      assert Query.find(html, "p, span") == [
               {"p", [], ["Para"]},
               {"span", [], ["Span"]}
             ]
    end

    test "finds nested elements" do
      html = PureHTML.parse("<div><div><p class='deep'>Deep</p></div></div>")

      assert Query.find(html, ".deep") == [{"p", [{"class", "deep"}], ["Deep"]}]
    end

    test "returns empty list when no matches" do
      html = PureHTML.parse("<div><p>Hello</p></div>")

      assert Query.find(html, ".nonexistent") == []
    end

    test "works with single node input" do
      node = {"div", [], [{"p", [{"class", "inner"}], ["Hello"]}]}

      assert Query.find(node, ".inner") == [{"p", [{"class", "inner"}], ["Hello"]}]
    end

    test "finds universal selector" do
      html = [{"div", [], [{"p", [], ["Hello"]}]}]

      # Should find div and p
      assert Query.find(html, "*") == [
               {"div", [], [{"p", [], ["Hello"]}]},
               {"p", [], ["Hello"]}
             ]
    end
  end

  describe "children/2" do
    test "returns children of element" do
      node = {"div", [], [{"p", [], ["Hello"]}, {"span", [], ["World"]}]}

      assert Query.children(node) == [
               {"p", [], ["Hello"]},
               {"span", [], ["World"]}
             ]
    end

    test "includes text nodes by default" do
      node = {"div", [], [{"p", [], ["Hello"]}, "Some text", {"span", [], ["World"]}]}

      assert Query.children(node) == [
               {"p", [], ["Hello"]},
               "Some text",
               {"span", [], ["World"]}
             ]
    end

    test "excludes text nodes with include_text: false" do
      node = {"div", [], [{"p", [], ["Hello"]}, "Some text", {"span", [], ["World"]}]}

      assert Query.children(node, include_text: false) == [
               {"p", [], ["Hello"]},
               {"span", [], ["World"]}
             ]
    end

    test "returns nil for non-elements" do
      assert Query.children("text") == nil
      assert Query.children({:comment, "comment"}) == nil
    end

    test "returns empty list for element with no children" do
      assert Query.children({"br", [], []}) == []
    end

    test "works with foreign elements" do
      node = {{:svg, "svg"}, [], [{{:svg, "circle"}, [{"r", "10"}], []}]}

      assert Query.children(node) == [{{:svg, "circle"}, [{"r", "10"}], []}]
    end
  end

  describe "PureHTML.query/2 delegation" do
    test "delegates to Query.find/2" do
      html = PureHTML.parse("<div><p class='intro'>Hello</p></div>")

      assert PureHTML.query(html, ".intro") == [{"p", [{"class", "intro"}], ["Hello"]}]
    end
  end

  describe "PureHTML.children/2 delegation" do
    test "delegates to Query.children/2" do
      node = {"div", [], [{"p", [], ["Hello"]}]}

      assert PureHTML.children(node) == [{"p", [], ["Hello"]}]
    end
  end

  describe "text/2" do
    test "extracts text from simple element" do
      html = PureHTML.parse("<p>Hello</p>")
      assert Query.text(html) == "Hello"
    end

    test "extracts text from nested elements" do
      html = PureHTML.parse("<p>Hello <strong>World</strong></p>")
      assert Query.text(html) == "Hello World"
    end

    test "extracts text with separator" do
      html = PureHTML.parse("<p>Hello<strong>World</strong></p>")
      assert Query.text(html, separator: " ") == "Hello World"
    end

    test "extracts text from list elements with separator" do
      html = PureHTML.parse("<ul><li>A</li><li>B</li><li>C</li></ul>")
      assert Query.text(html, separator: ", ") == "A, B, C"
    end

    test "excludes script content by default" do
      html = PureHTML.parse("<div>Hello<script>alert(1)</script>World</div>")
      assert Query.text(html) == "HelloWorld"
    end

    test "includes script content when option is set" do
      html = PureHTML.parse("<div>Hello<script>alert(1)</script>World</div>")
      assert Query.text(html, include_script: true) == "Helloalert(1)World"
    end

    test "excludes style content by default" do
      html = PureHTML.parse("<div>Hello<style>.foo{}</style>World</div>")
      assert Query.text(html) == "HelloWorld"
    end

    test "includes style content when option is set" do
      html = PureHTML.parse("<div>Hello<style>.foo{}</style>World</div>")
      assert Query.text(html, include_style: true) == "Hello.foo{}World"
    end

    test "excludes input values by default" do
      html = PureHTML.parse("<form><input value='test'>Submit</form>")
      assert Query.text(html) == "Submit"
    end

    test "includes input values when option is set" do
      html = PureHTML.parse("<form><input value='test'>Submit</form>")
      assert Query.text(html, include_inputs: true) == "testSubmit"
    end

    test "includes textarea content when include_inputs is set" do
      html = PureHTML.parse("<form><textarea>Hello World</textarea></form>")
      assert Query.text(html, include_inputs: true) == "Hello World"
    end

    test "deep: false only extracts direct text children" do
      html = PureHTML.parse("<div>Direct<p>Nested</p>Text</div>")

      html
      |> Query.find("div")
      |> hd()
      |> Query.text(deep: false)
      |> then(&assert &1 == "DirectText")
    end

    test "works with single node" do
      node = {"p", [], ["Hello ", {"strong", [], ["World"]}]}
      assert Query.text(node) == "Hello World"
    end

    test "ignores comments" do
      html = [{"div", [], ["Hello", {:comment, "ignored"}, "World"]}]
      assert Query.text(html) == "HelloWorld"
    end

    test "ignores doctype" do
      html = [{:doctype, "html", nil, nil}, {"html", [], [{"body", [], ["Hello"]}]}]
      assert Query.text(html) == "Hello"
    end

    test "returns empty string for empty tree" do
      assert Query.text([]) == ""
    end

    test "handles foreign elements" do
      node = {{:svg, "text"}, [], ["SVG Text"]}
      assert Query.text(node) == "SVG Text"
    end

    # :strip option tests

    test "strip: true removes leading/trailing whitespace from segments" do
      html = PureHTML.parse("<p>  Hello  </p>")
      assert Query.text(html, strip: true) == "Hello"
    end

    test "strip: true removes whitespace-only segments" do
      html =
        PureHTML.parse("""
        <ul>
          <li>One</li>
          <li>Two</li>
        </ul>
        """)

      assert Query.text(html, strip: true, separator: ", ") == "One, Two"
    end

    test "strip: true with deeply nested formatted HTML" do
      html =
        PureHTML.parse("""
        <div>
          <section>
            <p>
              First paragraph.
            </p>
            <p>
              Second paragraph.
            </p>
          </section>
        </div>
        """)

      assert Query.text(html, strip: true, separator: " ") == "First paragraph. Second paragraph."
    end

    test "strip: false (default) preserves whitespace" do
      html = PureHTML.parse("<p>  Hello  </p>")
      assert Query.text(html) == "  Hello  "
    end

    # Complex real-world scenarios

    test "scraping workflow: query then extract text" do
      html =
        PureHTML.parse("""
        <article>
          <h1>Article Title</h1>
          <p class="summary">This is the summary.</p>
          <p>This is the body.</p>
        </article>
        """)

      summary =
        html
        |> Query.find(".summary")
        |> Query.text(strip: true)

      assert summary == "This is the summary."
    end

    test "extracting text from a table" do
      html =
        PureHTML.parse("""
        <table>
          <tr><th>Name</th><th>Age</th></tr>
          <tr><td>Alice</td><td>30</td></tr>
          <tr><td>Bob</td><td>25</td></tr>
        </table>
        """)

      assert Query.text(html, strip: true, separator: " | ") ==
               "Name | Age | Alice | 30 | Bob | 25"
    end

    test "extracting text from navigation" do
      html =
        PureHTML.parse("""
        <nav>
          <a href="/">Home</a>
          <a href="/about">About</a>
          <a href="/contact">Contact</a>
        </nav>
        """)

      links =
        html
        |> Query.find("a")
        |> Query.text(strip: true, separator: " > ")

      assert links == "Home > About > Contact"
    end

    test "handles self-closing elements mixed with text" do
      html = PureHTML.parse("<p>Line one<br>Line two<br>Line three</p>")
      assert Query.text(html) == "Line oneLine twoLine three"
      assert Query.text(html, separator: "\n") == "Line one\nLine two\nLine three"
    end

    test "deeply nested structure" do
      html =
        PureHTML.parse("""
        <div>
          <div>
            <div>
              <div>
                <span>Deep text</span>
              </div>
            </div>
          </div>
        </div>
        """)

      assert Query.text(html, strip: true) == "Deep text"
    end

    test "multiple scripts and styles are all excluded" do
      html =
        PureHTML.parse("""
        <div>
          Start
          <script>var a = 1;</script>
          Middle
          <style>.foo {}</style>
          <script>var b = 2;</script>
          End
        </div>
        """)

      assert Query.text(html, strip: true, separator: " ") == "Start Middle End"
    end

    test "combining multiple options" do
      html =
        PureHTML.parse("""
        <form>
          <label>Name:</label>
          <input value="John">
          <label>Email:</label>
          <textarea>john@example.com</textarea>
          <script>validate();</script>
          <button>Submit</button>
        </form>
        """)

      result = Query.text(html, strip: true, separator: " ", include_inputs: true)
      assert result == "Name: John Email: john@example.com Submit"
    end
  end

  describe "PureHTML.text/2 delegation" do
    test "delegates to Query.text/2" do
      html = PureHTML.parse("<p>Hello <strong>World</strong></p>")
      assert PureHTML.text(html) == "Hello World"
    end

    test "delegates with options" do
      html = PureHTML.parse("<ul><li>A</li><li>B</li></ul>")
      assert PureHTML.text(html, separator: ", ") == "A, B"
    end
  end
end
