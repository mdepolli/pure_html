defmodule PureHTML.Test.Html5libSerializerTests do
  @moduledoc """
  Parses html5lib serializer test files (.test JSON format) and adapts their
  token streams to the library's node format.

  The fixtures test html5lib's token serializer: each token is written as it
  comes, with html5lib's attribute quoting, boolean minimization, optional tag
  omission, meta injection, and PUBLIC/SYSTEM doctypes. `PureHTML.Serializer`
  implements the HTML fragment serialization algorithm, which serializes a
  tree. `skip_reason/1` names why a case cannot be evidence for that
  algorithm; the test file reports such cases as skipped and runs the rest
  through `build_tree/1` and `PureHTML.Serializer.serialize/2`.
  """

  alias PureHTML.Serializer

  @test_dir Path.expand("../fixtures/html5lib/serializer", __DIR__)
  @html_ns "http://www.w3.org/1999/xhtml"
  # html5lib.filters.whitespace spacePreserveElements: pre, textarea, plus rcdataElements.
  @space_preserve ~w(pre textarea style script xmp iframe noembed noframes noscript)

  def test_dir, do: @test_dir

  def list_test_files do
    @test_dir
    |> Path.join("**/*.test")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @doc "Fixture name relative to the serializer directory: `core`, `scripted/core`."
  def fixture_name(path) do
    path
    |> Path.relative_to(@test_dir)
    |> Path.rootname(".test")
  end

  def parse_file(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.get("tests", [])
  end

  @doc """
  Why a case is not evidence for the fragment serialization algorithm, or nil
  when it is, decided from the case itself. `encoding` changes nothing here.
  `strip_whitespace` is ignored when every `Characters` token sits under
  html5lib's space-preserve elements (`pre`, `textarea`, and the rcdata set).
  """
  def skip_reason(test) do
    extra = Map.keys(test["options"] || %{}) -- ["encoding"]

    cond do
      extra -- ["strip_whitespace"] != [] ->
        "uses html5lib serializer options the fragment algorithm does not have"

      extra == ["strip_whitespace"] and strip_would_change?(test["input"]) ->
        "uses html5lib serializer options the fragment algorithm does not have"

      Enum.any?(test["input"], &match?(["Doctype", _, _ | _], &1)) ->
        "expects a PUBLIC/SYSTEM doctype; the fragment algorithm writes the name only"

      true ->
        test["input"]
        |> build_tree()
        |> tree_skip_reason(test)
    end
  end

  @doc """
  Splits a fixture file into fragment-algorithm cases and skip counts
  `{reason, n}`, sorted by count descending.
  """
  def classify(path) do
    {running, skipped} =
      path
      |> parse_file()
      |> Enum.split_with(&(skip_reason(&1) == nil))

    skip_counts =
      skipped
      |> Enum.map(&skip_reason/1)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {reason, n} -> {-n, reason} end)

    {running, skip_counts}
  end

  @doc "Failure reports for the fragment-algorithm cases in `path`."
  def failures(path) do
    name = fixture_name(path)

    path
    |> parse_file()
    |> Enum.filter(&(skip_reason(&1) == nil))
    |> Enum.flat_map(&failure_report(name, &1))
  end

  defp failure_report(name, test) do
    {:ok, nodes} = build_tree(test["input"])
    actual = Serializer.serialize(nodes)

    if actual in test["expected"] do
      []
    else
      [
        """
        #{name}: #{test["description"]}
        Expected one of: #{inspect(test["expected"])}
        Got: #{inspect(actual)}
        Nodes: #{inspect(nodes)}
        """
      ]
    end
  end

  @doc "One skip reason for a file: total and per-reason counts."
  def skip_summary(skip_counts) do
    total = Enum.reduce(skip_counts, 0, fn {_reason, n}, acc -> acc + n end)

    parts =
      Enum.map_join(skip_counts, ", ", fn {reason, n} ->
        "#{short_skip_reason(reason)} (#{n})"
      end)

    "#{total} cases: #{parts}"
  end

  defp short_skip_reason("uses html5lib serializer options" <> _),
    do: "html5lib serializer options"

  defp short_skip_reason("expects a PUBLIC/SYSTEM doctype" <> _),
    do: "PUBLIC/SYSTEM doctype"

  defp short_skip_reason("has an end tag with no open element" <> _),
    do: "stray end tag"

  defp short_skip_reason("expects an unclosed start tag" <> _),
    do: "unclosed start tag"

  defp short_skip_reason("expects an omitted end tag" <> _),
    do: "omitted end tag"

  defp short_skip_reason(reason), do: reason

  # html5lib.filters.whitespace: collapse runs of spaceCharacters in Characters
  # tokens while the preserve counter is 0.
  defp strip_would_change?(tokens) do
    Enum.reduce_while(tokens, 0, fn
      ["StartTag", _ns, tag, _attrs], preserve when preserve > 0 or tag in @space_preserve ->
        {:cont, preserve + 1}

      ["EndTag", _ns, _tag], preserve when preserve > 0 ->
        {:cont, preserve - 1}

      ["Characters", data], 0 ->
        if collapse_spaces(data) != data, do: {:halt, true}, else: {:cont, 0}

      _token, preserve ->
        {:cont, preserve}
    end) == true
  end

  defp collapse_spaces(data), do: Regex.replace(~r/[\t\n\f \r]+/, data, " ")

  defp tree_skip_reason({:error, {:stray_end_tag, _tag}}, _test) do
    "has an end tag with no open element; the fragment algorithm serializes a tree"
  end

  defp tree_skip_reason({:error, {:unclosed, _tag}}, _test) do
    "expects an unclosed start tag; the fragment algorithm closes every non-void element"
  end

  defp tree_skip_reason({:ok, _nodes}, test) do
    if omits_end_tag?(test) do
      "expects an omitted end tag; the fragment algorithm closes every non-void element"
    end
  end

  # True when the expected output lacks the end tag of a non-void element the
  # input opens: html5lib's optional tag omission.
  defp omits_end_tag?(test) do
    opened =
      for ["StartTag", @html_ns, tag, _attrs] <- test["input"],
          not Serializer.void_element?(tag),
          do: tag

    Enum.any?(opened, fn tag ->
      Enum.all?(test["expected"], &(not String.contains?(&1, "</" <> tag <> ">")))
    end)
  end

  @doc """
  Builds the library's node list from an html5lib token stream, or returns
  `{:error, {:unclosed, tag}}` when a non-void element is never closed and
  `{:error, {:stray_end_tag, tag}}` when an end tag has no open element.
  """
  def build_tree(tokens) do
    tokens
    |> Enum.reduce_while([{:root, [], []}], &push_token/2)
    |> finish_tree()
  end

  defp push_token(["StartTag", @html_ns, tag, attrs], stack) do
    if Serializer.void_element?(tag) do
      append_node({tag, decode_attrs(attrs), []}, stack)
    else
      {:cont, [{tag, decode_attrs(attrs), []} | stack]}
    end
  end

  defp push_token(["EmptyTag", tag, attrs], stack) do
    append_node({tag, decode_attrs(attrs), []}, stack)
  end

  defp push_token(["EndTag", @html_ns, tag], [{tag, attrs, children} | stack]) do
    append_node({tag, attrs, Enum.reverse(children)}, stack)
  end

  defp push_token(["EndTag", @html_ns, tag], _stack), do: {:halt, {:stray_end_tag, tag}}

  defp push_token(["Characters", text], stack), do: append_node(text, stack)
  defp push_token(["Comment", text], stack), do: append_node({:comment, text}, stack)

  defp push_token(["Doctype", name], stack) do
    append_node({:doctype, name, nil, nil}, stack)
  end

  defp push_token(["Doctype", name, public_id], stack) do
    append_node({:doctype, name, public_id, nil}, stack)
  end

  defp push_token(["Doctype", name, public_id, system_id], stack) do
    append_node({:doctype, name, public_id, system_id}, stack)
  end

  defp append_node(node, [{tag, attrs, children} | stack]) do
    {:cont, [{tag, attrs, [node | children]} | stack]}
  end

  defp finish_tree({:stray_end_tag, tag}), do: {:error, {:stray_end_tag, tag}}
  defp finish_tree([{:root, [], children}]), do: {:ok, Enum.reverse(children)}
  defp finish_tree([{tag, _attrs, _children} | _stack]), do: {:error, {:unclosed, tag}}

  defp decode_attrs(attrs) when is_map(attrs), do: Map.to_list(attrs)
  defp decode_attrs(attrs) when is_list(attrs), do: Enum.map(attrs, &{&1["name"], &1["value"]})
end
