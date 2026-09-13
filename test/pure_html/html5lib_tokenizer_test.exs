defmodule PureHTML.Html5libTokenizerTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libTokenizerTests, as: H5

  # One test per fixture file; the cases and their initial states run in a loop
  # at run time. Generating a test function per case made compiling this file
  # the slowest part of the suite.
  for path <- H5.list_test_files() do
    filename = Path.basename(path, ".test")

    @tag :html5lib
    @tag :tokenizer
    @tag test_file: filename
    test filename do
      failures = H5.failures(unquote(path))

      assert failures == [],
             "#{length(failures)} failing case(s):\n\n" <> Enum.join(failures, "\n")
    end
  end
end
