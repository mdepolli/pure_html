defmodule PureHTML.Html5libTokenizerTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libTokenizerTests, as: H5
  alias PureHTML.Tokenizer

  # Map html5lib state names to our atom names
  @state_map %{
    "Data state" => :data,
    "RCDATA state" => :rcdata,
    "RAWTEXT state" => :rawtext,
    "Script data state" => :script_data,
    "PLAINTEXT state" => :plaintext
  }

  for path <- H5.list_test_files() do
    filename = Path.basename(path, ".test")
    {tests, xml_violation_mode} = H5.parse_file(path)

    describe filename do
      for {test, index} <- Enum.with_index(tests) do
        normalized = H5.normalize_test(test)
        description = normalized.description || "test #{index}"

        for initial_state <- normalized.initial_states do
          state_atom = @state_map[initial_state]

          # Only run tests for states we support
          if state_atom == :data do
            @tag :html5lib
            @tag :tokenizer
            @tag test_file: filename
            test "##{index}: #{description} (#{initial_state})" do
              normalized = unquote(Macro.escape(normalized))
              state_atom = unquote(state_atom)
              xml_violation_mode = unquote(xml_violation_mode)

              opts = [initial_state: state_atom, xml_violation_mode: xml_violation_mode]

              opts =
                if normalized.last_start_tag do
                  Keyword.put(opts, :last_start_tag, normalized.last_start_tag)
                else
                  opts
                end

              actual =
                normalized.input
                |> Tokenizer.tokenize(opts)
                |> Enum.to_list()

              assert actual == normalized.expected_tokens
            end
          end
        end
      end
    end
  end
end
