defmodule PureHtml.Html5libTokenizerTest do
  use ExUnit.Case, async: true

  alias PureHtml.Test.Html5libTokenizerTests, as: H5
  alias PureHtml.Tokenizer

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

    describe filename do
      for {test, index} <- Enum.with_index(H5.parse_file(path)) do
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

              opts = [initial_state: state_atom]

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
