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

  HTML elements are `{tag, attrs, children}` tuples, the same shape
  [Floki](https://hex.pm/packages/floki) uses. Foreign elements, namespaced
  attributes, template content, and processing instructions are this parser's.

  - `{tag, attrs, children}` — HTML element
  - `{{:svg | :math, local}, attrs, children}` — foreign element
  - `{:content, children}` — sole child of `template`
  - `{:doctype, name, public_id, system_id}` — `name` is `nil` when missing
  - `{:comment, text}`
  - `{:pi, target, data}`
  - `"text"`

  Attributes are `{name, value}` tuples in source order. `name` is a string or
  `{:xlink | :xml | :xmlns, local}`. A duplicate name keeps the first value.
  """

  alias PureHTML.{Query, Serializer, Tokenizer, TreeBuilder}

  @typedoc """
  Attribute name: a local name, or a namespaced name from the adjust-foreign-attributes table.
  """
  @type attr_name :: String.t() | {:xlink | :xml | :xmlns, String.t()}

  @typedoc "One attribute: name and value, in source order on the element."
  @type attr :: {attr_name(), String.t()}

  @typedoc """
  A node `parse/2` returns. The runtime check of this type is `valid_node?/1`
  in `test/pure_html_test.exs`.
  """
  @type html_node ::
          {String.t(), [attr()], [html_node()]}
          | {{:svg | :math, String.t()}, [attr()], [html_node()]}
          | {:content, [html_node()]}
          | {:doctype, String.t() | nil, String.t() | nil, String.t() | nil}
          | {:comment, String.t()}
          | {:pi, String.t(), String.t()}
          | String.t()

  @doc """
  Parses an HTML string into a list of nodes.

  Returns a list of `t:html_node/0`. A doctype, if present, is first.

  ## Options

  - `:context` - Context element for fragment parsing: `"tag"` for an HTML
    element (ASCII case-insensitive, e.g. `"div"`), or `"svg local"` or
    `"math local"` for a foreign one (case-sensitive, e.g. `"svg foreignObject"`).
    A bare `"svg"` is an HTML element named svg; the SVG root is `"svg svg"`.
    A name that is not a valid element local name in DOM, or any other form,
    raises `ArgumentError`.
  - `:scripting` - Whether the scripting flag is enabled (default: `true`).
    When `false`, `<noscript>` content is parsed as HTML instead of raw text.

  An unknown option, or a `:scripting` that is not a boolean, raises
  `ArgumentError`.

  ## Examples

      iex> PureHTML.parse("<p>Hello</p>")
      [{"html", [], [{"head", [], []}, {"body", [], [{"p", [], ["Hello"]}]}]}]

      iex> PureHTML.parse("<!DOCTYPE html><html></html>")
      [{:doctype, "html", nil, nil}, {"html", [], [{"head", [], []}, {"body", [], []}]}]

      iex> [{"html", [], [{"head", [], []}, {"body", [], [svg]}]}] = PureHTML.parse("<svg></svg>")
      iex> svg
      {{:svg, "svg"}, [], []}

  """
  @spec parse(String.t(), keyword()) :: [html_node()]
  def parse(html, opts \\ []) when is_binary(html) do
    {nodes, _error_count} = parse_with_errors(html, opts)
    nodes
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
  @spec parse_with_errors(String.t(), keyword()) :: {[html_node()], non_neg_integer()}
  def parse_with_errors(html, opts \\ []) when is_binary(html) do
    %{context: context, scripting: scripting} = parse_options(opts)

    build(html, context, scripting)
  end

  @doc """
  Converts parsed HTML nodes, or a single node, back to an HTML string.

  Follows the HTML fragment serialization algorithm. A node that is not a
  `t:html_node/0`, or an attribute that is not a `t:attr/0`, raises
  `ArgumentError` naming it.

  ## Options

  - `:scripting` - Whether scripting is enabled (default: `true`, as for
    `parse/2`). Text in a `noscript` element is written literally when it is
    `true` and escaped when it is `false`.

    Pass the `:scripting` you passed to `parse/2`. A scripting-on parse keeps
    noscript content as one text node of raw markup, which must be written
    literally. A scripting-off parse decodes character references in noscript
    text, so writing that text literally turns `&lt;img onerror=...&gt;` back
    into a live `<img>`.

  An unknown option, or a `:scripting` that is not a boolean, raises
  `ArgumentError`.

  ## Examples

      iex> PureHTML.parse("<p>Hello</p>") |> PureHTML.to_html()
      "<html><head></head><body><p>Hello</p></body></html>"

      iex> PureHTML.to_html([{"div", [{"class", "foo"}], ["text"]}])
      "<div class=\\"foo\\">text</div>"

      iex> "<ul><li>A</li></ul>"
      ...> |> PureHTML.parse()
      ...> |> PureHTML.query_one("li")
      ...> |> PureHTML.to_html()
      "<li>A</li>"

  """
  @spec to_html(html_node() | [html_node()], keyword()) :: String.t()
  def to_html(nodes, opts \\ [])

  def to_html(nodes, opts) when is_list(nodes) do
    %{scripting: scripting} = serialize_options(opts)

    Serializer.serialize(nodes, scripting: scripting)
  end

  def to_html(node, opts), do: to_html([node], opts)

  @doc """
  Finds all nodes matching the CSS selector.

  ## Supported Selectors

  - Tag: `div`, `p`, `a`
  - Universal: `*`
  - Class: `.class`
  - ID: `#id`
  - Attribute: `[attr]`, `[attr=value]`, `[attr^=prefix]`, `[attr$=suffix]`, `[attr*=substring]`
  - Selector list: `.a, .b`

  An invalid selector represents, and therefore matches, nothing: the result
  is `[]`. `query!/2` raises instead.

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
  Like `query/2`, but raises `ArgumentError` on an invalid selector.
  """
  defdelegate query!(html, selector), to: Query, as: :find!

  @doc """
  Finds the first node matching the CSS selector.

  Returns the first matching node in document order, or `nil` if no match is
  found. Stops at the first match, so it is cheaper than `query/2` when you
  only need one result. An invalid selector matches nothing.

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
  Like `query_one/2`, but raises `ArgumentError` on an invalid selector.
  """
  defdelegate query_one!(html, selector), to: Query, as: :find_one!

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
  # Options
  # --------------------------------------------------------------------------

  defp parse_options(opts) do
    opts
    |> Keyword.validate!(context: nil, scripting: true)
    |> Map.new()
    |> validate_scripting()
  end

  defp serialize_options(opts) do
    opts
    |> Keyword.validate!(scripting: true)
    |> Map.new()
    |> validate_scripting()
  end

  defp validate_scripting(%{scripting: scripting} = options) when is_boolean(scripting),
    do: options

  defp validate_scripting(%{scripting: scripting}) do
    raise ArgumentError, ":scripting must be a boolean, got: #{inspect(scripting)}"
  end

  # --------------------------------------------------------------------------
  # Building
  # --------------------------------------------------------------------------

  defp build(html, nil = _context, scripting) do
    html
    |> Tokenizer.new()
    |> TreeBuilder.build(scripting)
  end

  defp build(html, context, scripting) do
    {ns, tag} = context_element(context)

    html
    |> Tokenizer.new()
    |> TreeBuilder.build_fragment(ns, tag, scripting)
  end

  @context_forms ~s("tag", "svg local", or "math local", each name a valid element local name)

  # The html5lib #document-fragment format: "svg local" and "math local" are
  # foreign elements, anything else an HTML one. Each name must be a valid
  # element local name, which createElement and createElementNS require; an
  # HTML name is then ASCII lowercased, as createElement does in an HTML
  # document, and a foreign one keeps its case.
  defp context_element(context) when is_binary(context) do
    context
    |> String.split(" ")
    |> context_element_from_names(context)
  end

  defp context_element(context), do: raise_invalid_context(context)

  defp context_element_from_names(["svg", local], context),
    do: {:svg, context_name(local, context)}

  defp context_element_from_names(["math", local], context),
    do: {:math, context_name(local, context)}

  defp context_element_from_names([tag], context) do
    name =
      tag
      |> context_name(context)
      |> String.downcase(:ascii)

    {nil, name}
  end

  defp context_element_from_names(_names, context), do: raise_invalid_context(context)

  defp context_name(name, context) do
    if valid_element_local_name?(name) do
      name
    else
      raise_invalid_context(context)
    end
  end

  # DOM's "valid element local name", as the regular expression the standard
  # gives for it. A binary that is not UTF-8 holds no name.
  defp valid_element_local_name?(name) do
    String.valid?(name) and
      Regex.match?(
        ~r/\A(?:[A-Za-z][^\x00\t\n\f\r \/>]*|[:_\x{80}-\x{10FFFF}][A-Za-z0-9\-.:_\x{80}-\x{10FFFF}]*)\z/u,
        name
      )
  end

  defp raise_invalid_context(context) do
    raise ArgumentError, "invalid :context #{inspect(context)}: expected #{@context_forms}"
  end
end
