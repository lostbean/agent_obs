defmodule Demo.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :opentelemetry_exporter, :opentelemetry],
      mod: {Demo.Application, []}
    ]
  end

  defp deps do
    [
      # Local AgentObs library
      {:agent_obs, path: ".."},

      # LLM interaction
      {:req_llm, "~> 1.0.0-rc.7"}
    ]
  end
end
