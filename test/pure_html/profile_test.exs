defmodule PureHTML.ProfileTest do
  use ExUnit.Case, async: true

  @moduletag :profile

  setup_all do
    html = File.read!("test/fixtures/wikipedia_homepage.html")
    %{html: html}
  end

  test "profile tokenizer with fprof", %{html: html} do
    IO.puts("\nProfiling tokenizer on #{byte_size(html)} bytes...")

    :fprof.trace([:start, {:procs, self()}])
    html |> PureHTML.Tokenizer.tokenize() |> Enum.to_list()
    :fprof.trace(:stop)

    :fprof.profile()
    :fprof.analyse(totals: true, sort: :own)
  end

  test "profile full parse with fprof", %{html: html} do
    tokenizer = PureHTML.Tokenizer.new(html)

    IO.puts("\nProfiling full parse (tokenizer + tree builder) on #{byte_size(html)} bytes...")

    :fprof.trace([:start, {:procs, self()}])
    PureHTML.TreeBuilder.build(tokenizer)
    :fprof.trace(:stop)

    :fprof.profile()
    :fprof.analyse(totals: true, sort: :own)
  end
end
