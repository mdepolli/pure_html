defmodule PureHTML.Test.Html5libSerializerTests do
  @moduledoc """
  Parses html5lib serializer test files (.test JSON format) and adapts their
  token streams to the library's node format.

  The fixtures test html5lib's token serializer: each token is written as it
  comes, with html5lib's attribute quoting, boolean minimization, optional tag
  omission, meta injection, and PUBLIC/SYSTEM doctypes. `PureHTML.Serializer`
  implements the HTML fragment serialization algorithm, which serializes a
  tree. `skip_reason/2` names why a case cannot be evidence for that
  algorithm; the test file reports such cases as skipped and runs the rest
  through `build_tree/1` and `PureHTML.Serializer.serialize/2`.
  """

  alias PureHTML.Serializer

  @test_dir Path.expand("../html5lib-tests/serializer", __DIR__)
  @html_ns "http://www.w3.org/1999/xhtml"

  def test_dir, do: @test_dir

  def list_test_files do
    @test_dir
    |> Path.join("*.test")
    |> Path.wildcard()
    |> Enum.sort()
  end

  def fixture_name(path), do: Path.basename(path, ".test")

  def parse_file(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.get("tests", [])
  end

  @doc """
  Why a case is not evidence for the fragment serialization algorithm, or nil
  when it is. `encoding` is the one option that changes nothing here.
  """
  def skip_reason("optionaltags", _test) do
    "tests html5lib's optional tag omission; the fragment algorithm never omits a tag"
  end

  def skip_reason(_name, test) do
    cond do
      Map.keys(test["options"] || %{}) -- ["encoding"] != [] ->
        "uses html5lib serializer options the fragment algorithm does not have"

      Enum.any?(test["input"], &match?(["Doctype", _, _ | _], &1)) ->
        "expects a PUBLIC/SYSTEM doctype; the fragment algorithm writes the name only"

      match?({:error, {:unclosed, _}}, build_tree(test["input"])) ->
        "expects an unclosed start tag; the fragment algorithm closes every non-void element"

      true ->
        nil
    end
  end

  @doc """
  Builds the library's node list from an html5lib token stream, or returns
  `{:error, {:unclosed, tag}}` when a non-void element is never closed.
  """
  def build_tree(tokens) do
    tokens
    |> Enum.reduce([{:root, [], []}], &push_token/2)
    |> finish_tree()
  end

  defp push_token(["StartTag", @html_ns, tag, attrs], stack) do
    if Serializer.void_element?(tag) do
      append_node({tag, decode_attrs(attrs), []}, stack)
    else
      [{tag, decode_attrs(attrs), []} | stack]
    end
  end

  defp push_token(["EmptyTag", tag, attrs], stack) do
    append_node({tag, decode_attrs(attrs), []}, stack)
  end

  defp push_token(["EndTag", @html_ns, tag], [{tag, attrs, children} | stack]) do
    append_node({tag, attrs, Enum.reverse(children)}, stack)
  end

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
    [{tag, attrs, [node | children]} | stack]
  end

  defp finish_tree([{:root, [], children}]), do: {:ok, Enum.reverse(children)}
  defp finish_tree([{tag, _attrs, _children} | _stack]), do: {:error, {:unclosed, tag}}

  defp decode_attrs(attrs) when is_map(attrs), do: Map.to_list(attrs)
  defp decode_attrs(attrs) when is_list(attrs), do: Enum.map(attrs, &{&1["name"], &1["value"]})
end
