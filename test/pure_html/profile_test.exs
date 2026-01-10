defmodule PureHtml.ProfileTest do
  use ExUnit.Case, async: true

  @moduletag :profile

  setup_all do
    html = File.read!("test/fixtures/wikipedia_homepage.html")
    %{html: html}
  end

  test "profile tokenizer with fprof", %{html: html} do
    IO.puts("\nProfiling tokenizer on #{byte_size(html)} bytes...")

    :fprof.trace([:start, {:procs, self()}])
    html |> PureHtml.Tokenizer.tokenize() |> Enum.to_list()
    :fprof.trace(:stop)

    :fprof.profile()
    :fprof.analyse(totals: true, sort: :own)
  end

  test "profile tree builder with fprof", %{html: html} do
    tokens = html |> PureHtml.Tokenizer.tokenize() |> Enum.to_list()

    IO.puts("\nProfiling tree builder on #{length(tokens)} tokens...")

    :fprof.trace([:start, {:procs, self()}])
    PureHtml.TreeBuilder.build(tokens)
    :fprof.trace(:stop)

    :fprof.profile()
    :fprof.analyse(totals: true, sort: :own)
  end
end
