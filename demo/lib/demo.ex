defmodule Demo do
  @moduledoc """
  AgentObs demo application showcasing LLM agent observability.

  This demo includes:
  - Instrumented req_llm agent with AgentObs
  - Dual-backend observability (Arize Phoenix + Jaeger)
  - Multiple demo scenarios
  """

  @doc """
  Run all demo scenarios.
  """
  def run_all do
    IO.puts("\n🎯 AgentObs Demo - Running All Scenarios\n")
    IO.puts("=" <> String.duplicate("=", 50))

    Demo.Scenarios.calculator_demo()
    Demo.Scenarios.weather_demo()
    Demo.Scenarios.multi_step_demo()

    IO.puts("\n✅ All demos completed!")
    IO.puts("\n📊 View traces:")
    IO.puts("  • Arize Phoenix: http://localhost:6006")
    IO.puts("  • Jaeger:        http://localhost:16686")
    IO.puts("")
  end
end
