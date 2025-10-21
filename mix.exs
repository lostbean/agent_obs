defmodule AgentObs.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/your-org/agent_obs"

  def project do
    [
      app: :agent_obs,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      aliases: aliases(),
      preferred_cli_env: [
        precommit: :test,
        ci: :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AgentObs.Application, []}
    ]
  end

  defp deps do
    [
      # Core telemetry and OpenTelemetry dependencies
      {:telemetry, "~> 1.0"},
      {:opentelemetry_api, "~> 1.2"},
      {:opentelemetry, "~> 1.3"},
      {:opentelemetry_exporter, "~> 1.6"},
      {:jason, "~> 1.2"},

      # Development and testing dependencies
      {:ex_doc, "~> 0.28", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    A production-grade Elixir library for LLM agent observability.
    Provides instrumentation for agent loops, tool calls, and LLM requests
    with support for OpenTelemetry and OpenInference semantic conventions.
    """
  end

  defp package do
    [
      name: "agent_obs",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/agent_obs"
      },
      maintainers: ["Your Name"]
    ]
  end

  defp docs do
    [
      main: "AgentObs",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md"
      ]
    ]
  end

  defp aliases do
    [
      # Pre-commit hook: format code, run tests, check code quality
      precommit: [
        "format",
        "test",
        "credo --strict"
      ],
      # CI pipeline: check formatting, run tests, check code quality
      ci: [
        "format --check-formatted",
        "test",
        "credo --strict"
      ]
    ]
  end
end
