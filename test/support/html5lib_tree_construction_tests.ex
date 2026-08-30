defmodule PureHTML.Test.Html5libTreeConstructionTests do
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
    # Split on blank lines followed by #data to properly separate tests
    # (handles empty data sections that have blank lines within the test)
    |> String.split(~r/\n\n(?=#data\n)/)
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

  # For #data section: preserve internal newlines but trim the final section-separator newline
  # The test format uses blank lines between sections, so content ends with \n\n
  # but we only want to preserve the actual trailing newline from the HTML input
  defp parse_section_content("data", content) do
    # Trim exactly one trailing newline (the section separator)
    # If content ends with \n\n, result ends with \n (preserving HTML trailing newline)
    # If content ends with \n, result has no trailing newline (no HTML trailing newline)
    case content do
      "" -> ""
      _ -> String.replace_suffix(content, "\n", "")
    end
  end

  defp parse_section_content(_keyword, content) do
    String.trim_trailing(content, "\n")
  end

  @doc """
  Serializes a document to the html5lib tree format for comparison.

  Document format: list of nodes where:
  - `{:doctype, name, public_id, system_id}` - DOCTYPE (if present, first)
  - `{:comment, text}` - comment
  - `{tag, attrs, children}` - element
  """
  def serialize_document(nodes) when is_list(nodes) do
    Enum.map_join(nodes, "", &serialize_node(&1, 0))
  end

  defp serialize_node(text, depth) when is_binary(text) do
    indent = "| " <> String.duplicate("  ", depth)
    "#{indent}\"#{text}\"\n"
  end

  defp serialize_node({:doctype, name, public_id, system_id}, _depth) do
    if (public_id == "" or public_id == nil) and (system_id == "" or system_id == nil) do
      "| <!DOCTYPE #{name}>\n"
    else
      "| <!DOCTYPE #{name} \"#{public_id || ""}\" \"#{system_id || ""}\">\n"
    end
  end

  defp serialize_node({:comment, text}, depth) do
    indent = "| " <> String.duplicate("  ", depth)
    "#{indent}<!-- #{text} -->\n"
  end

  defp serialize_node({{ns, tag}, attrs, children}, depth) do
    serialize_element("#{ns} #{tag}", attrs, children, depth)
  end

  defp serialize_node({tag, attrs, children}, depth) do
    serialize_element(tag, attrs, children, depth)
  end

  defp serialize_element(tag_display, attrs, children, depth) do
    indent = "| " <> String.duplicate("  ", depth)
    tag_line = "#{indent}<#{tag_display}>\n"

    attr_lines =
      attrs
      |> Enum.sort_by(&attr_sort_key/1)
      |> Enum.map_join("", fn {name, value} ->
        "#{indent}  #{format_attr_name(name)}=\"#{value}\"\n"
      end)

    children_lines = Enum.map_join(children, "", &serialize_child(&1, depth + 1))

    tag_line <> attr_lines <> children_lines
  end

  # Format namespaced attribute names: {:xml, "lang"} -> "xml lang"
  defp format_attr_name({ns, local}), do: "#{ns} #{local}"
  defp format_attr_name(name), do: name

  # Sort key for attributes - namespaced attrs sort by "ns local" format
  defp attr_sort_key({{ns, local}, _value}), do: "#{ns} #{local}"
  defp attr_sort_key({name, _value}), do: name

  defp serialize_child(text, depth) when is_binary(text) do
    indent = "| " <> String.duplicate("  ", depth)
    "#{indent}\"#{text}\"\n"
  end

  # Template content document fragment
  defp serialize_child({:content, children}, depth) do
    indent = "| " <> String.duplicate("  ", depth)
    content_line = "#{indent}content\n"
    children_lines = Enum.map_join(children, "", &serialize_child(&1, depth + 1))
    content_line <> children_lines
  end

  defp serialize_child(node, depth) do
    serialize_node(node, depth)
  end
end
