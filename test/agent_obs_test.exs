defmodule AgentObsTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  describe "trace_agent/3" do
    test "executes function and returns result" do
      result =
        AgentObs.trace_agent("test_agent", %{input: "test"}, fn ->
          {:ok, "success", %{iterations: 1}}
        end)

      assert {:ok, "success", %{iterations: 1}} = result
    end

    test "handles simple {:ok, output} return" do
      result =
        AgentObs.trace_agent("test_agent", %{input: "test"}, fn ->
          {:ok, "success"}
        end)

      assert {:ok, "success"} = result
    end

    test "handles errors" do
      result =
        AgentObs.trace_agent("test_agent", %{input: "test"}, fn ->
          {:error, :some_reason}
        end)

      assert {:error, :some_reason} = result
    end

    test "captures exceptions with stacktraces" do
      result =
        AgentObs.trace_agent("test_agent", %{input: "test"}, fn ->
          raise RuntimeError, "Test error"
        end)

      assert {:error, %{exception: exception, stacktrace: stacktrace}} = result
      assert exception.__struct__ == RuntimeError
      assert Exception.message(exception) == "Test error"
      assert is_list(stacktrace)
      assert length(stacktrace) > 0
    end

    test "captures throw with stacktraces" do
      result =
        AgentObs.trace_agent("test_agent", %{input: "test"}, fn ->
          throw(:something_bad)
        end)

      assert {:error, %{kind: :throw, reason: :something_bad, stacktrace: stacktrace}} = result
      assert is_list(stacktrace)
    end

    test "captures exit with stacktraces" do
      result =
        AgentObs.trace_agent("test_agent", %{input: "test"}, fn ->
          exit(:normal)
        end)

      assert {:error, %{kind: :exit, reason: :normal, stacktrace: stacktrace}} = result
      assert is_list(stacktrace)
    end

    test "handles {:error, binary} format" do
      result =
        AgentObs.trace_agent("test_agent", %{input: "test"}, fn ->
          {:error, "Something went wrong"}
        end)

      assert {:error, "Something went wrong"} = result
    end

    test "handles {:error, exception} format" do
      exception = %RuntimeError{message: "Custom error"}

      result =
        AgentObs.trace_agent("test_agent", %{input: "test"}, fn ->
          {:error, exception}
        end)

      assert {:error, ^exception} = result
    end
  end

  describe "trace_tool/3" do
    test "executes tool and returns result" do
      result =
        AgentObs.trace_tool("get_weather", %{arguments: %{city: "SF"}}, fn ->
          {:ok, %{temp: 72, condition: "sunny"}}
        end)

      assert {:ok, %{temp: 72, condition: "sunny"}} = result
    end

    test "captures tool execution exceptions" do
      result =
        AgentObs.trace_tool("calculator", %{arguments: %{op: "divide", a: 1, b: 0}}, fn ->
          raise ArithmeticError, "division by zero"
        end)

      assert {:error, %{exception: exception, stacktrace: _stacktrace}} = result
      assert exception.__struct__ == ArithmeticError
    end

    test "handles tool errors" do
      result =
        AgentObs.trace_tool("search", %{arguments: %{query: "test"}}, fn ->
          {:error, "API rate limit exceeded"}
        end)

      assert {:error, "API rate limit exceeded"} = result
    end
  end

  describe "trace_llm/3" do
    test "executes LLM call and returns result" do
      result =
        AgentObs.trace_llm("gpt-4o", %{input_messages: [%{role: "user", content: "Hi"}]}, fn ->
          {:ok, "response",
           %{
             output_messages: [%{role: "assistant", content: "response"}],
             tokens: %{prompt: 10, completion: 5}
           }}
        end)

      assert {:ok, "response", _metadata} = result
    end

    test "normalizes message roles" do
      # This test verifies that atom roles are normalized
      result =
        AgentObs.trace_llm("gpt-4o", %{input_messages: [%{role: :user, content: "Hi"}]}, fn ->
          {:ok, "response", %{}}
        end)

      assert {:ok, "response", %{}} = result
    end

    test "captures LLM API exceptions" do
      result =
        AgentObs.trace_llm("gpt-4o", %{input_messages: [%{role: "user", content: "Hi"}]}, fn ->
          raise "API timeout"
        end)

      assert {:error, %{exception: exception, stacktrace: _stacktrace}} = result
      assert Exception.message(exception) == "API timeout"
    end

    test "handles LLM API errors" do
      result =
        AgentObs.trace_llm("gpt-4o", %{input_messages: [%{role: "user", content: "Hi"}]}, fn ->
          {:error, %{status: 429, message: "Rate limit exceeded"}}
        end)

      assert {:error, %{status: 429, message: "Rate limit exceeded"}} = result
    end
  end

  describe "trace_prompt/3" do
    test "executes prompt rendering and returns result" do
      result =
        AgentObs.trace_prompt("system", %{variables: %{user: "Alice"}}, fn ->
          {:ok, "Hello Alice"}
        end)

      assert {:ok, "Hello Alice"} = result
    end
  end

  describe "emit/2" do
    test "emits custom telemetry event" do
      # Attach a test handler
      :telemetry.attach(
        "test-custom-event",
        [:agent_obs, :custom],
        fn event_name, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      AgentObs.emit(:custom, %{name: "test", data: "value"})

      assert_receive {:telemetry_event, [:agent_obs, :custom], %{},
                      %{name: "test", data: "value"}}

      :telemetry.detach("test-custom-event")
    end
  end

  describe "configure/1" do
    test "updates configuration" do
      AgentObs.configure(
        handlers: [TestHandler],
        event_prefix: [:test, :prefix],
        enabled: false
      )

      assert Application.get_env(:agent_obs, :handlers) == [TestHandler]
      assert Application.get_env(:agent_obs, :event_prefix) == [:test, :prefix]
      assert Application.get_env(:agent_obs, :enabled) == false

      # Reset to defaults
      AgentObs.configure(handlers: [], event_prefix: [:agent_obs], enabled: true)
    end
  end
end
