defmodule PureHtml.Test.Html5libTreeConstructionTests do
  @moduledoc """
  Parses html5lib tree-construction test files (.dat format).

  Each test has:
  - #data: HTML input
  - #errors: expected parse errors (count matters, content doesn't)
  - #document: expected tree as indented text
  - Optional #document-fragment: context element for fragment parsing
  - Optional #script-off/#script-on: scripting mode
  """

  @test_dir Path.expand("../html5lib-tests/tree-construction", __DIR__)

  def test_dir, do: @test_dir

  def list_test_files do
    @test_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".dat"))
    |> Enum.reject(&String.contains?(&1, "unsafe"))
    |> Enum.sort()
    |> Enum.map(&Path.join(@test_dir, &1))
  end

  def parse_file(path) do
    path
    |> File.read!()
    |> String.split("\n\n")
    |> Enum.map(&parse_test/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_test(text) do
    text = String.trim(text)
    if text == "", do: nil, else: do_parse_test(text)
  end

  defp do_parse_test(text) do
    sections = parse_sections(text)

    %{
      data: Map.get(sections, "data", ""),
      errors: Map.get(sections, "errors", []),
      document: Map.get(sections, "document", ""),
      document_fragment: Map.get(sections, "document-fragment"),
      script_off: Map.has_key?(sections, "script-off"),
      script_on: Map.has_key?(sections, "script-on")
    }
  end

  defp parse_sections(text) do
    # Split by #keyword at start of line
    parts = Regex.split(~r/^#/m, text, trim: true)

    Enum.reduce(parts, %{}, fn part, acc ->
      case String.split(part, "\n", parts: 2) do
        [keyword] ->
          Map.put(acc, keyword, "")

        [keyword, content] ->
          value = parse_section_content(keyword, content)
          Map.put(acc, keyword, value)
      end
    end)
  end

  defp parse_section_content("errors", content) do
    content |> String.split("\n", trim: true)
  end

  defp parse_section_content("new-errors", content) do
    content |> String.split("\n", trim: true)
  end

  defp parse_section_content(_keyword, content) do
    String.trim_trailing(content, "\n")
  end

  @doc """
  Serializes a Document to the html5lib tree format for comparison.
  """
  def serialize_document(document) do
    doctype = serialize_doctype(document.doctype)

    tree =
      case document.root_id do
        nil -> ""
        root_id -> serialize_node(document, root_id, 0)
      end

    doctype <> tree
  end

  defp serialize_doctype(nil), do: ""

  defp serialize_doctype(%{name: name, public_id: public_id, system_id: system_id}) do
    if (public_id == "" or public_id == nil) and (system_id == "" or system_id == nil) do
      "| <!DOCTYPE #{name}>\n"
    else
      "| <!DOCTYPE #{name} \"#{public_id || ""}\" \"#{system_id || ""}\">\n"
    end
  end

  defp serialize_node(document, node_id, depth) do
    node = PureHtml.Document.get_node(document, node_id)
    indent = "| " <> String.duplicate("  ", depth)

    case node.type do
      :element ->
        tag_line = "#{indent}<#{node.tag}>\n"

        attr_lines =
          node.attrs
          |> Enum.sort()
          |> Enum.map(fn {name, value} ->
            "#{indent}  #{name}=\"#{value}\"\n"
          end)
          |> Enum.join()

        children_lines =
          document
          |> PureHtml.Document.get_children_ids(node_id)
          |> Enum.map(&serialize_node(document, &1, depth + 1))
          |> Enum.join()

        tag_line <> attr_lines <> children_lines

      :text ->
        "#{indent}\"#{node.content}\"\n"

      :comment ->
        "#{indent}<!-- #{node.content} -->\n"
    end
  end
end
