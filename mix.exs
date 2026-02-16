defmodule AgentObs.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/lostbean/agent_obs"

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
      aliases: aliases()
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

      # Optional dependencies for integrations
      {:req_llm, "~> 1.0", optional: true},
      {:langchain, "~> 0.5 or ~> 0.6", optional: true},
      {:sagents, github: "lostbean/sagents", branch: "preview/all-features", optional: true},

      # Horde needed for sagents compilation (optional in sagents)
      {:horde, "~> 0.10", optional: true},

      # Development and testing dependencies
      {:ex_doc, "~> 0.28", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:req_cassette, "~> 0.5", only: :test}
    ]
  end

  defp description do
    """
    An Elixir library for LLM agent observability.
    Provides instrumentation for agent loops, tool calls, and LLM requests
    with support for OpenTelemetry and OpenInference semantic conventions.
    """
  end

  defp package do
    [
      name: "agent_obs",
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/agent_obs"
      },
      maintainers: ["Your Name"]
    ]
  end

  defp docs do
    [
      main: "home",
      name: "AgentObs",
      source_url: @source_url,
      source_ref: "v#{@version}",
      homepage_url: @source_url,
      formatters: ["html"],
      extras: [
        "home.md",
        "README.md",
        "CHANGELOG.md",
        "guides/getting_started.md",
        "guides/configuration.md",
        "guides/instrumentation.md",
        "guides/req_llm_integration.md",
        "guides/langchain_sagents.md",
        "guides/custom_handlers.md"
      ],
      groups_for_extras: [
        Guides: [
          "guides/getting_started.md",
          "guides/configuration.md",
          "guides/instrumentation.md",
          "guides/req_llm_integration.md",
          "guides/langchain_sagents.md",
          "guides/custom_handlers.md"
        ]
      ],
      groups_for_modules: [
        "Core API": [
          AgentObs,
          AgentObs.Events
        ],
        Handlers: [
          AgentObs.Handler,
          AgentObs.Handlers.Phoenix,
          AgentObs.Handlers.Generic,
          AgentObs.Handlers.Phoenix.Translator
        ],
        Integrations: [
          AgentObs.ReqLLM,
          AgentObs.LangChain,
          AgentObs.Sagents
        ],
        Infrastructure: [
          AgentObs.Application,
          AgentObs.Supervisor
        ]
      ]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test, ci: :test]]
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
