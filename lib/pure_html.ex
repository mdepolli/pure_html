defmodule PureHTML do
  @moduledoc """
  A pure Elixir HTML5 parser with CSS selector querying.

  PureHTML parses HTML strings into a tree of nodes and provides functions
  to query, traverse, and serialize them back to HTML.

  ## Parsing

      iex> PureHTML.parse("<p>Hello</p>")
      [{"html", [], [{"head", [], []}, {"body", [], [{"p", [], ["Hello"]}]}]}]

  ## Querying

      iex> html = PureHTML.parse("<div><p class='intro'>Hello</p></div>")
      iex> PureHTML.query(html, ".intro")
      [{"p", [{"class", "intro"}], ["Hello"]}]

  ## Serializing

      iex> [{"p", [], ["Hello"]}] |> PureHTML.to_html()
      "<p>Hello</p>"

  ## Node Format

  Nodes are represented as tuples compatible with [Floki](https://hex.pm/packages/floki):

  - `{tag, attrs, children}` - Element with tag name, attribute list, and children
  - `{:doctype, name, public_id, system_id}` - DOCTYPE declaration
  - `{:comment, text}` - HTML comment
  - `"text"` - Text content (binary string)

  Attributes are lists of `{name, value}` tuples, sorted alphabetically.
  """

  alias PureHTML.{Query, Serializer, Tokenizer, TreeBuilder}

  @doc """
  Parses an HTML string into a list of nodes.

  Returns a list of nodes where each node is one of:
  - `{:doctype, name, public_id, system_id}` - DOCTYPE declaration (if present, always first)
  - `{:comment, text}` - HTML comment
  - `{tag, attrs, children}` - Element with tag name, attributes list, and child nodes
  - `text` - Text content (binary)

  Attributes are represented as a list of `{name, value}` tuples, sorted alphabetically.

  ## Options

  - `:context` - Context element for fragment parsing (e.g., `"div"`, `"svg title"`)
  - `:scripting` - Whether the scripting flag is enabled (default: `true`).
    When `false`, `<noscript>` content is parsed as HTML instead of raw text.

  ## Examples

      iex> PureHTML.parse("<p>Hello</p>")
      [{"html", [], [{"head", [], []}, {"body", [], [{"p", [], ["Hello"]}]}]}]

      iex> PureHTML.parse("<!DOCTYPE html><html></html>")
      [{:doctype, "html", nil, nil}, {"html", [], [{"head", [], []}, {"body", [], []}]}]

  """
  @spec parse(String.t(), keyword()) :: [term()]
  def parse(html, opts \\ []) when is_binary(html) do
    scripting = Keyword.get(opts, :scripting, true)

    case Keyword.get(opts, :context) do
      nil ->
        html
        |> Tokenizer.new()
        |> TreeBuilder.build(scripting)

      context ->
        {ns, tag} = parse_context(context)

        html
        |> Tokenizer.new(fragment_tokenizer_opts(ns, tag, scripting))
        |> TreeBuilder.build_fragment(ns, tag, scripting)
    end
  end

  @doc """
  Parses HTML like `parse/2` and returns `{nodes, error_count}`.

  The count follows the parse errors the WHATWG tokenizer and tree
  construction rules define (a missing doctype, an unexpected end tag, an
  element still open at the end of the input, and so on). Well-formed input
  yields `0`. Takes the same options as `parse/2`.

  ## Examples

      iex> PureHTML.parse_with_errors("<!DOCTYPE html><p>Hi</p>")
      {[{:doctype, "html", nil, nil}, {"html", [], [{"head", [], []}, {"body", [], [{"p", [], ["Hi"]}]}]}], 0}

      iex> {_nodes, errors} = PureHTML.parse_with_errors("<p>Hi")
      iex> errors
      1

  """
  @spec parse_with_errors(String.t(), keyword()) :: {[term()], non_neg_integer()}
  def parse_with_errors(html, opts \\ []) when is_binary(html) do
    scripting = Keyword.get(opts, :scripting, true)

    case Keyword.get(opts, :context) do
      nil ->
        html
        |> Tokenizer.new()
        |> TreeBuilder.build_with_errors(scripting)

      context ->
        {ns, tag} = parse_context(context)

        html
        |> Tokenizer.new(fragment_tokenizer_opts(ns, tag, scripting))
        |> TreeBuilder.build_fragment_with_errors(ns, tag, scripting)
    end
  end

  @doc """
  Converts parsed HTML nodes back to an HTML string.

  ## Options

  - `:quote_char` - Force `"'"` or `"\""` for attribute quotes (default: smart quoting)
  - `:minimize_boolean_attributes` - Output `disabled` vs `disabled=disabled` (default: true)
  - `:use_trailing_solidus` - Output `<br />` vs `<br>` (default: false)
  - `:escape_rcdata` - Escape content in script/style (default: false)
  - `:strip_whitespace` - Collapse whitespace in text nodes (default: false)

  ## Examples

      iex> PureHTML.parse("<p>Hello</p>") |> PureHTML.to_html()
      "<html><head></head><body><p>Hello</p></body></html>"

      iex> PureHTML.to_html([{"div", [{"class", "foo"}], ["text"]}])
      "<div class=foo>text</div>"

      iex> PureHTML.to_html([{"br", [], []}], use_trailing_solidus: true)
      "<br />"

  """
  @spec to_html([term()], keyword()) :: String.t()
  def to_html(nodes, opts \\ []) when is_list(nodes) do
    Serializer.serialize(nodes, opts)
  end

  @doc """
  Finds all nodes matching the CSS selector.

  ## Supported Selectors

  - Tag: `div`, `p`, `a`
  - Universal: `*`
  - Class: `.class`
  - ID: `#id`
  - Attribute: `[attr]`, `[attr=value]`, `[attr^=prefix]`, `[attr$=suffix]`, `[attr*=substring]`
  - Selector list: `.a, .b`

  ## Examples

      iex> html = PureHTML.parse("<div><p class='intro'>Hello</p><p>World</p></div>")
      iex> PureHTML.query(html, "p.intro")
      [{"p", [{"class", "intro"}], ["Hello"]}]

      iex> html = PureHTML.parse("<ul><li>A</li><li>B</li></ul>")
      iex> PureHTML.query(html, "li")
      [{"li", [], ["A"]}, {"li", [], ["B"]}]

  """
  defdelegate query(html, selector), to: Query, as: :find

  @doc """
  Finds the first node matching the CSS selector.

  Returns the first matching node, or `nil` if no match is found.
  More efficient than `query/2` when you only need the first result.

  ## Examples

      iex> "<ul><li>A</li><li>B</li></ul>"
      ...> |> PureHTML.parse()
      ...> |> PureHTML.query_one("li")
      {"li", [], ["A"]}

      iex> "<div><p>Hello</p></div>"
      ...> |> PureHTML.parse()
      ...> |> PureHTML.query_one(".missing")
      nil

  """
  defdelegate query_one(html, selector), to: Query, as: :find_one

  @doc """
  Returns the immediate children of a node.

  ## Options

  - `:include_text` - Include text nodes (default: true)

  ## Examples

      iex> node = {"div", [], [{"p", [], ["Hello"]}, "Some text"]}
      iex> PureHTML.children(node)
      [{"p", [], ["Hello"]}, "Some text"]

      iex> node = {"div", [], [{"p", [], ["Hello"]}, "Some text"]}
      iex> PureHTML.children(node, include_text: false)
      [{"p", [], ["Hello"]}]

  """
  defdelegate children(node, opts \\ []), to: Query

  @doc """
  Extracts text content from an HTML tree or node.

  ## Options

  - `:deep` - Traverse all descendants (default: true). When false, only direct text children.
  - `:separator` - String to insert between text segments (default: "")
  - `:strip` - Strip whitespace from each segment and remove empty segments (default: false)
  - `:include_script` - Include text from `<script>` tags (default: false)
  - `:include_style` - Include text from `<style>` tags (default: false)
  - `:include_inputs` - Include value from `<input>` and `<textarea>` (default: false)

  ## Examples

      iex> html = PureHTML.parse("<p>Hello <strong>World</strong></p>")
      iex> PureHTML.text(html)
      "Hello World"

      iex> html = PureHTML.parse("<ul><li>A</li><li>B</li></ul>")
      iex> PureHTML.text(html, separator: ", ")
      "A, B"

      iex> html = PureHTML.parse("<div>Hello<script>alert(1)</script>World</div>")
      iex> PureHTML.text(html)
      "HelloWorld"

      iex> html = PureHTML.parse("<form><input value='test'></form>")
      iex> PureHTML.text(html, include_inputs: true)
      "test"

  Formatted HTML often contains whitespace for indentation. Use `:strip` to clean it:

      iex> html = PureHTML.parse("<ul>\\n  <li>One</li>\\n  <li>Two</li>\\n</ul>")
      iex> PureHTML.text(html, strip: true, separator: " | ")
      "One | Two"

  """
  defdelegate text(html, opts \\ []), to: Query

  @doc """
  Extracts an attribute value from a single node.

  Returns the attribute value as a string, or `nil` if the attribute
  doesn't exist or the input is not an element.

  ## Examples

      iex> node = {"a", [{"href", "/home"}, {"class", "link"}], ["Home"]}
      iex> PureHTML.attr(node, "href")
      "/home"

      iex> node = {"a", [{"href", "/home"}], ["Home"]}
      iex> PureHTML.attr(node, "title")
      nil

      iex> PureHTML.attr("text node", "href")
      nil

  """
  defdelegate attr(node, name), to: Query

  @doc """
  Extracts attribute values from a list of nodes.

  Returns a list of attribute values. Nodes without the attribute are skipped.

  ## Examples

      iex> "<a href='/one'>One</a><a href='/two'>Two</a>"
      ...> |> PureHTML.parse()
      ...> |> PureHTML.query("a")
      ...> |> PureHTML.attribute("href")
      ["/one", "/two"]

  """
  defdelegate attribute(nodes, name), to: Query

  @doc """
  Finds elements matching a selector and extracts an attribute from them.

  Combines `query/2` and `attribute/2` into a single call for convenience.
  This is the most common pattern for scraping.

  ## Examples

      iex> "<nav><a href='/'>Home</a><a href='/about'>About</a></nav>"
      ...> |> PureHTML.parse()
      ...> |> PureHTML.attribute("a", "href")
      ["/", "/about"]

      iex> "<div><img src='a.png'><img src='b.png'></div>"
      ...> |> PureHTML.parse()
      ...> |> PureHTML.attribute("img", "src")
      ["a.png", "b.png"]

  """
  defdelegate attribute(html, selector, name), to: Query

  # --------------------------------------------------------------------------
  # Fragment parsing helpers
  # --------------------------------------------------------------------------

  @raw_text_elements ~w(style xmp iframe noembed noframes)
  @rcdata_elements ~w(title textarea)

  defp parse_context(context) do
    case String.split(context, " ", parts: 2) do
      ["svg", tag] -> {:svg, tag}
      ["math", tag] -> {:math, tag}
      [tag] -> {nil, tag}
    end
  end

  # Foreign elements always use :data state — the tokenizer state rules
  # only apply to HTML namespace context elements.
  defp fragment_tokenizer_opts(ns, _tag, _scripting) when ns in [:svg, :math], do: []

  defp fragment_tokenizer_opts(_ns, tag, _scripting) when tag in @rcdata_elements do
    [initial_state: :rcdata]
  end

  defp fragment_tokenizer_opts(_ns, "script", _scripting), do: [initial_state: :script_data]
  defp fragment_tokenizer_opts(_ns, "plaintext", _scripting), do: [initial_state: :plaintext]
  defp fragment_tokenizer_opts(_ns, "noscript", true = _scripting), do: [initial_state: :rawtext]

  defp fragment_tokenizer_opts(_ns, tag, _scripting) when tag in @raw_text_elements do
    [initial_state: :rawtext]
  end

  defp fragment_tokenizer_opts(_ns, _tag, _scripting), do: []
end
