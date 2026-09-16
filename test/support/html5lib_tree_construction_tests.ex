defmodule PureHTML.Test.Html5libTreeConstructionTests do
  @moduledoc """
  Parses html5lib tree-construction test files (.dat format).

  Each test has:
  - #data: HTML input
  - #errors: expected parse errors (count matters, content doesn't)
  - #document: expected tree as indented text
  - Optional #document-fragment: context element for fragment parsing
  - Optional #script-off/#script-on: scripting mode

  A fixture may have a corrections file of the same name under
  `test/fixtures/corrections/tree-construction/`, in the same format, one
  block per case whose expectation contradicts the WHATWG text. A block is
  keyed by `#data`, cites the walk in `#spec`, snapshots what upstream lists
  in `#upstream-errors` (and `#upstream-document` when the tree changes), and
  gives the text's `#errors` (and `#document`). `parse_file/1` applies them;
  a block that matches no case, or whose snapshot no longer matches upstream,
  raises so the disagreement is re-walked rather than carried blindly.
  """

  @test_dir Path.expand("../fixtures/html5lib/tree-construction", __DIR__)
  @corrections_dir Path.expand("../fixtures/corrections/tree-construction", __DIR__)

  def test_dir, do: @test_dir
  def corrections_dir, do: @corrections_dir

  def list_test_files do
    @test_dir
    |> Path.join("**/*.dat")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @doc "Fixture name relative to the tree-construction directory: `webkit01`, `scripted/webkit01`."
  def fixture_name(path) do
    path
    |> Path.relative_to(@test_dir)
    |> Path.rootname(".dat")
  end

  @doc """
  True for fixtures whose expected tree is the DOM after their scripts ran.

  The cases under `scripted/` call `document.write`, `setAttribute`, and
  `getElementById` from `<script>` elements and expect the tree those calls
  produce. A parser without a script engine has no correct answer for them,
  so the test file reports them as skipped instead of running them.
  """
  def needs_script_execution?(path) do
    String.starts_with?(fixture_name(path), "scripted/")
  end

  def parse_file(path) do
    path
    |> parse_cases()
    |> apply_corrections(Path.join(@corrections_dir, Path.relative_to(path, @test_dir)))
  end

  @doc "The cases of a corrections file, in the shape `parse_file/1` returns."
  def parse_corrections(path), do: parse_cases(path)

  defp parse_cases(path) do
    path
    |> File.read!()
    # Split on blank lines followed by #data to properly separate tests
    # (handles empty data sections that have blank lines within the test)
    |> String.split(~r/\n\n(?=#data\n)/)
    |> Enum.map(&parse_test/1)
    |> Enum.reject(&is_nil/1)
  end

  defp apply_corrections(tests, corrections_path) do
    if File.exists?(corrections_path) do
      corrections_path
      |> parse_cases()
      |> Enum.reduce(tests, &apply_correction(&2, &1, corrections_path))
    else
      tests
    end
  end

  defp apply_correction(tests, correction, source) do
    matches = for {test, index} <- Enum.with_index(tests), test.data == correction.data, do: index

    case matches do
      [index] -> List.update_at(tests, index, &correct(&1, correction, source))
      [] -> raise "#{source}: no case has #data #{inspect(correction.data)}"
      _many -> raise "#{source}: #data #{inspect(correction.data)} matches more than one case"
    end
  end

  # The snapshot must still match upstream: a changed case means upstream
  # moved, and the correction needs a fresh walk, not blind reuse.
  defp correct(test, correction, source) do
    if test.errors != correction.upstream_errors do
      raise "#{source}: #data #{inspect(test.data)} lists #{inspect(test.errors)} upstream, " <>
              "the correction expected #{inspect(correction.upstream_errors)}; re-walk it"
    end

    if correction.upstream_document != nil and test.document != correction.upstream_document do
      raise "#{source}: #data #{inspect(test.data)} has a different upstream #document now; re-walk it"
    end

    %{
      test
      | errors: correction.errors,
        document: correction.document || test.document,
        spec: correction.spec
    }
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
      document: Map.get(sections, "document"),
      document_fragment: Map.get(sections, "document-fragment"),
      spec: Map.get(sections, "spec"),
      upstream_errors: Map.get(sections, "upstream-errors"),
      upstream_document: Map.get(sections, "upstream-document"),
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

  defp parse_section_content("upstream-errors", content) do
    content |> String.split("\n", trim: true)
  end

  defp parse_section_content("spec", content), do: String.trim(content)

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
  Runs every case of a fixture file in the given scripting mode and returns one
  report per failing case. Set `HTML5LIB_CASE=name:index` with the fixture
  name (for example `webkit02:12`) to run a single case.
  """
  def failures(path, scripting) do
    name = fixture_name(path)

    path
    |> parse_file()
    |> Enum.with_index()
    |> Enum.filter(&(selected?(name, &1) and runs_with_scripting?(elem(&1, 0), scripting)))
    |> Enum.reject(&passes?(&1, scripting))
    |> Enum.map(&failure_report(name, &1, scripting))
  end

  defp selected?(name, {_test, index}) do
    case System.get_env("HTML5LIB_CASE") do
      nil -> true
      only -> only == "#{name}:#{index}"
    end
  end

  defp runs_with_scripting?(%{script_off: true}, scripting), do: scripting == false
  defp runs_with_scripting?(%{script_on: true}, scripting), do: scripting == true
  defp runs_with_scripting?(_test, _scripting), do: true

  defp passes?({test, _index}, scripting) do
    {document, error_count} = parse_case(test, scripting)

    serialize_tree(document) == expected_document(test) and
      error_count == length(test.errors)
  end

  defp parse_case(test, scripting) do
    PureHTML.parse_with_errors(test.data, parse_opts(test, scripting))
  end

  defp serialize_tree(document) do
    document
    |> serialize_document()
    |> String.trim_trailing("\n")
  end

  defp expected_document(test), do: String.trim_trailing(test.document, "\n")

  defp parse_opts(%{document_fragment: nil}, scripting), do: [scripting: scripting]

  defp parse_opts(%{document_fragment: context}, scripting) do
    [scripting: scripting, context: context]
  end

  defp failure_report(name, {test, index}, scripting) do
    {document, error_count} = parse_case(test, scripting)

    """
    #{name}:#{index} [script-#{if scripting, do: "on", else: "off"}]
    #data
    #{test.data}
    #expected
    #{expected_document(test)}
    #actual
    #{serialize_tree(document)}
    #errors expected #{length(test.errors)} got #{error_count}
    """
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

  defp serialize_node({:pi, target, data}, depth) do
    indent = "| " <> String.duplicate("  ", depth)
    "#{indent}<?#{target} #{data}>\n"
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
