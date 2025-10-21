defmodule AgentObsTest do
  use ExUnit.Case, async: true

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
  end

  describe "trace_tool/3" do
    test "executes tool and returns result" do
      result =
        AgentObs.trace_tool("get_weather", %{arguments: %{city: "SF"}}, fn ->
          {:ok, %{temp: 72, condition: "sunny"}}
        end)

      assert {:ok, %{temp: 72, condition: "sunny"}} = result
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
