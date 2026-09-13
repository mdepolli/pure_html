defmodule PureHTML.Html5libTreeConstructionTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libTreeConstructionTests, as: H5

  # One test per fixture file and scripting mode; the cases run in a loop at
  # run time. Generating a test function per case made compiling this file the
  # slowest part of the suite.
  for path <- H5.list_test_files(), {scripting, label} <- [{true, "on"}, {false, "off"}] do
    filename = Path.basename(path, ".dat")

    @tag :html5lib
    @tag :tree_construction
    @tag test_file: filename
    @tag scripting: String.to_atom(label)
    test "#{filename} [script-#{label}]" do
      failures = H5.failures(unquote(path), unquote(scripting))

      assert failures == [],
             "#{length(failures)} failing case(s):\n\n" <> Enum.join(failures, "\n")
    end
  end
end
