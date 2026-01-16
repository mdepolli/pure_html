defmodule PureHTML.Test.Html5libSerializerTests do
  @moduledoc """
  Parses html5lib serializer test files (.test JSON format).

  The html5lib serializer tests use a JSON format where each test specifies:
  - "input": list of tokens to serialize
  - "expected": list of acceptable output strings
  - "xhtml": optional XHTML-mode expected output (ignored)
  - "options": optional serializer options (ignored for now)

  Token formats:
  - ["StartTag", namespace, tag, attrs_list] - start tag
  - ["EmptyTag", tag, attrs_map] - void element (legacy format)
  - ["EndTag", namespace, tag] - end tag
  - ["Characters", text] - text content
  - ["Comment", text] - comment
  - ["Doctype", name] or ["Doctype", name, public, system] - DOCTYPE
  """

  @test_dir Path.expand("../html5lib-tests/serializer", __DIR__)

  @doc "Returns the path to the serializer test directory."
  def test_dir, do: @test_dir

  @doc "Lists all .test files in the serializer test directory."
  def list_test_files do
    @test_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".test"))
    |> Enum.sort()
    |> Enum.map(&Path.join(@test_dir, &1))
  end

  @doc "Parses a test file and returns a list of raw test maps."
  def parse_file(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.get("tests", [])
  end

  @doc """
  Normalizes a raw test map into a structured format.

  Returns a map with:
  - :description - test description string
  - :input - list of tokens
  - :expected - list of acceptable output strings
  - :options - serializer options map
  """
  def normalize_test(test) do
    %{
      description: test["description"],
      input: test["input"],
      expected: test["expected"],
      options: test["options"] || %{}
    }
  end

  @doc """
  Converts html5lib tokens to our serializer input format.

  Since our serializer works with a tree structure but html5lib tests
  use token streams, we need to handle this conversion carefully.

  For simple cases, we can convert tokens to nodes directly.
  For complex cases (like unclosed tags), we serialize tokens individually.
  """
  def tokens_to_nodes(tokens) do
    tokens_to_nodes(tokens, [])
  end

  defp tokens_to_nodes([], acc), do: Enum.reverse(acc)

  # Characters -> text string
  defp tokens_to_nodes([["Characters", text] | rest], acc) do
    tokens_to_nodes(rest, [text | acc])
  end

  # Comment
  defp tokens_to_nodes([["Comment", text] | rest], acc) do
    tokens_to_nodes(rest, [{:comment, text} | acc])
  end

  # Doctype with just name
  defp tokens_to_nodes([["Doctype", name] | rest], acc) do
    tokens_to_nodes(rest, [{:doctype, name, nil, nil} | acc])
  end

  # Doctype with public identifier only
  defp tokens_to_nodes([["Doctype", name, public_id] | rest], acc) do
    tokens_to_nodes(rest, [{:doctype, name, public_id, nil} | acc])
  end

  # Doctype with public and system identifiers
  defp tokens_to_nodes([["Doctype", name, public_id, system_id] | rest], acc) do
    tokens_to_nodes(rest, [{:doctype, name, public_id, system_id} | acc])
  end

  # EmptyTag (void element, legacy format with map attrs)
  defp tokens_to_nodes([["EmptyTag", tag, attrs] | rest], acc) when is_map(attrs) do
    node = {tag, attrs, []}
    tokens_to_nodes(rest, [node | acc])
  end

  # EmptyTag with list attrs
  defp tokens_to_nodes([["EmptyTag", tag, attrs] | rest], acc) when is_list(attrs) do
    node = {tag, normalize_attrs(attrs), []}
    tokens_to_nodes(rest, [node | acc])
  end

  # StartTag followed by Characters (for raw text elements like script)
  defp tokens_to_nodes(
         [["StartTag", _ns, tag, attrs], ["Characters", text] | rest],
         acc
       )
       when tag in ~w(script style) do
    node = {tag, normalize_attrs(attrs), [text]}
    tokens_to_nodes(rest, [node | acc])
  end

  # StartTag without matching EndTag (serialize as unclosed element)
  defp tokens_to_nodes([["StartTag", _ns, tag, attrs] | rest], acc) do
    # For tests that just check start tag serialization, we create an element
    # and mark it specially so the serializer knows to omit the end tag
    node = {:start_tag_only, tag, normalize_attrs(attrs)}
    tokens_to_nodes(rest, [node | acc])
  end

  # EndTag (standalone)
  defp tokens_to_nodes([["EndTag", _ns, tag] | rest], acc) do
    node = {:end_tag_only, tag}
    tokens_to_nodes(rest, [node | acc])
  end

  # Normalize attrs from list of {namespace, name, value} maps to simple map
  defp normalize_attrs(attrs) when is_list(attrs) do
    attrs
    |> Enum.map(fn attr ->
      name = attr["name"]
      value = attr["value"]
      {name, value}
    end)
    |> Map.new()
  end

  defp normalize_attrs(attrs) when is_map(attrs), do: attrs

  @doc """
  Serializes tokens directly for html5lib test compatibility.

  This handles the token stream format that html5lib tests use,
  including partial structures like unclosed tags.
  """
  def serialize_tokens(tokens) do
    tokens
    |> Enum.map(&serialize_token/1)
    |> IO.iodata_to_binary()
  end

  defp serialize_token(["Characters", text]) do
    escape_text(text)
  end

  defp serialize_token(["Comment", text]) do
    ["<!--", text, "-->"]
  end

  defp serialize_token(["Doctype", name]) do
    ["<!DOCTYPE ", name, ">"]
  end

  defp serialize_token(["Doctype", name, public_id]) do
    ["<!DOCTYPE ", name, " PUBLIC \"", public_id, "\">"]
  end

  defp serialize_token(["Doctype", name, public_id, system_id]) do
    cond do
      public_id == "" ->
        ["<!DOCTYPE ", name, " SYSTEM \"", system_id, "\">"]

      true ->
        ["<!DOCTYPE ", name, " PUBLIC \"", public_id, "\" \"", system_id, "\">"]
    end
  end

  defp serialize_token(["EmptyTag", tag, attrs]) do
    serialize_start_tag(tag, attrs)
  end

  defp serialize_token(["StartTag", _namespace, tag, attrs]) do
    serialize_start_tag(tag, attrs)
  end

  defp serialize_token(["EndTag", _namespace, tag]) do
    ["</", tag, ">"]
  end

  defp serialize_start_tag(tag, attrs) when is_map(attrs) and map_size(attrs) == 0 do
    ["<", tag, ">"]
  end

  defp serialize_start_tag(tag, attrs) when is_map(attrs) do
    attr_str = serialize_attrs_map(attrs)
    ["<", tag, " ", attr_str, ">"]
  end

  defp serialize_start_tag(tag, attrs) when is_list(attrs) and length(attrs) == 0 do
    ["<", tag, ">"]
  end

  defp serialize_start_tag(tag, attrs) when is_list(attrs) do
    attr_str = serialize_attrs_list(attrs)
    ["<", tag, " ", attr_str, ">"]
  end

  defp serialize_attrs_map(attrs) do
    attrs
    |> Enum.map(fn {name, value} -> serialize_attr(name, value) end)
    |> Enum.intersperse(" ")
  end

  defp serialize_attrs_list(attrs) do
    attrs
    |> Enum.map(fn attr -> serialize_attr(attr["name"], attr["value"]) end)
    |> Enum.intersperse(" ")
  end

  # Characters that require quoting in attribute values
  # Per html5lib tests:
  # - < is allowed unquoted (browser will parse correctly)
  # - > requires quoting
  # - Only ASCII whitespace (space, tab, LF, CR, FF) requires quoting
  # - Vertical tab (U+000B) is allowed unquoted
  @unquoted_attr_regex ~r/^[^ \t\n\r\f"'=>`]+$/

  defp serialize_attr(name, value) do
    cond do
      # Empty value - just the attribute name
      value == "" ->
        name

      # Unquoted: safe chars only
      Regex.match?(@unquoted_attr_regex, value) ->
        [name, "=", value]

      # Single quotes: contains " but not '
      String.contains?(value, "\"") and not String.contains?(value, "'") ->
        escaped = escape_attr_single(value)
        [name, "='", escaped, "'"]

      # Double quotes: default
      true ->
        escaped = escape_attr_double(value)
        [name, "=\"", escaped, "\""]
    end
  end

  defp escape_attr_single(value) do
    String.replace(value, "&", "&amp;")
  end

  defp escape_attr_double(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
  end

  defp escape_text(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc """
  Serializes tokens with context awareness for raw text elements.

  When a StartTag for script/style is followed by Characters,
  the characters should not be escaped.
  """
  def serialize_tokens_with_context(tokens) do
    serialize_tokens_with_context(tokens, nil, [])
  end

  defp serialize_tokens_with_context([], _context, acc) do
    acc
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp serialize_tokens_with_context(
         [["Characters", text] | rest],
         context,
         acc
       )
       when context in ~w(script style xmp iframe noembed noframes plaintext) do
    # Raw text element - don't escape
    serialize_tokens_with_context(rest, context, [text | acc])
  end

  defp serialize_tokens_with_context([["Characters", text] | rest], _context, acc) do
    serialize_tokens_with_context(rest, nil, [escape_text(text) | acc])
  end

  defp serialize_tokens_with_context([["StartTag", _ns, tag, attrs] | rest], _context, acc) do
    serialized = serialize_start_tag(tag, attrs)
    serialize_tokens_with_context(rest, tag, [serialized | acc])
  end

  defp serialize_tokens_with_context([token | rest], _context, acc) do
    serialized = serialize_token(token)
    serialize_tokens_with_context(rest, nil, [serialized | acc])
  end
end
