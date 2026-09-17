defmodule PureHTML.Html5libTokenizerTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libTokenizerTests, as: H5

  # One test per fixture file; the cases and their initial states run in a loop
  # at run time. Generating a test function per case made compiling this file
  # the slowest part of the suite.
  for path <- H5.list_test_files() do
    filename = H5.fixture_name(path)

    @tag :html5lib
    @tag :tokenizer
    @tag test_file: filename
    test filename do
      failures = H5.failures(unquote(path))

      assert failures == [],
             "#{length(failures)} failing case(s):\n\n" <> Enum.join(failures, "\n")
    end

    # Cases whose error list omits an input stream error the text requires
    # (see H5.uncounted_input_stream_error_cases/1): the tokens run in the
    # file's test above, the count is reported as skipped with the citation.
    for {index, description} <- H5.uncounted_input_stream_error_cases(path) do
      @tag :html5lib
      @tag :tokenizer
      @tag test_file: filename
      @tag skip: "the fixture omits an input stream parse error the text requires"
      test "#{filename}:#{index} error count: #{description}" do
        flunk("the fixture omits an input stream parse error the text requires")
      end
    end

    # Cases whose input holds a lone surrogate are deferred to a later release:
    # UTF-8 strings cannot hold one (see H5.script_api_cases/1). One skipped
    # test each keeps them in the result line instead of inside a green count.
    for {index, description} <- H5.script_api_cases(path) do
      @tag :html5lib
      @tag :tokenizer
      @tag test_file: filename
      @tag skip: "deferred: a lone surrogate needs a text representation other than UTF-8"
      test "#{filename}:#{index} #{description}" do
        flunk("deferred: a lone surrogate needs a text representation other than UTF-8")
      end
    end
  end
end
