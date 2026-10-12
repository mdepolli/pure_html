defmodule PureHTML.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/mdepolli/pure_html"

  def project do
    [
      app: :pure_html,
      version: @version,
      elixir: ">= 1.20.0",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "PureHTML",
      description: "A pure Elixir HTML5 parser. No NIFs. No native dependencies. Just Elixir.",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger] ++ extra_applications(Mix.env())
    ]
  end

  defp extra_applications(env) when env in [:dev, :test], do: [:tools, :runtime_tools]
  defp extra_applications(_), do: []

  defp deps do
    [
      # Dev/Test
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:jason, "~> 1.4", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:test]}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      files: ~w(
        lib/pure_html lib/pure_html.ex .formatter.exs mix.exs
        README.md LICENSE CHANGELOG.md ROADMAP.md guides
      ),
      maintainers: ["Marcelo De Polli"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md": [title: "Overview"],
        "guides/querying.md": [title: "Querying HTML"],
        "ROADMAP.md": [title: "Roadmap"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"]
      ],
      # The html5lib.sync task is development tooling, not part of the package.
      filter_modules: ~r/^Elixir\.PureHTML/,
      # Changelog entries name modules that were public when they were written.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      formatters: ["html"]
    ]
  end
end
