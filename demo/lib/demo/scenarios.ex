defmodule Demo.Scenarios do
  @moduledoc """
  Pre-built demo scenarios showcasing AgentObs instrumentation.
  """

  @doc """
  Calculator demo - showcases tool calling with math operations.
  """
  def calculator_demo do
    IO.puts("\n🧮 Scenario 1: Calculator Demo")
    IO.puts("-" <> String.duplicate("-", 50))

    {:ok, agent} = Demo.Agent.start_link()

    questions = [
      "What is 15 multiplied by 7?",
      "Calculate the square root of 144",
      "What's 100 divided by 4, then add 25?"
    ]

    Enum.each(questions, fn question ->
      IO.puts("\n💬 User: #{question}")
      IO.write("🤖 Agent: ")

      case Demo.Agent.prompt(agent, question) do
        {:ok, _response} ->
          IO.puts(" ✓")

        {:error, error} ->
          IO.puts("\n❌ Error: #{inspect(error)}")
      end

      Process.sleep(1000)
    end)

    GenServer.stop(agent)
  end

  @doc """
  Weather demo - showcases information retrieval (mocked web search).
  """
  def weather_demo do
    IO.puts("\n🌤️  Scenario 2: Weather Demo")
    IO.puts("-" <> String.duplicate("-", 50))

    {:ok, agent} = Demo.Agent.start_link()

    questions = [
      "Search for current weather conditions in San Francisco",
      "What's the weather like in Tokyo?"
    ]

    Enum.each(questions, fn question ->
      IO.puts("\n💬 User: #{question}")
      IO.write("🤖 Agent: ")

      case Demo.Agent.prompt(agent, question) do
        {:ok, _response} ->
          IO.puts(" ✓")

        {:error, error} ->
          IO.puts("\n❌ Error: #{inspect(error)}")
      end

      Process.sleep(1000)
    end)

    GenServer.stop(agent)
  end

  @doc """
  Multi-step demo - complex agent loop with multiple tool calls.
  """
  def multi_step_demo do
    IO.puts("\n🔄 Scenario 3: Multi-Step Demo")
    IO.puts("-" <> String.duplicate("-", 50))

    {:ok, agent} = Demo.Agent.start_link()

    question = """
    First, calculate 25 * 4. Then, search for information about that number's \
    significance in mathematics. Finally, calculate the square root of that number.
    """

    IO.puts("\n💬 User: #{String.trim(question)}")
    IO.write("🤖 Agent: ")

    case Demo.Agent.prompt(agent, question) do
      {:ok, _response} ->
        IO.puts(" ✓")

      {:error, error} ->
        IO.puts("\n❌ Error: #{inspect(error)}")
    end

    GenServer.stop(agent)
  end

  @doc """
  Run a custom question against the agent.
  """
  def custom(question) when is_binary(question) do
    IO.puts("\n💭 Custom Question Demo")
    IO.puts("-" <> String.duplicate("-", 50))

    {:ok, agent} = Demo.Agent.start_link()

    IO.puts("\n💬 User: #{question}")
    IO.write("🤖 Agent: ")

    result =
      case Demo.Agent.prompt(agent, question) do
        {:ok, response} ->
          IO.puts(" ✓\n")
          {:ok, response}

        {:error, error} ->
          IO.puts("\n❌ Error: #{inspect(error)}")
          {:error, error}
      end

    GenServer.stop(agent)
    result
  end

  @doc """
  Run all demo scenarios sequentially.
  """
  def run_all do
    calculator_demo()
    weather_demo()
    multi_step_demo()

    IO.puts("\n" <> String.duplicate("=", 52))
    IO.puts("✅ All scenarios completed!")
    IO.puts("\n📊 View traces at:")
    IO.puts("  • Arize Phoenix: http://localhost:6006")
    IO.puts("  • Jaeger:        http://localhost:16686")
    IO.puts("")
  end
end
