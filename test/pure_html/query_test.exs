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

  describe "find_one/2" do
    test "returns first matching element" do
      html = PureHTML.parse("<ul><li>A</li><li>B</li><li>C</li></ul>")
      assert Query.find_one(html, "li") == {"li", [], ["A"]}
    end

    test "returns nil when no match" do
      html = PureHTML.parse("<div><p>Hello</p></div>")
      assert Query.find_one(html, ".missing") == nil
    end

    test "finds first by class" do
      html = PureHTML.parse("<div><p class='a'>First</p><p class='a'>Second</p></div>")
      assert Query.find_one(html, ".a") == {"p", [{"class", "a"}], ["First"]}
    end

    test "finds first by id" do
      html = PureHTML.parse("<div><span id='target'>Found</span></div>")
      assert Query.find_one(html, "#target") == {"span", [{"id", "target"}], ["Found"]}
    end

    test "finds deeply nested element" do
      html = PureHTML.parse("<div><div><div><span class='deep'>Deep</span></div></div></div>")
      assert Query.find_one(html, ".deep") == {"span", [{"class", "deep"}], ["Deep"]}
    end

    test "works with compound selector" do
      html =
        PureHTML.parse("<div><a href='/one'>One</a><a href='/two' class='special'>Two</a></div>")

      assert Query.find_one(html, "a.special") ==
               {"a", [{"class", "special"}, {"href", "/two"}], ["Two"]}
    end

    test "works with attribute selector" do
      html = PureHTML.parse("<form><input type='text'><input type='email'></form>")
      assert Query.find_one(html, "[type=email]") == {"input", [{"type", "email"}], []}
    end

    test "works with selector list (returns first match of any)" do
      html = PureHTML.parse("<div><span>Span</span><p>Para</p></div>")
      assert Query.find_one(html, "p, span") == {"span", [], ["Span"]}
    end

    test "works with single node input" do
      node = {"div", [], [{"p", [{"class", "inner"}], ["Hello"]}]}
      assert Query.find_one(node, ".inner") == {"p", [{"class", "inner"}], ["Hello"]}
    end

    test "returns nil for empty tree" do
      assert Query.find_one([], "p") == nil
    end

    # Common scraping patterns

    test "get page title" do
      html =
        PureHTML.parse("""
        <html>
          <head><title>My Page</title></head>
          <body><h1>Welcome</h1></body>
        </html>
        """)

      title = Query.find_one(html, "title")
      assert title == {"title", [], ["My Page"]}
    end

    test "get main content" do
      html =
        PureHTML.parse("""
        <html>
          <body>
            <nav>Navigation</nav>
            <main class="content">
              <article>Main content here</article>
            </main>
          </body>
        </html>
        """)

      main = Query.find_one(html, "main.content")
      assert {"main", [{"class", "content"}], _children} = main
    end
  end

  describe "PureHTML.query_one/2 delegation" do
    test "delegates to Query.find_one/2" do
      html = PureHTML.parse("<ul><li>A</li><li>B</li></ul>")
      assert PureHTML.query_one(html, "li") == {"li", [], ["A"]}
    end

    test "returns nil when no match" do
      html = PureHTML.parse("<div><p>Hello</p></div>")
      assert PureHTML.query_one(html, ".missing") == nil
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

  describe "attr/2" do
    test "extracts attribute from element" do
      node = {"a", [{"href", "/home"}, {"class", "link"}], ["Home"]}
      assert Query.attr(node, "href") == "/home"
      assert Query.attr(node, "class") == "link"
    end

    test "returns nil for missing attribute" do
      node = {"a", [{"href", "/home"}], ["Home"]}
      assert Query.attr(node, "title") == nil
    end

    test "returns nil for non-element nodes" do
      assert Query.attr("text", "href") == nil
      assert Query.attr({:comment, "comment"}, "href") == nil
      assert Query.attr({:doctype, "html", nil, nil}, "href") == nil
    end

    test "works with foreign elements" do
      node = {{:svg, "circle"}, [{"r", "10"}, {"cx", "50"}], []}
      assert Query.attr(node, "r") == "10"
      assert Query.attr(node, "cx") == "50"
    end
  end

  describe "attribute/2" do
    test "extracts attribute from list of nodes" do
      nodes = [
        {"a", [{"href", "/one"}], ["One"]},
        {"a", [{"href", "/two"}], ["Two"]}
      ]

      assert Query.attribute(nodes, "href") == ["/one", "/two"]
    end

    test "skips nodes without the attribute" do
      nodes = [
        {"a", [{"href", "/one"}], ["One"]},
        {"span", [], ["Text"]},
        {"a", [{"href", "/two"}], ["Two"]}
      ]

      assert Query.attribute(nodes, "href") == ["/one", "/two"]
    end

    test "works with single node" do
      node = {"a", [{"href", "/home"}], ["Home"]}
      assert Query.attribute(node, "href") == ["/home"]
    end

    test "returns empty list when no matches" do
      nodes = [{"span", [], ["Text"]}, {"div", [], []}]
      assert Query.attribute(nodes, "href") == []
    end

    test "returns empty list for empty input" do
      assert Query.attribute([], "href") == []
    end
  end

  describe "attribute/3" do
    test "finds elements and extracts attribute" do
      html = PureHTML.parse("<nav><a href='/'>Home</a><a href='/about'>About</a></nav>")
      assert Query.attribute(html, "a", "href") == ["/", "/about"]
    end

    test "works with different selectors" do
      html = PureHTML.parse("<div><img src='a.png' alt='A'><img src='b.png' alt='B'></div>")
      assert Query.attribute(html, "img", "src") == ["a.png", "b.png"]
      assert Query.attribute(html, "img", "alt") == ["A", "B"]
    end

    test "returns empty list when selector matches nothing" do
      html = PureHTML.parse("<div><p>Hello</p></div>")
      assert Query.attribute(html, "a", "href") == []
    end

    test "returns empty list when attribute not present" do
      html = PureHTML.parse("<div><a>Link without href</a></div>")
      assert Query.attribute(html, "a", "href") == []
    end

    # Real-world scraping scenarios

    test "scraping all links from a page" do
      html =
        PureHTML.parse("""
        <html>
          <body>
            <nav>
              <a href="/home">Home</a>
              <a href="/products">Products</a>
            </nav>
            <main>
              <a href="/featured">Featured</a>
            </main>
            <footer>
              <a href="/contact">Contact</a>
            </footer>
          </body>
        </html>
        """)

      hrefs = Query.attribute(html, "a", "href")
      assert hrefs == ["/home", "/products", "/featured", "/contact"]
    end

    test "scraping images with specific class" do
      html =
        PureHTML.parse("""
        <div>
          <img class="thumbnail" src="thumb1.jpg">
          <img class="full" src="full1.jpg">
          <img class="thumbnail" src="thumb2.jpg">
        </div>
        """)

      thumbnails = Query.attribute(html, "img.thumbnail", "src")
      assert thumbnails == ["thumb1.jpg", "thumb2.jpg"]
    end

    test "scraping data attributes" do
      html =
        PureHTML.parse("""
        <ul>
          <li data-id="1">Item 1</li>
          <li data-id="2">Item 2</li>
          <li data-id="3">Item 3</li>
        </ul>
        """)

      ids = Query.attribute(html, "li", "data-id")
      assert ids == ["1", "2", "3"]
    end
  end

  describe "PureHTML.attr/2 delegation" do
    test "delegates to Query.attr/2" do
      node = {"a", [{"href", "/home"}], ["Home"]}
      assert PureHTML.attr(node, "href") == "/home"
    end
  end

  describe "PureHTML.attribute/2 delegation" do
    test "delegates to Query.attribute/2" do
      nodes = [{"a", [{"href", "/one"}], []}, {"a", [{"href", "/two"}], []}]
      assert PureHTML.attribute(nodes, "href") == ["/one", "/two"]
    end
  end

  describe "PureHTML.attribute/3 delegation" do
    test "delegates to Query.attribute/3" do
      html = PureHTML.parse("<div><a href='/link'>Link</a></div>")
      assert PureHTML.attribute(html, "a", "href") == ["/link"]
    end
  end
end
