defmodule PureHtml.MixProject do
  use Mix.Project

  def project do
    [
      app: :pure_html,
      version: "0.1.0",
      elixir: ">= 1.20.0-rc.0",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
