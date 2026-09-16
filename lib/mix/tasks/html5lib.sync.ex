defmodule Mix.Tasks.Html5lib.Sync do
  @shortdoc "Checks or moves the html5lib fixture pins"

  @moduledoc """
  The fixtures under `test/fixtures/html5lib/` are html5lib-tests, each
  directory at the commit `UPSTREAM` there pins for it, byte for byte. The
  cases whose expectation contradicts the WHATWG text are corrected by the
  runners from `test/fixtures/corrections/`, never by editing these files.

      mix html5lib.sync

  lists every fixture file that differs from upstream at its directory's
  pin and fails if there is one, so it can gate like `mix format
  --check-formatted`. Offline, it runs against the clone under `_build`
  when that already holds every pinned commit.

      mix html5lib.sync <commit>

  moves every directory the commit still has to that commit, replacing its
  files; a directory absent there (tree-construction after 9329e64) keeps
  its pin and its files. Then run the suite: a correction whose case
  upstream changed fails by name and needs a fresh walk.

  The clone lives under `_build`; `git -C <clone> show <commit>:<path>`
  prints any upstream version of a file.
  """

  use Mix.Task

  @fixtures Path.expand("test/fixtures/html5lib")
  @manifest Path.join(@fixtures, "UPSTREAM")
  @paths ~w(tree-construction tokenizer encoding serializer LICENSE)

  @impl Mix.Task
  def run(args) do
    clone = Path.join(Mix.Project.build_path(), "html5lib-tests")

    with {:ok, url, pins} <- read_manifest(@manifest),
         :ok <- fetch(clone, url, pins),
         :ok <- sync(args, clone, url, pins) do
      :ok
    else
      {:error, reason} -> Mix.raise(describe(reason))
    end
  end

  defp sync([], clone, _url, pins), do: report(differences(clone, pins), clone)
  defp sync([ref], clone, url, pins), do: move_pins(clone, url, pins, ref)
  defp sync(args, _clone, _url, _pins), do: {:error, {:usage, args}}

  defp read_manifest(path) do
    case File.read(path) do
      {:ok, text} -> parse_manifest(text, path)
      {:error, reason} -> {:error, {:manifest_unreadable, path, reason}}
    end
  end

  defp parse_manifest(text, path) do
    lines = String.split(text, "\n", trim: true)

    fields =
      for [key, value] <- Enum.map(lines, &String.split(&1, " ", parts: 2)),
          into: %{},
          do: {key, value}

    {url, pins} = Map.pop(fields, "url")

    if url != nil and Enum.all?(@paths, &Map.has_key?(pins, &1)) do
      {:ok, url, pins}
    else
      {:error, {:manifest_incomplete, path}}
    end
  end

  defp write_manifest(url, pins) do
    lines = for path <- @paths, do: "#{path} #{pins[path]}\n"
    File.write!(@manifest, "url #{url}\n" <> Enum.join(lines))
  end

  defp fetch(clone, url, pins) do
    case clone_once(clone, url) do
      :ok -> fetch_or_use_clone(clone, pins)
      {:error, _reason} = error -> error
    end
  end

  # Offline is fine for a check as long as the clone already has every pin.
  defp fetch_or_use_clone(clone, pins) do
    case git(clone, ["fetch", "--quiet", "origin"]) do
      :ok -> :ok
      {:error, reason} -> use_clone_if_pinned(clone, pins, reason)
    end
  end

  defp use_clone_if_pinned(clone, pins, fetch_error) do
    if Enum.all?(Map.values(pins), &match?({:ok, _sha}, resolve(clone, &1))) do
      Mix.shell().info("fetch failed; using the clone as it is")
      :ok
    else
      {:error, fetch_error}
    end
  end

  defp clone_once(clone, url) do
    if File.dir?(Path.join(clone, ".git")) do
      :ok
    else
      git(File.cwd!(), ["clone", "--quiet", "--no-checkout", url, clone])
    end
  end

  defp git(dir, args) do
    case git_output(dir, args) do
      {:ok, _output} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp git_output(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, {:git_failed, args, output}}
    end
  end

  # Report mode

  defp differences(clone, pins) do
    Enum.flat_map(@paths, fn path -> differences(clone, path, pins[path]) end)
  end

  defp differences(clone, path, commit) do
    upstream = upstream_files(clone, commit, path)
    vendored = vendored_files(path)

    upstream
    |> MapSet.union(vendored)
    |> Enum.sort()
    |> Enum.map(&{&1, status(&1, clone, commit, upstream, vendored)})
    |> Enum.reject(&match?({_file, :same}, &1))
  end

  defp status(path, clone, commit, upstream, vendored) do
    cond do
      path not in upstream -> :only_here
      path not in vendored -> :only_upstream
      upstream_file(clone, commit, path) == vendored_file(path) -> :same
      true -> :differs
    end
  end

  defp report([], _clone) do
    Mix.shell().info("test/fixtures/html5lib matches upstream at the pins in UPSTREAM")
  end

  defp report(differences, clone) do
    for {path, status} <- differences do
      Mix.shell().info("  #{status}  #{path}")
    end

    {:error, {:drift, length(differences), clone}}
  end

  # Move mode

  defp move_pins(clone, url, pins, ref) do
    case resolve(clone, ref) do
      {:ok, commit} -> move_pins_to(clone, url, pins, commit)
      {:error, _reason} = error -> error
    end
  end

  defp move_pins_to(clone, url, pins, commit) do
    {present, absent} =
      Enum.split_with(@paths, &(MapSet.size(upstream_files(clone, commit, &1)) > 0))

    outcomes = Enum.flat_map(present, &replace_directory(clone, &1, pins[&1], commit))
    moved = Map.new(present, &{&1, commit})

    write_manifest(url, Map.merge(pins, moved))
    report_move(outcomes, absent, pins, commit)
  end

  defp resolve(clone, ref) do
    case git_output(clone, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, _reason} -> {:error, {:unknown_commit, ref}}
    end
  end

  defp replace_directory(clone, path, pinned, commit) do
    before = upstream_files(clone, pinned, path)
    after_move = upstream_files(clone, commit, path)

    before
    |> MapSet.union(after_move)
    |> Enum.sort()
    |> Enum.map(&{&1, replace_file(&1, clone, commit, after_move)})
    |> Enum.reject(&match?({_file, :unchanged}, &1))
  end

  defp replace_file(file, clone, commit, after_move) do
    cond do
      file not in after_move -> remove_vendored(file)
      upstream_file(clone, commit, file) == vendored_file(file) -> :unchanged
      true -> write_vendored(file, upstream_file(clone, commit, file))
    end
  end

  defp report_move(outcomes, absent, pins, commit) do
    for path <- absent do
      Mix.shell().info("#{path} is absent upstream at #{commit}; kept at #{pins[path]}")
    end

    Mix.shell().info("#{length(outcomes)} file(s) changed:")

    for {file, outcome} <- outcomes do
      Mix.shell().info("  #{outcome}  #{file}")
    end

    Mix.shell().info("Run the suite: a correction whose case changed upstream fails by name.")
    :ok
  end

  # File access

  defp upstream_files(clone, commit, path) do
    case git_output(clone, ["ls-tree", "-r", "--name-only", commit, "--", path]) do
      {:ok, listing} -> MapSet.new(String.split(listing, "\n", trim: true))
      {:error, _reason} -> MapSet.new()
    end
  end

  defp upstream_file(clone, commit, path) do
    case git_output(clone, ["show", commit <> ":" <> path]) do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end

  defp vendored_files(path) do
    for file <- [Path.join(@fixtures, path) | Path.wildcard(Path.join([@fixtures, path, "**"]))],
        File.regular?(file),
        into: MapSet.new() do
      Path.relative_to(file, @fixtures)
    end
  end

  defp vendored_file(path) do
    case File.read(Path.join(@fixtures, path)) do
      {:ok, text} -> text
      {:error, :enoent} -> nil
    end
  end

  defp write_vendored(path, text) do
    file = Path.join(@fixtures, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, text)
    :written
  end

  defp remove_vendored(path) do
    File.rm!(Path.join(@fixtures, path))
    :removed
  end

  defp describe({:usage, args}),
    do: "expected no argument or one commit, got: #{Enum.join(args, " ")}"

  defp describe({:manifest_unreadable, path, reason}),
    do: "cannot read #{path}: #{:file.format_error(reason)}"

  defp describe({:manifest_incomplete, path}),
    do: "#{path} needs a url line and a commit for each of #{Enum.join(@paths, ", ")}"

  defp describe({:unknown_commit, ref}),
    do: "#{ref} is not a commit in the upstream clone; a fetch must succeed first"

  defp describe({:drift, count, clone}),
    do:
      "#{count} file(s) differ from upstream at their pins (clone in #{clone}); never edit test/fixtures/html5lib"

  defp describe({:git_failed, args, output}), do: "git #{Enum.join(args, " ")} failed:\n#{output}"
end
