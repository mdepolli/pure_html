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

  @state_map %{
    "Data state" => :data,
    "RCDATA state" => :rcdata,
    "RAWTEXT state" => :rawtext,
    "Script data state" => :script_data,
    "PLAINTEXT state" => :plaintext,
    "CDATA section state" => :cdata_section
  }

  @doc """
  Runs every case of a fixture file in each of its initial states and returns
  one report per failing case. Set `HTML5LIB_CASE=file:index` (for example
  `test1:41`) to run a single case.
  """
  def failures(path) do
    filename = Path.basename(path, ".test")
    {tests, xml_violation_mode} = parse_file(path)

    tests
    |> Enum.with_index()
    |> Enum.filter(&selected?(filename, &1))
    |> Enum.flat_map(&case_runs(&1, xml_violation_mode))
    |> Enum.reject(&passes?/1)
    |> Enum.map(&failure_report(filename, &1))
  end

  defp selected?(filename, {_test, index}) do
    case System.get_env("HTML5LIB_CASE") do
      nil -> true
      only -> only == "#{filename}:#{index}"
    end
  end

  defp case_runs({test, index}, xml_violation_mode) do
    normalized = normalize_test(test)

    for state <- normalized.initial_states, state_atom = @state_map[state], state_atom != nil do
      opts =
        [initial_state: state_atom, xml_violation_mode: xml_violation_mode]
        |> put_last_start_tag(normalized.last_start_tag)

      {index, state, normalized, opts}
    end
  end

  defp put_last_start_tag(opts, nil), do: opts
  defp put_last_start_tag(opts, tag), do: Keyword.put(opts, :last_start_tag, tag)

  defp passes?({_index, _state, normalized, opts}) do
    actual_tokens(normalized, opts) == normalized.expected_tokens
  end

  defp actual_tokens(normalized, opts) do
    normalized.input
    |> PureHTML.Tokenizer.tokenize(opts)
    |> Enum.map(&sort_start_tag_attrs/1)
  end

  # Sort attrs in start tags for deterministic comparison
  defp sort_start_tag_attrs({:start_tag, name, attrs, self_closing}) do
    {:start_tag, name, Enum.sort(attrs), self_closing}
  end

  defp sort_start_tag_attrs(token), do: token

  defp failure_report(filename, {index, state, normalized, opts}) do
    """
    #{filename}:#{index} (#{state}): #{normalized.description}
    input:    #{inspect(normalized.input)}
    expected: #{inspect(normalized.expected_tokens)}
    actual:   #{inspect(actual_tokens(normalized, opts))}
    """
  end

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
      input: maybe_unescape_input(test["input"], double_escaped?),
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

  # Tokenizer input is a code-point stream. Double-escaped tests may include
  # unpaired surrogates, which cannot live in a UTF-8 binary.
  defp maybe_unescape_input(string, false), do: string
  defp maybe_unescape_input(string, true), do: unescape_unicode_codepoints(string)

  defp unescape_unicode_codepoints(string) when is_binary(string) do
    ~r/\\u([0-9A-Fa-f]{4})/
    |> Regex.split(string, include_captures: true)
    |> parse_unicode_parts()
    |> combine_surrogate_pairs()
    |> parts_to_codepoints()
  end

  defp parts_to_codepoints(parts) do
    Enum.flat_map(parts, fn
      {:text, str} -> String.to_charlist(str)
      {:codepoint, cp} -> [cp]
    end)
  end

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
