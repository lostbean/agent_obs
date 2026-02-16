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

  describe "span context storage (stack-based)" do
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

    test "stores {span_ctx, parent_ctx} tuple as stack" do
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

      # Verify stack-based storage
      span_key = :agent_obs_phoenix_span_llm
      stored = Process.get(span_key)

      assert is_list(stored), "Expected list (stack), got #{inspect(stored)}"
      assert length(stored) == 1

      [{span_ctx, parent_ctx}] = stored
      assert is_tuple(span_ctx), "span_ctx should be tuple (OTel record)"
      assert is_map(parent_ctx), "parent_ctx should be map (OTel context)"
    end

    test "nested same-type spans push/pop correctly" do
      # Start outer tool span
      :telemetry.execute(
        [:test_ctx, :tool, :start],
        %{},
        %{name: "outer_tool", arguments: %{a: 1}}
      )

      # Start inner tool span (nested same type)
      :telemetry.execute(
        [:test_ctx, :tool, :start],
        %{},
        %{name: "inner_tool", arguments: %{b: 2}}
      )

      span_key = :agent_obs_phoenix_span_tool
      stack = Process.get(span_key)
      assert length(stack) == 2, "Expected 2 spans on stack"

      # Stop inner tool span
      :telemetry.execute(
        [:test_ctx, :tool, :stop],
        %{duration: 100_000_000},
        %{result: "inner_result"}
      )

      stack = Process.get(span_key)
      assert length(stack) == 1, "Expected 1 span on stack after inner stop"

      # Stop outer tool span
      :telemetry.execute(
        [:test_ctx, :tool, :stop],
        %{duration: 200_000_000},
        %{result: "outer_result"}
      )

      # Stack should be cleaned up
      assert Process.get(span_key) == nil
    end

    test "try/after restores context even when translator raises" do
      span_key = :agent_obs_phoenix_span_tool

      # Capture the OTel context before any spans
      ctx_before = OpenTelemetry.Ctx.get_current()

      # Start first span
      :telemetry.execute(
        [:test_ctx, :tool, :start],
        %{},
        %{name: "first_tool", arguments: %{}}
      )

      # Verify span was pushed onto the stack
      assert [{_span_ctx, _parent_ctx}] = Process.get(span_key)

      # Stop the span - the try/after in handle_stop should restore context
      :telemetry.execute(
        [:test_ctx, :tool, :stop],
        %{duration: 100_000_000},
        %{result: "ok"}
      )

      # Verify span key was cleaned up
      assert Process.get(span_key) == nil

      # Verify context was restored by starting and stopping a second span
      # successfully. If context was NOT restored, this would either fail
      # or produce orphaned/corrupted spans.
      :telemetry.execute(
        [:test_ctx, :tool, :start],
        %{},
        %{name: "second_tool", arguments: %{}}
      )

      assert [{_span_ctx2, _parent_ctx2}] = Process.get(span_key)

      :telemetry.execute(
        [:test_ctx, :tool, :stop],
        %{duration: 50_000_000},
        %{result: "also ok"}
      )

      # Second span also cleaned up properly
      assert Process.get(span_key) == nil

      # The current OTel context should be back to the original state
      # (no leftover span contexts polluting the process)
      ctx_after = OpenTelemetry.Ctx.get_current()
      assert ctx_before == ctx_after
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
      span_key = :agent_obs_phoenix_span_agent

      # Start agent span
      :telemetry.execute(
        [:test_status_ok, :agent, :start],
        %{},
        %{name: "test_agent", input: "test input"}
      )

      assert Process.get(span_key) != nil, "span should be on the stack after start"

      # Stop with success metadata
      :telemetry.execute(
        [:test_status_ok, :agent, :stop],
        %{duration: 1_000_000_000},
        %{output: "test output", iterations: 1}
      )

      # Verify the full start->stop flow completed including context cleanup
      assert Process.get(span_key) == nil, "span should be cleaned up after stop"
    end

    test "sets status OK for successful LLM call" do
      span_key = :agent_obs_phoenix_span_llm

      :telemetry.execute(
        [:test_status_ok, :llm, :start],
        %{},
        %{model: "gpt-4o", input_messages: [%{role: "user", content: "Hi"}]}
      )

      assert Process.get(span_key) != nil, "span should be on the stack after start"

      :telemetry.execute(
        [:test_status_ok, :llm, :stop],
        %{duration: 2_000_000_000},
        %{
          output_messages: [%{role: "assistant", content: "Hello"}],
          tokens: %{prompt: 10, completion: 5}
        }
      )

      assert Process.get(span_key) == nil, "span should be cleaned up after stop"
    end

    test "sets status OK for successful tool execution" do
      span_key = :agent_obs_phoenix_span_tool

      :telemetry.execute(
        [:test_status_ok, :tool, :start],
        %{},
        %{name: "get_weather", arguments: %{city: "SF"}}
      )

      assert Process.get(span_key) != nil, "span should be on the stack after start"

      :telemetry.execute(
        [:test_status_ok, :tool, :stop],
        %{duration: 500_000_000},
        %{result: %{temp: 72}}
      )

      assert Process.get(span_key) == nil, "span should be cleaned up after stop"
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
      span_key = :agent_obs_phoenix_span_agent

      :telemetry.execute(
        [:test_status_error, :agent, :start],
        %{},
        %{name: "test_agent", input: "test"}
      )

      assert Process.get(span_key) != nil, "span should be on the stack after start"

      # Stop with error in metadata
      :telemetry.execute(
        [:test_status_error, :agent, :stop],
        %{duration: 1_000_000_000},
        %{error: "Something went wrong"}
      )

      assert Process.get(span_key) == nil, "span should be cleaned up after error stop"
    end

    test "sets status ERROR when LLM metadata contains error" do
      span_key = :agent_obs_phoenix_span_llm

      :telemetry.execute(
        [:test_status_error, :llm, :start],
        %{},
        %{model: "gpt-4o", input_messages: []}
      )

      assert Process.get(span_key) != nil, "span should be on the stack after start"

      :telemetry.execute(
        [:test_status_error, :llm, :stop],
        %{duration: 1_000_000_000},
        %{error: %{status: 429, message: "Rate limit"}}
      )

      assert Process.get(span_key) == nil, "span should be cleaned up after error stop"
    end

    test "sets status ERROR when tool metadata contains error" do
      span_key = :agent_obs_phoenix_span_tool

      :telemetry.execute(
        [:test_status_error, :tool, :start],
        %{},
        %{name: "calculator", arguments: %{op: "divide", a: 1, b: 0}}
      )

      assert Process.get(span_key) != nil, "span should be on the stack after start"

      :telemetry.execute(
        [:test_status_error, :tool, :stop],
        %{duration: 100_000_000},
        %{error: "Division by zero"}
      )

      assert Process.get(span_key) == nil, "span should be cleaned up after error stop"
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
      span_key = :agent_obs_phoenix_span_agent

      :telemetry.execute(
        [:test_exception, :agent, :start],
        %{},
        %{name: "test_agent", input: "test"}
      )

      assert Process.get(span_key) != nil, "span should be on the stack after start"

      exception = %RuntimeError{message: "Test error"}
      stacktrace = [{Demo.Agent, :prompt, 2, [file: ~c"lib/demo/agent.ex", line: 100]}]

      :telemetry.execute(
        [:test_exception, :agent, :exception],
        %{duration: 500_000_000},
        %{kind: :error, reason: exception, stacktrace: stacktrace}
      )

      assert Process.get(span_key) == nil, "span should be cleaned up after exception"
    end

    test "handles LLM exception" do
      span_key = :agent_obs_phoenix_span_llm

      :telemetry.execute(
        [:test_exception, :llm, :start],
        %{},
        %{model: "gpt-4o", input_messages: []}
      )

      assert Process.get(span_key) != nil, "span should be on the stack after start"

      :telemetry.execute(
        [:test_exception, :llm, :exception],
        %{duration: 1_000_000_000},
        %{kind: :error, reason: %RuntimeError{message: "API timeout"}, stacktrace: []}
      )

      assert Process.get(span_key) == nil, "span should be cleaned up after exception"
    end

    test "handles tool exception with throw" do
      span_key = :agent_obs_phoenix_span_tool

      :telemetry.execute(
        [:test_exception, :tool, :start],
        %{},
        %{name: "search", arguments: %{query: "test"}}
      )

      assert Process.get(span_key) != nil, "span should be on the stack after start"

      :telemetry.execute(
        [:test_exception, :tool, :exception],
        %{duration: 200_000_000},
        %{kind: :throw, reason: :api_unavailable, stacktrace: []}
      )

      assert Process.get(span_key) == nil, "span should be cleaned up after exception"
    end

    test "handles exception with exit" do
      span_key = :agent_obs_phoenix_span_agent

      :telemetry.execute(
        [:test_exception, :agent, :start],
        %{},
        %{name: "test", input: "test"}
      )

      assert Process.get(span_key) != nil, "span should be on the stack after start"

      :telemetry.execute(
        [:test_exception, :agent, :exception],
        %{duration: 100_000_000},
        %{kind: :exit, reason: :normal, stacktrace: []}
      )

      assert Process.get(span_key) == nil, "span should be cleaned up after exception"
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
      span_key = :agent_obs_phoenix_span_agent

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

      assert Process.get(span_key) != nil, "span should be on the stack after start"

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

      assert Process.get(span_key) == nil, "span should be cleaned up after stop"
    end

    test "translates LLM metadata with gen_ai attributes" do
      span_key = :agent_obs_phoenix_span_llm

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

      assert Process.get(span_key) != nil, "span should be on the stack after start"

      :telemetry.execute(
        [:test_attrs, :llm, :stop],
        %{duration: 2_000_000_000},
        %{
          output_messages: [%{role: "assistant", content: "Response"}],
          tokens: %{prompt: 150, completion: 75},
          finish_reason: "stop"
        }
      )

      assert Process.get(span_key) == nil, "span should be cleaned up after stop"
    end

    test "translates tool metadata with parameters" do
      span_key = :agent_obs_phoenix_span_tool

      :telemetry.execute(
        [:test_attrs, :tool, :start],
        %{},
        %{
          name: "calculator",
          arguments: %{operation: "multiply", operands: [15, 7]},
          description: "A calculator tool"
        }
      )

      assert Process.get(span_key) != nil, "span should be on the stack after start"

      :telemetry.execute(
        [:test_attrs, :tool, :stop],
        %{duration: 100_000_000},
        %{result: 105}
      )

      assert Process.get(span_key) == nil, "span should be cleaned up after stop"
    end
  end
end
