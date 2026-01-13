alias PureHTML.{Tokenizer, TreeBuilder}

html = File.read!("test/fixtures/wikipedia_homepage.html")

IO.puts("File size: #{byte_size(html)} bytes\n")

case System.argv() do
  ["tokenizer"] ->
    IO.puts("Profiling tokenizer...")
    :fprof.trace([:start, {:procs, self()}])
    html |> Tokenizer.tokenize() |> Enum.to_list()
    :fprof.trace(:stop)
    :fprof.profile()
    :fprof.analyse(totals: true, sort: :own)

  ["full"] ->
    IO.puts("Profiling full parse (tokenizer + tree builder)...")
    :fprof.trace([:start, {:procs, self()}])
    html |> Tokenizer.new() |> TreeBuilder.build()
    :fprof.trace(:stop)
    :fprof.profile()
    :fprof.analyse(totals: true, sort: :own)

  _ ->
    IO.puts("""
    Usage: mix run bench/profile.exs <target>

    Targets:
      tokenizer  - Profile tokenizer only
      full       - Profile full parse (tokenizer + tree builder)
    """)
end
