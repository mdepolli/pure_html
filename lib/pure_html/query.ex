defmodule PureHTML.Query do
  @moduledoc """
  CSS selector querying for PureHTML documents.

  Provides functions for finding and traversing HTML nodes using CSS selectors.
  """

  alias PureHTML.Query.Selector
  alias PureHTML.Query.Selector.Parser

  @type html_tree :: [html_node()]
  @type html_node ::
          {String.t(), [{String.t(), String.t()}], [html_node() | String.t()]}
          | String.t()
          | {:comment, String.t()}
          | {:doctype, String.t(), String.t() | nil, String.t() | nil}

  @doc """
  Finds all nodes matching the CSS selector.

  ## Supported Selectors

  - Tag: `div`, `p`, `a`
  - Universal: `*`
  - Class: `.class`
  - ID: `#id`
  - Attribute: `[attr]`, `[attr=value]`, `[attr^=prefix]`, `[attr$=suffix]`, `[attr*=substring]`
  - Combinators: `div p` (descendant), `div > p` (child), `h1 + p` (adjacent sibling), `h1 ~ p` (general sibling)
  - Selector list: `.a, .b`

  ## Examples

      iex> html = PureHTML.parse("<div><p class='intro'>Hello</p><p>World</p></div>")
      iex> PureHTML.Query.find(html, "p.intro")
      [{"p", [{"class", "intro"}], ["Hello"]}]

      iex> html = PureHTML.parse("<ul><li>A</li><li>B</li></ul>")
      iex> PureHTML.Query.find(html, "li")
      [{"li", [], ["A"]}, {"li", [], ["B"]}]

  """
  @spec find(html_tree() | html_node(), String.t() | Parser.selector_chain()) :: html_tree()
  def find(html, selector) when is_binary(selector) do
    chains = Parser.parse(selector)
    find(html, chains)
  end

  def find(html, chains) when is_list(chains) do
    tree = List.wrap(html)

    chains
    |> Enum.flat_map(&evaluate_chain(tree, &1))
    |> Enum.uniq()
  end

  @doc """
  Finds the first node matching the CSS selector.

  Returns the first matching node, or `nil` if no match is found.
  More efficient than `find/2` when you only need the first result.

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
  @spec find_one(html_tree() | html_node(), String.t() | Parser.selector_chain()) ::
          html_node() | nil
  def find_one(html, selector) when is_binary(selector) do
    chains = Parser.parse(selector)
    find_one(html, chains)
  end

  def find_one(html, chains) when is_list(chains) do
    case find(html, chains) do
      [first | _] -> first
      [] -> nil
    end
  end

  # Evaluate a single selector chain against the tree
  defp evaluate_chain(tree, [{nil, selector} | rest]) do
    # First selector - find all matches in tree
    matches = find_all_matching(tree, selector)
    apply_combinators(tree, matches, rest)
  end

  # Apply remaining combinators in the chain
  defp apply_combinators(_tree, matches, []), do: matches

  defp apply_combinators(tree, matches, [{:descendant, selector} | rest]) do
    # For each match, find all descendants matching selector
    new_matches =
      Enum.flat_map(matches, fn node ->
        node
        |> get_element_children()
        |> find_all_matching(selector)
      end)

    apply_combinators(tree, new_matches, rest)
  end

  defp apply_combinators(tree, matches, [{:child, selector} | rest]) do
    # For each match, find direct children matching selector
    new_matches =
      Enum.flat_map(matches, fn node ->
        node
        |> get_element_children()
        |> Enum.filter(&Selector.match?(&1, selector))
      end)

    apply_combinators(tree, new_matches, rest)
  end

  defp apply_combinators(tree, matches, [{:adjacent_sibling, selector} | rest]) do
    # For each match, get the next sibling if it matches
    new_matches =
      matches
      |> Enum.flat_map(&adjacent_sibling_matches(tree, &1, selector))

    apply_combinators(tree, new_matches, rest)
  end

  defp apply_combinators(tree, matches, [{:general_sibling, selector} | rest]) do
    # For each match, get all following siblings that match
    new_matches =
      matches
      |> Enum.flat_map(fn node ->
        tree
        |> find_following_siblings(node)
        |> Enum.filter(&Selector.match?(&1, selector))
      end)

    apply_combinators(tree, new_matches, rest)
  end

  defp adjacent_sibling_matches(tree, node, selector) do
    with sibling when not is_nil(sibling) <- find_next_sibling(tree, node),
         true <- Selector.match?(sibling, selector) do
      [sibling]
    else
      _ -> []
    end
  end

  # Find all nodes matching a selector (recursive descent)
  defp find_all_matching(nodes, selector) do
    do_find_all_matching(nodes, selector, [])
    |> Enum.reverse()
  end

  defp do_find_all_matching([], _selector, acc), do: acc

  defp do_find_all_matching([node | rest], selector, acc) do
    acc =
      if Selector.match?(node, selector) do
        [node | acc]
      else
        acc
      end

    children = get_element_children(node)
    acc = do_find_all_matching(children, selector, acc)
    do_find_all_matching(rest, selector, acc)
  end

  # Find the next sibling of a node within the tree
  defp find_next_sibling(tree, target) do
    case find_siblings_of(tree, target) do
      nil -> nil
      siblings -> get_sibling_after(siblings, target)
    end
  end

  # Find all following siblings of a node within the tree
  defp find_following_siblings(tree, target) do
    case find_siblings_of(tree, target) do
      nil -> []
      siblings -> get_siblings_after(siblings, target)
    end
  end

  # Find the siblings list containing the target node
  defp find_siblings_of(nodes, target) when is_list(nodes) do
    if Enum.any?(nodes, &(&1 == target)) do
      nodes
    else
      nodes
      |> Enum.find_value(fn node ->
        children = get_element_children(node)
        find_siblings_of(children, target)
      end)
    end
  end

  # Get the sibling immediately after target
  defp get_sibling_after(siblings, target) do
    siblings
    |> Enum.drop_while(&(&1 != target))
    |> Enum.drop(1)
    |> Enum.find(&element?/1)
  end

  # Get all siblings after target
  defp get_siblings_after(siblings, target) do
    siblings
    |> Enum.drop_while(&(&1 != target))
    |> Enum.drop(1)
    |> Enum.filter(&element?/1)
  end

  defp get_element_children({{_ns, _tag}, _attrs, children}), do: children
  defp get_element_children({_tag, _attrs, children}) when is_list(children), do: children
  defp get_element_children(_), do: []

  @doc """
  Returns the immediate children of a node.

  ## Options

  - `:include_text` - Include text nodes (default: true)

  ## Examples

      iex> node = {"div", [], [{"p", [], ["Hello"]}, "Some text"]}
      iex> PureHTML.Query.children(node)
      [{"p", [], ["Hello"]}, "Some text"]

      iex> node = {"div", [], [{"p", [], ["Hello"]}, "Some text"]}
      iex> PureHTML.Query.children(node, include_text: false)
      [{"p", [], ["Hello"]}]

  """
  @spec children(html_node(), keyword()) :: html_tree() | nil
  def children(node, opts \\ [])

  def children({{_ns, _tag}, _attrs, children}, opts) do
    filter_children(children, opts)
  end

  def children({_tag, _attrs, children}, opts) when is_list(children) do
    filter_children(children, opts)
  end

  def children(_non_element, _opts), do: nil

  defp filter_children(children, opts) do
    include_text = Keyword.get(opts, :include_text, true)

    if include_text do
      children
    else
      Enum.filter(children, &element?/1)
    end
  end

  defp element?({tag, attrs, _children}) when is_binary(tag) and is_list(attrs), do: true

  defp element?({{_ns, tag}, attrs, _children}) when is_binary(tag) and is_list(attrs),
    do: true

  defp element?(_), do: false

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

      iex> html = PureHTML.parse("<ul>\\n  <li>One</li>\\n  <li>Two</li>\\n</ul>")
      iex> PureHTML.text(html, strip: true, separator: ", ")
      "One, Two"

  """
  @spec text(html_tree() | html_node(), keyword()) :: String.t()
  def text(html, opts \\ []) do
    deep = Keyword.get(opts, :deep, true)
    separator = Keyword.get(opts, :separator, "")
    strip = Keyword.get(opts, :strip, false)
    include_script = Keyword.get(opts, :include_script, false)
    include_style = Keyword.get(opts, :include_style, false)
    include_inputs = Keyword.get(opts, :include_inputs, false)

    extract_opts = %{
      deep: deep,
      include_script: include_script,
      include_style: include_style,
      include_inputs: include_inputs
    }

    html
    |> List.wrap()
    |> extract_text(extract_opts)
    |> maybe_strip(strip)
    |> Enum.join(separator)
  end

  defp maybe_strip(segments, false), do: segments

  defp maybe_strip(segments, true) do
    segments
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_text(nodes, opts) when is_list(nodes) do
    Enum.flat_map(nodes, &extract_text_from_node(&1, opts))
  end

  defp extract_text_from_node(text, _opts) when is_binary(text), do: [text]
  defp extract_text_from_node({:comment, _}, _opts), do: []
  defp extract_text_from_node({:doctype, _, _, _}, _opts), do: []

  defp extract_text_from_node({"script", _, _}, %{include_script: false}), do: []
  defp extract_text_from_node({"style", _, _}, %{include_style: false}), do: []

  defp extract_text_from_node({"input", attrs, _}, %{include_inputs: true}) do
    case List.keyfind(attrs, "value", 0) do
      {_, value} -> [value]
      nil -> []
    end
  end

  defp extract_text_from_node({"textarea", _, children}, %{include_inputs: true}) do
    Enum.filter(children, &is_binary/1)
  end

  defp extract_text_from_node({_tag, _attrs, children}, %{deep: true} = opts) do
    extract_text(children, opts)
  end

  defp extract_text_from_node({_tag, _attrs, children}, %{deep: false}) do
    Enum.filter(children, &is_binary/1)
  end

  defp extract_text_from_node({{_ns, "script"}, _, _}, %{include_script: false}), do: []
  defp extract_text_from_node({{_ns, "style"}, _, _}, %{include_style: false}), do: []

  defp extract_text_from_node({{_ns, _tag}, _attrs, children}, %{deep: true} = opts) do
    extract_text(children, opts)
  end

  defp extract_text_from_node({{_ns, _tag}, _attrs, children}, %{deep: false}) do
    Enum.filter(children, &is_binary/1)
  end

  defp extract_text_from_node(_, _opts), do: []

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

  """
  @spec attr(html_node(), String.t()) :: String.t() | nil
  def attr({_tag, attrs, _children}, name) when is_list(attrs) do
    case List.keyfind(attrs, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  def attr({{_ns, _tag}, attrs, _children}, name) when is_list(attrs) do
    case List.keyfind(attrs, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  def attr(_non_element, _name), do: nil

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
  @spec attribute(html_tree() | html_node(), String.t()) :: [String.t()]
  def attribute(html, name) do
    html
    |> List.wrap()
    |> Enum.flat_map(fn node ->
      case attr(node, name) do
        nil -> []
        value -> [value]
      end
    end)
  end

  @doc """
  Finds elements matching a selector and extracts an attribute from them.

  Combines `find/2` and `attribute/2` into a single call for convenience.

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
  @spec attribute(html_tree() | html_node(), String.t(), String.t()) :: [String.t()]
  def attribute(html, selector, name) do
    html
    |> find(selector)
    |> attribute(name)
  end
end
