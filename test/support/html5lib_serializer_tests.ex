defmodule PureHTML.Test.Html5libSerializerTests do
  @moduledoc """
  Parses html5lib serializer test files (.test JSON format).

  The html5lib serializer tests use a JSON format where each test specifies:
  - "input": list of tokens to serialize
  - "expected": list of acceptable output strings
  - "xhtml": optional XHTML-mode expected output (ignored)
  - "options": optional serializer options

  Token formats:
  - ["StartTag", namespace, tag, attrs_list] - start tag
  - ["EmptyTag", tag, attrs_map] - void element (legacy format)
  - ["EndTag", namespace, tag] - end tag
  - ["Characters", text] - text content
  - ["Comment", text] - comment
  - ["Doctype", name] or ["Doctype", name, public, system] - DOCTYPE
  """

  @test_dir Path.expand("../html5lib-tests/serializer", __DIR__)

  @void_elements ~w(area base basefont bgsound br col embed hr img input
                    keygen link meta param source track wbr)

  @raw_text_elements ~w(script style xmp iframe noembed noframes plaintext)

  @whitespace_preserving ~w(pre textarea script style)

  # Characters that require quoting in attribute values
  @unquoted_attr_regex ~r/^[^ \t\n\r\f"'=>`]+$/

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
  Serializes tokens with context awareness and options support.

  Options (from html5lib test format):
  - "quote_char" - force single (') or double (") quotes for attributes
  - "minimize_boolean_attributes" - output `disabled` vs `disabled=disabled`
  - "use_trailing_solidus" - output `<br />` vs `<br>`
  - "escape_lt_in_attrs" - escape `<` in attribute values
  - "escape_rcdata" - escape content in script/style
  - "strip_whitespace" - collapse whitespace in text nodes
  """
  def serialize_tokens_with_context(tokens, options \\ %{}) do
    # Context is a stack of ancestor tags to track raw text and whitespace preservation
    serialize_tokens_with_context(tokens, [], options, [])
  end

  defp serialize_tokens_with_context([], _context_stack, _opts, acc) do
    acc
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp serialize_tokens_with_context(
         [["Characters", text] | rest],
         context_stack,
         opts,
         acc
       ) do
    escape_rcdata = Map.get(opts, "escape_rcdata", false)
    strip_whitespace = Map.get(opts, "strip_whitespace", false)

    # Check if any ancestor is whitespace-preserving
    preserve_whitespace = Enum.any?(context_stack, &(&1 in @whitespace_preserving))

    # Check if immediate parent is raw text element
    raw_text_context = List.first(context_stack) in @raw_text_elements

    text =
      if strip_whitespace and not preserve_whitespace do
        strip_ws(text)
      else
        text
      end

    serialized =
      cond do
        raw_text_context and not escape_rcdata ->
          text

        true ->
          escape_text(text)
      end

    serialize_tokens_with_context(rest, context_stack, opts, [serialized | acc])
  end

  defp serialize_tokens_with_context(
         [["StartTag", _ns, tag, attrs] | rest],
         context_stack,
         opts,
         acc
       ) do
    serialized = serialize_start_tag(tag, attrs, opts)
    serialize_tokens_with_context(rest, [tag | context_stack], opts, [serialized | acc])
  end

  defp serialize_tokens_with_context(
         [["EmptyTag", tag, attrs] | rest],
         context_stack,
         opts,
         acc
       ) do
    serialized = serialize_start_tag(tag, attrs, opts)
    # Empty tags don't add to context stack
    serialize_tokens_with_context(rest, context_stack, opts, [serialized | acc])
  end

  defp serialize_tokens_with_context(
         [["EndTag", _ns, tag] | rest],
         context_stack,
         opts,
         acc
       ) do
    # Pop from context stack (find and remove the matching tag)
    new_stack = pop_tag(context_stack, tag)
    serialize_tokens_with_context(rest, new_stack, opts, [["</", tag, ">"] | acc])
  end

  defp serialize_tokens_with_context([["Comment", text] | rest], context_stack, opts, acc) do
    serialize_tokens_with_context(rest, context_stack, opts, [["<!--", text, "-->"] | acc])
  end

  defp serialize_tokens_with_context([["Doctype", name] | rest], context_stack, opts, acc) do
    serialize_tokens_with_context(rest, context_stack, opts, [["<!DOCTYPE ", name, ">"] | acc])
  end

  defp serialize_tokens_with_context(
         [["Doctype", name, public_id] | rest],
         context_stack,
         opts,
         acc
       ) do
    doctype = ["<!DOCTYPE ", name, " PUBLIC \"", public_id, "\">"]
    serialize_tokens_with_context(rest, context_stack, opts, [doctype | acc])
  end

  defp serialize_tokens_with_context(
         [["Doctype", name, public_id, system_id] | rest],
         context_stack,
         opts,
         acc
       ) do
    doctype =
      cond do
        public_id == "" ->
          ["<!DOCTYPE ", name, " SYSTEM \"", system_id, "\">"]

        true ->
          ["<!DOCTYPE ", name, " PUBLIC \"", public_id, "\" \"", system_id, "\">"]
      end

    serialize_tokens_with_context(rest, context_stack, opts, [doctype | acc])
  end

  # Pop a tag from the context stack (remove first occurrence)
  defp pop_tag([], _tag), do: []
  defp pop_tag([tag | rest], tag), do: rest
  defp pop_tag([other | rest], tag), do: [other | pop_tag(rest, tag)]

  defp serialize_start_tag(tag, attrs, opts) when is_map(attrs) and map_size(attrs) == 0 do
    use_trailing_solidus = Map.get(opts, "use_trailing_solidus", false)

    if use_trailing_solidus and tag in @void_elements do
      ["<", tag, " />"]
    else
      ["<", tag, ">"]
    end
  end

  defp serialize_start_tag(tag, attrs, opts) when is_map(attrs) do
    use_trailing_solidus = Map.get(opts, "use_trailing_solidus", false)
    attr_str = serialize_attrs_map(attrs, opts)

    if use_trailing_solidus and tag in @void_elements do
      ["<", tag, " ", attr_str, " />"]
    else
      ["<", tag, " ", attr_str, ">"]
    end
  end

  defp serialize_start_tag(tag, attrs, opts) when is_list(attrs) and length(attrs) == 0 do
    use_trailing_solidus = Map.get(opts, "use_trailing_solidus", false)

    if use_trailing_solidus and tag in @void_elements do
      ["<", tag, " />"]
    else
      ["<", tag, ">"]
    end
  end

  defp serialize_start_tag(tag, attrs, opts) when is_list(attrs) do
    use_trailing_solidus = Map.get(opts, "use_trailing_solidus", false)
    attr_str = serialize_attrs_list(attrs, opts)

    if use_trailing_solidus and tag in @void_elements do
      ["<", tag, " ", attr_str, " />"]
    else
      ["<", tag, " ", attr_str, ">"]
    end
  end

  defp serialize_attrs_map(attrs, opts) do
    attrs
    |> Enum.map(fn {name, value} -> serialize_attr(name, value, opts) end)
    |> Enum.intersperse(" ")
  end

  defp serialize_attrs_list(attrs, opts) do
    attrs
    |> Enum.map(fn attr -> serialize_attr(attr["name"], attr["value"], opts) end)
    |> Enum.intersperse(" ")
  end

  defp serialize_attr(name, value, opts) do
    quote_char = Map.get(opts, "quote_char")
    minimize = Map.get(opts, "minimize_boolean_attributes", true)
    escape_lt = Map.get(opts, "escape_lt_in_attrs", false)

    cond do
      # Empty value with minimize=false - use empty quotes
      value == "" and minimize == false ->
        [name, "=\"\""]

      # Empty value with minimize=true (default) - just the attribute name
      value == "" ->
        name

      # Value equals name (boolean attribute like disabled=disabled)
      minimize and value == name ->
        name

      # Forced quote char
      quote_char == "'" ->
        escaped = escape_attr_single(value, escape_lt)
        [name, "='", escaped, "'"]

      quote_char == "\"" ->
        escaped = escape_attr_double(value, escape_lt)
        [name, "=\"", escaped, "\""]

      # Smart quoting: unquoted if safe chars only
      Regex.match?(@unquoted_attr_regex, value) ->
        [name, "=", value]

      # Single quotes: contains " but not '
      String.contains?(value, "\"") and not String.contains?(value, "'") ->
        escaped = escape_attr_single(value, escape_lt)
        [name, "='", escaped, "'"]

      # Double quotes: default (contains ' or both or neither)
      true ->
        escaped = escape_attr_double(value, escape_lt)
        [name, "=\"", escaped, "\""]
    end
  end

  defp escape_attr_single(value, escape_lt) do
    value = String.replace(value, "&", "&amp;")
    value = String.replace(value, "'", "&#39;")

    if escape_lt do
      String.replace(value, "<", "&lt;")
    else
      value
    end
  end

  defp escape_attr_double(value, escape_lt) do
    value =
      value
      |> String.replace("&", "&amp;")
      |> String.replace("\"", "&quot;")

    if escape_lt do
      String.replace(value, "<", "&lt;")
    else
      value
    end
  end

  defp escape_text(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Collapse whitespace: replace sequences of whitespace chars with single space
  defp strip_ws(text) do
    text
    |> String.replace(~r/[\t\r\n\f]+/, " ")
    |> String.replace(~r/  +/, " ")
  end
end
