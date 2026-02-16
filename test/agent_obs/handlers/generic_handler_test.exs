defmodule AgentObs.Handlers.GenericHandlerTest do
  use ExUnit.Case, async: false

  alias AgentObs.Handlers.Generic

  @moduletag :capture_log

  describe "span context storage (stack-based)" do
    setup do
      config = %{event_prefix: [:test_generic_ctx]}
      {:ok, state} = Generic.attach(config)

      on_exit(fn ->
        Generic.detach(state)
        # Clean up any process dictionary keys
        Process.get_keys()
        |> Enum.filter(&match?(:agent_obs_generic_span_, &1))
        |> Enum.each(&Process.delete/1)
      end)

      %{state: state}
    end

    test "nested same-type spans push/pop correctly" do
      # Start outer tool span
      :telemetry.execute(
        [:test_generic_ctx, :tool, :start],
        %{},
        %{name: "outer_tool", arguments: %{a: 1}}
      )

      # Start inner tool span (nested same type)
      :telemetry.execute(
        [:test_generic_ctx, :tool, :start],
        %{},
        %{name: "inner_tool", arguments: %{b: 2}}
      )

      span_key = :agent_obs_generic_span_tool
      stack = Process.get(span_key)
      assert length(stack) == 2, "Expected 2 spans on stack"

      # Stop inner tool span
      :telemetry.execute(
        [:test_generic_ctx, :tool, :stop],
        %{duration: 100_000_000},
        %{result: "inner_result"}
      )

      stack = Process.get(span_key)
      assert length(stack) == 1, "Expected 1 span on stack after inner stop"

      # Stop outer tool span
      :telemetry.execute(
        [:test_generic_ctx, :tool, :stop],
        %{duration: 200_000_000},
        %{result: "outer_result"}
      )

      # Stack should be cleaned up
      assert Process.get(span_key) == nil
    end
  end
end
