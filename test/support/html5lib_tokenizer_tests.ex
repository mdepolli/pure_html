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

  A fixture may have a corrections file of the same name under
  `test/fixtures/corrections/tokenizer/` (`<name>.json`, entries under
  `"corrections"`), one entry per case whose expectation contradicts the
  WHATWG text. An entry is keyed by `description` and `input`, cites the walk
  in `spec`, snapshots upstream's `output` and `errors` under `upstream`, and
  gives the text's `output` and `errors`. `parse_file/1` applies them; an
  entry that matches no case, or more than one, or whose snapshot no longer
  matches upstream, raises so the disagreement is re-walked rather than
  carried blindly.
  """

  @test_dir Path.expand("../fixtures/html5lib/tokenizer", __DIR__)
  @corrections_dir Path.expand("../fixtures/corrections/tokenizer", __DIR__)

  @doc "Returns the path to the tokenizer test directory."
  def test_dir, do: @test_dir
  def corrections_dir, do: @corrections_dir

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
    {tests, xml_violation_mode} =
      path
      |> File.read!()
      |> Jason.decode!()
      |> extract_tests()

    corrections_path = Path.join(@corrections_dir, Path.basename(path, ".test") <> ".json")
    {apply_corrections(tests, corrections_path), xml_violation_mode}
  end

  @doc "The entries of a corrections file: `description`, `input`, `spec`, `upstream`, `output`, `errors`."
  def parse_corrections(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("corrections")
  end

  defp apply_corrections(tests, corrections_path) do
    if File.exists?(corrections_path) do
      corrections_path
      |> parse_corrections()
      |> Enum.reduce(tests, &apply_correction(&2, &1, corrections_path))
    else
      tests
    end
  end

  defp apply_correction(tests, correction, source) do
    key = {correction["description"], correction["input"]}

    matches =
      for {test, index} <- Enum.with_index(tests),
          {test["description"], test["input"]} == key,
          do: index

    case matches do
      [index] -> List.update_at(tests, index, &correct(&1, correction, source))
      [] -> raise "#{source}: no case has description and input #{inspect(key)}"
      _many -> raise "#{source}: #{inspect(key)} matches more than one case"
    end
  end

  # The snapshot must still match upstream: a changed case means upstream
  # moved, and the correction needs a fresh walk, not blind reuse.
  defp correct(test, correction, source) do
    upstream = %{"output" => test["output"], "errors" => test["errors"] || []}

    if upstream != correction["upstream"] do
      raise "#{source}: #{inspect(test["input"])} changed upstream (#{inspect(upstream)}); re-walk it"
    end

    Map.merge(test, Map.take(correction, ["output", "errors", "spec"]))
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
    |> Enum.reject(fn {test, _index} -> needs_script_api?(test) end)
    |> Enum.flat_map(&case_runs(&1, xml_violation_mode, filename))
    |> Enum.reject(&passes?/1)
    |> Enum.map(&failure_report/1)
  end

  @doc """
  Cases of a fixture file whose input holds a lone surrogate, as
  `{index, description}`. They are deferred to a later release.

  Their input and expected character token both hold a code point UTF-8
  cannot encode, and this library's strings are UTF-8 binaries; supporting
  them needs a different text representation for input and tree. The text
  notes they never arise from bytes ("Surrogates can only find their way
  into the input stream via script APIs such as document.write()"). The
  test file reports each as skipped instead of running it.
  """
  def script_api_cases(path) do
    {tests, _xml_violation_mode} = parse_file(path)

    for {test, index} <- Enum.with_index(tests), needs_script_api?(test) do
      {index, test["description"]}
    end
  end

  defp needs_script_api?(%{"doubleEscaped" => true, "input" => input}) do
    input
    |> unicode_parts()
    |> Enum.any?(&match?({:codepoint, cp} when cp in 0xD800..0xDFFF, &1))
  end

  defp needs_script_api?(_test), do: false

  @doc """
  Cases whose expected error list contradicts "preprocessing the input
  stream", as `{index, description}`.

  "Any occurrences of noncharacters are noncharacter-in-input-stream parse
  errors and any occurrences of controls other than ASCII whitespace and
  U+0000 NULL characters are control-character-in-input-stream parse
  errors." A case whose input holds such a code point but whose error list
  has no entry for it disagrees with the text on the count; its tokens are
  still asserted, and the test file reports the count as skipped.
  """
  def uncounted_input_stream_error_cases(path) do
    {tests, _xml_violation_mode} = parse_file(path)

    for {test, index} <- Enum.with_index(tests),
        not needs_script_api?(test),
        omits_input_stream_error?(normalize_test(test)) do
      {index, test["description"]}
    end
  end

  @input_stream_error_codes ~w(noncharacter-in-input-stream control-character-in-input-stream)

  defp omits_input_stream_error?(normalized), do: omitted_input_stream_errors(normalized) > 0

  # How many input stream errors the text requires for the input beyond those
  # the fixture lists; zero for a fixture that agrees with the text.
  defp omitted_input_stream_errors(%{input: input, expected_errors: errors}) do
    codes = Enum.map(errors, & &1["code"])
    listed = Enum.count(codes, &(&1 in @input_stream_error_codes))

    max(input_stream_errors(input) - listed, 0)
  end

  defp input_stream_errors(input) do
    input
    |> String.to_charlist()
    |> Enum.count(&input_stream_error?/1)
  end

  # Noncharacters, then controls other than ASCII whitespace and U+0000.
  defp input_stream_error?(cp) when cp in 0xFDD0..0xFDEF, do: true

  defp input_stream_error?(cp) when is_integer(cp) and rem(cp, 0x10000) in [0xFFFE, 0xFFFF],
    do: true

  defp input_stream_error?(cp) when cp in 0x01..0x08 or cp == 0x0B or cp in 0x0E..0x1F, do: true
  defp input_stream_error?(cp) when cp in 0x7F..0x9F, do: true
  defp input_stream_error?(_cp), do: false

  defp selected?(filename, {_test, index}) do
    case System.get_env("HTML5LIB_CASE") do
      nil -> true
      only -> only == "#{filename}:#{index}"
    end
  end

  defp case_runs({test, index}, xml_violation_mode, filename) do
    normalized = normalize_test(test)

    for state <- normalized.initial_states, state_atom = @state_map[state], state_atom != nil do
      opts =
        [initial_state: state_atom, xml_violation_mode: xml_violation_mode]
        |> put_last_start_tag(normalized.last_start_tag)

      {index, state, normalized, opts, filename}
    end
  end

  defp put_last_start_tag(opts, nil), do: opts
  defp put_last_start_tag(opts, tag), do: Keyword.put(opts, :last_start_tag, tag)

  # Tokens always, and the count against the fixture's list plus the input
  # stream errors it omits (see uncounted_input_stream_error_cases/1), so a
  # classified case still catches any other surplus error.
  defp passes?({_index, _state, normalized, opts, _filename}) do
    {tokens, error_count} = actual(normalized, opts)

    tokens == normalized.expected_tokens and
      error_count == length(normalized.expected_errors) + omitted_input_stream_errors(normalized)
  end

  defp actual(normalized, opts) do
    {tokens, error_count} = PureHTML.Tokenizer.tokenize_with_errors(normalized.input, opts)
    {Enum.map(tokens, &sort_start_tag_attrs/1), error_count}
  end

  # Sort attrs in start tags for deterministic comparison
  defp sort_start_tag_attrs({:start_tag, name, attrs, self_closing}) do
    {:start_tag, name, Enum.sort(attrs), self_closing}
  end

  defp sort_start_tag_attrs(token), do: token

  defp failure_report({index, state, normalized, opts, filename}) do
    {tokens, error_count} = actual(normalized, opts)

    """
    #{filename}:#{index} (#{state}): #{normalized.description}
    input:    #{inspect(normalized.input)}
    expected: #{inspect(normalized.expected_tokens)} with #{length(normalized.expected_errors)} error(s)
    actual:   #{inspect(tokens)} with #{error_count} error(s)
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

  defp normalize_token(["ProcessingInstruction", target, data], double_escaped?) do
    {:pi, maybe_unescape(target, double_escaped?), maybe_unescape(data, double_escaped?)}
  end

  defp normalize_start_tag(name, attrs, self_closing) do
    attrs_list = attrs |> Map.to_list() |> Enum.sort()
    {:start_tag, name, attrs_list, self_closing}
  end

  # Unicode unescaping for doubleEscaped tests

  defp maybe_unescape(string, false), do: string
  defp maybe_unescape(string, true), do: unescape_unicode(string)

  defp unescape_unicode(string) when is_binary(string) do
    string
    |> unicode_parts()
    |> parts_to_binary()
  end

  defp unescape_unicode(other), do: other

  # Split on \uXXXX escapes into {:text, str} and {:codepoint, int} parts,
  # with UTF-16 surrogate pairs combined into one code point.
  defp unicode_parts(string) do
    ~r/\\u([0-9A-Fa-f]{4})/
    |> Regex.split(string, include_captures: true)
    |> parse_unicode_parts()
    |> combine_surrogate_pairs()
  end

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

  defp parts_to_binary(parts) do
    parts
    |> Enum.map(fn
      {:text, str} -> str
      {:codepoint, cp} -> <<cp::utf8>>
    end)
    |> IO.iodata_to_binary()
  end
end
