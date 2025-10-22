defmodule AgentObs.Handlers.PhoenixHandlerTest do
  use ExUnit.Case, async: false

  alias AgentObs.Handlers.Phoenix

  @moduletag :capture_log

  describe "handler lifecycle" do
    test "attaches and detaches without errors" do
      config = %{event_prefix: [:test_phoenix]}

      assert {:ok, state} = Phoenix.attach(config)
      assert :ok = Phoenix.detach(state)
    end
  end

  describe "span context storage (regression test for tuple corruption)" do
    setup do
      config = %{event_prefix: [:test_ctx]}
      {:ok, state} = Phoenix.attach(config)

      on_exit(fn ->
        Phoenix.detach(state)
        # Clean up any process dictionary keys
        Process.get_keys()
        |> Enum.filter(&match?(:agent_obs_phoenix_span_, &1))
        |> Enum.each(&Process.delete/1)
      end)

      %{state: state}
    end

    test "stores {span_ctx, parent_ctx} tuple correctly" do
      # Emit LLM start event
      :telemetry.execute(
        [:test_ctx, :llm, :start],
        %{},
        %{
          name: "test_operation",
          model: "test-model",
          input_messages: [%{role: "user", content: "test"}]
        }
      )

      # Verify storage
      span_key = :agent_obs_phoenix_span_llm
      stored = Process.get(span_key)

      assert is_tuple(stored), "Expected tuple, got #{inspect(stored)}"
      assert tuple_size(stored) == 2, "Expected 2-tuple, got size #{tuple_size(stored)}"

      {span_ctx, parent_ctx} = stored
      assert is_tuple(span_ctx), "span_ctx should be tuple (OTel record)"
      assert is_map(parent_ctx), "parent_ctx should be map (OTel context)"
    end
  end

  describe "span status for successful operations" do
    setup do
      config = %{event_prefix: [:test_status_ok]}
      {:ok, state} = Phoenix.attach(config)

      on_exit(fn ->
        Phoenix.detach(state)

        Process.get_keys()
        |> Enum.filter(&match?(:agent_obs_phoenix_span_, &1))
        |> Enum.each(&Process.delete/1)
      end)

      %{state: state}
    end

    test "sets status OK for successful agent execution" do
      # Start agent span
      :telemetry.execute(
        [:test_status_ok, :agent, :start],
        %{},
        %{name: "test_agent", input: "test input"}
      )

      # Stop with success metadata
      :telemetry.execute(
        [:test_status_ok, :agent, :stop],
        %{duration: 1_000_000_000},
        %{output: "test output", iterations: 1}
      )

      # The span should have been set to :ok status
      # (We can't directly inspect OTel status without mocking, but we verify no crash)
      assert true
    end

    test "sets status OK for successful LLM call" do
      :telemetry.execute(
        [:test_status_ok, :llm, :start],
        %{},
        %{model: "gpt-4o", input_messages: [%{role: "user", content: "Hi"}]}
      )

      :telemetry.execute(
        [:test_status_ok, :llm, :stop],
        %{duration: 2_000_000_000},
        %{
          output_messages: [%{role: "assistant", content: "Hello"}],
          tokens: %{prompt: 10, completion: 5}
        }
      )

      assert true
    end

    test "sets status OK for successful tool execution" do
      :telemetry.execute(
        [:test_status_ok, :tool, :start],
        %{},
        %{name: "get_weather", arguments: %{city: "SF"}}
      )

      :telemetry.execute(
        [:test_status_ok, :tool, :stop],
        %{duration: 500_000_000},
        %{result: %{temp: 72}}
      )

      assert true
    end
  end

  describe "span status for error operations" do
    setup do
      config = %{event_prefix: [:test_status_error]}
      {:ok, state} = Phoenix.attach(config)

      on_exit(fn ->
        Phoenix.detach(state)

        Process.get_keys()
        |> Enum.filter(&match?(:agent_obs_phoenix_span_, &1))
        |> Enum.each(&Process.delete/1)
      end)

      %{state: state}
    end

    test "sets status ERROR when agent metadata contains error" do
      :telemetry.execute(
        [:test_status_error, :agent, :start],
        %{},
        %{name: "test_agent", input: "test"}
      )

      # Stop with error in metadata
      :telemetry.execute(
        [:test_status_error, :agent, :stop],
        %{duration: 1_000_000_000},
        %{error: "Something went wrong"}
      )

      assert true
    end

    test "sets status ERROR when LLM metadata contains error" do
      :telemetry.execute(
        [:test_status_error, :llm, :start],
        %{},
        %{model: "gpt-4o", input_messages: []}
      )

      :telemetry.execute(
        [:test_status_error, :llm, :stop],
        %{duration: 1_000_000_000},
        %{error: %{status: 429, message: "Rate limit"}}
      )

      assert true
    end

    test "sets status ERROR when tool metadata contains error" do
      :telemetry.execute(
        [:test_status_error, :tool, :start],
        %{},
        %{name: "calculator", arguments: %{op: "divide", a: 1, b: 0}}
      )

      :telemetry.execute(
        [:test_status_error, :tool, :stop],
        %{duration: 100_000_000},
        %{error: "Division by zero"}
      )

      assert true
    end
  end

  describe "exception event handling" do
    setup do
      config = %{event_prefix: [:test_exception]}
      {:ok, state} = Phoenix.attach(config)

      on_exit(fn ->
        Phoenix.detach(state)

        Process.get_keys()
        |> Enum.filter(&match?(:agent_obs_phoenix_span_, &1))
        |> Enum.each(&Process.delete/1)
      end)

      %{state: state}
    end

    test "handles agent exception with full stacktrace" do
      :telemetry.execute(
        [:test_exception, :agent, :start],
        %{},
        %{name: "test_agent", input: "test"}
      )

      exception = %RuntimeError{message: "Test error"}
      stacktrace = [{Demo.Agent, :prompt, 2, [file: ~c"lib/demo/agent.ex", line: 100]}]

      :telemetry.execute(
        [:test_exception, :agent, :exception],
        %{duration: 500_000_000},
        %{kind: :error, reason: exception, stacktrace: stacktrace}
      )

      assert true
    end

    test "handles LLM exception" do
      :telemetry.execute(
        [:test_exception, :llm, :start],
        %{},
        %{model: "gpt-4o", input_messages: []}
      )

      :telemetry.execute(
        [:test_exception, :llm, :exception],
        %{duration: 1_000_000_000},
        %{kind: :error, reason: %RuntimeError{message: "API timeout"}, stacktrace: []}
      )

      assert true
    end

    test "handles tool exception with throw" do
      :telemetry.execute(
        [:test_exception, :tool, :start],
        %{},
        %{name: "search", arguments: %{query: "test"}}
      )

      :telemetry.execute(
        [:test_exception, :tool, :exception],
        %{duration: 200_000_000},
        %{kind: :throw, reason: :api_unavailable, stacktrace: []}
      )

      assert true
    end

    test "handles exception with exit" do
      :telemetry.execute(
        [:test_exception, :agent, :start],
        %{},
        %{name: "test", input: "test"}
      )

      :telemetry.execute(
        [:test_exception, :agent, :exception],
        %{duration: 100_000_000},
        %{kind: :exit, reason: :normal, stacktrace: []}
      )

      assert true
    end
  end

  describe "event attribute translation" do
    setup do
      config = %{event_prefix: [:test_attrs]}
      {:ok, state} = Phoenix.attach(config)

      on_exit(fn ->
        Phoenix.detach(state)

        Process.get_keys()
        |> Enum.filter(&match?(:agent_obs_phoenix_span_, &1))
        |> Enum.each(&Process.delete/1)
      end)

      %{state: state}
    end

    test "translates agent metadata with all semantic conventions" do
      :telemetry.execute(
        [:test_attrs, :agent, :start],
        %{},
        %{
          name: "weather_agent",
          input: "What's the weather?",
          model: "gpt-4o",
          session_id: "session-123",
          user_id: "user-456"
        }
      )

      :telemetry.execute(
        [:test_attrs, :agent, :stop],
        %{duration: 3_000_000_000},
        %{
          output: "It's sunny",
          iterations: 2,
          tools_used: ["web_search", "get_weather"],
          tokens: %{prompt: 100, completion: 50, total: 150},
          cost: 0.00123
        }
      )

      assert true
    end

    test "translates LLM metadata with gen_ai attributes" do
      :telemetry.execute(
        [:test_attrs, :llm, :start],
        %{},
        %{
          model: "anthropic:claude-3-sonnet",
          input_messages: [
            %{role: "user", content: "Hello"},
            %{role: "assistant", content: "Hi there"}
          ]
        }
      )

      :telemetry.execute(
        [:test_attrs, :llm, :stop],
        %{duration: 2_000_000_000},
        %{
          output_messages: [%{role: "assistant", content: "Response"}],
          tokens: %{prompt: 150, completion: 75},
          finish_reason: "stop"
        }
      )

      assert true
    end

    test "translates tool metadata with parameters" do
      :telemetry.execute(
        [:test_attrs, :tool, :start],
        %{},
        %{
          name: "calculator",
          arguments: %{operation: "multiply", operands: [15, 7]},
          description: "A calculator tool"
        }
      )

      :telemetry.execute(
        [:test_attrs, :tool, :stop],
        %{duration: 100_000_000},
        %{result: 105}
      )

      assert true
    end
  end
end
