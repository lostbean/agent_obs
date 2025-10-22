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
end
