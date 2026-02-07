defmodule PureHTML.Test.Html5libTokenizerTests do
  @moduledoc """
  Parses html5lib tokenizer test files (.test JSON format).

  The html5lib test suite uses a JSON format where each test specifies:
  - "input": the HTML string to tokenize
  - "output": expected tokens as arrays like ["StartTag", "div", {}]
  - "errors": optional list of expected parse errors
  - "initialStates": optional list of tokenizer states to test
  - "lastStartTag": for some states, the last start tag name
  - "doubleEscaped": if true, input has \\uXXXX sequences to unescape
  """

  @test_dir Path.expand("../html5lib-tests/tokenizer", __DIR__)

  @doc "Returns the path to the tokenizer test directory."
  def test_dir, do: @test_dir

  @doc "Lists all .test files in the tokenizer test directory."
  def list_test_files do
    @test_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".test"))
    |> Enum.sort()
    |> Enum.map(&Path.join(@test_dir, &1))
  end

  @doc """
  Parses a test file and returns {tests, xml_violation_mode?}.

  The xml_violation_mode? flag is true when the JSON uses "xmlViolationTests"
  key instead of "tests", indicating XML infoset coercion should be applied.
  """
  def parse_file(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> extract_tests()
  end

  defp extract_tests(%{"tests" => tests}), do: {tests, false}
  defp extract_tests(%{"xmlViolationTests" => tests}), do: {tests, true}
  defp extract_tests(_), do: {[], false}

  @doc """
  Normalizes a raw test map into a structured format.

  Returns a map with:
  - :description - test description string
  - :input - the HTML input (unescaped if needed)
  - :expected_tokens - list of normalized token tuples
  - :initial_states - list of tokenizer states to test in
  - :last_start_tag - last start tag name (for RCDATA/RAWTEXT states)
  - :expected_errors - list of expected parse errors
  """
  def normalize_test(test) do
    double_escaped? = test["doubleEscaped"] == true

    %{
      description: test["description"],
      input: maybe_unescape(test["input"], double_escaped?),
      expected_tokens: normalize_tokens(test["output"], double_escaped?),
      initial_states: test["initialStates"] || ["Data state"],
      last_start_tag: test["lastStartTag"],
      expected_errors: test["errors"] || []
    }
  end

  # Token normalization - converts JSON arrays to Elixir tuples

  defp normalize_tokens(tokens, double_escaped?) do
    Enum.map(tokens, &normalize_token(&1, double_escaped?))
  end

  defp normalize_token(["DOCTYPE", name, public_id, system_id, correctness], _) do
    # HTML5lib uses "correctness" (true=no quirks), we use "force_quirks" (true=quirks)
    # These are inverse semantics
    {:doctype, name, public_id, system_id, not correctness}
  end

  defp normalize_token(["StartTag", name, attrs], _) do
    normalize_start_tag(name, attrs, false)
  end

  defp normalize_token(["StartTag", name, attrs, self_closing], _) do
    normalize_start_tag(name, attrs, self_closing)
  end

  defp normalize_token(["EndTag", name], _) do
    {:end_tag, name}
  end

  defp normalize_token(["Comment", data], double_escaped?) do
    {:comment, maybe_unescape(data, double_escaped?)}
  end

  defp normalize_token(["Character", data], double_escaped?) do
    {:character, maybe_unescape(data, double_escaped?)}
  end

  defp normalize_start_tag(name, attrs, self_closing) do
    attrs_list = attrs |> Map.to_list() |> Enum.sort()
    {:start_tag, name, attrs_list, self_closing}
  end

  # Unicode unescaping for doubleEscaped tests

  defp maybe_unescape(string, false), do: string
  defp maybe_unescape(string, true), do: unescape_unicode(string)

  defp unescape_unicode(string) when is_binary(string) do
    # Split on \uXXXX patterns, keeping the captures
    parts = Regex.split(~r/\\u([0-9A-Fa-f]{4})/, string, include_captures: true)

    parts
    |> parse_unicode_parts()
    |> combine_surrogate_pairs()
    |> parts_to_binary()
  end

  defp unescape_unicode(other), do: other

  # Parse string parts into {:text, str} or {:codepoint, int}
  defp parse_unicode_parts(parts) do
    Enum.map(parts, fn part ->
      case Regex.run(~r/^\\u([0-9A-Fa-f]{4})$/, part) do
        [_, hex] -> {:codepoint, String.to_integer(hex, 16)}
        nil -> {:text, part}
      end
    end)
  end

  # Combine UTF-16 surrogate pairs into single codepoints
  defp combine_surrogate_pairs(parts) do
    combine_surrogate_pairs(parts, [])
  end

  defp combine_surrogate_pairs([], acc), do: Enum.reverse(acc)

  # High surrogate (D800-DBFF) followed by low surrogate (DC00-DFFF)
  defp combine_surrogate_pairs(
         [{:codepoint, high}, {:codepoint, low} | rest],
         acc
       )
       when high >= 0xD800 and high <= 0xDBFF and low >= 0xDC00 and low <= 0xDFFF do
    import Bitwise
    # Decode surrogate pair: 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
    codepoint = 0x10000 + ((high - 0xD800) <<< 10) + (low - 0xDC00)
    combine_surrogate_pairs(rest, [{:codepoint, codepoint} | acc])
  end

  defp combine_surrogate_pairs([part | rest], acc) do
    combine_surrogate_pairs(rest, [part | acc])
  end

  # Convert parts back to binary
  defp parts_to_binary(parts) do
    parts
    |> Enum.map(fn
      {:text, str} -> str
      {:codepoint, cp} when cp >= 0xD800 and cp <= 0xDFFF -> <<cp::16>>
      {:codepoint, cp} -> <<cp::utf8>>
    end)
    |> IO.iodata_to_binary()
  end
end
