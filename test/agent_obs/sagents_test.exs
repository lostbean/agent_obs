defmodule AgentObs.SagentsTest do
  use ExUnit.Case, async: true

  alias LangChain.Message
  alias Sagents.State

  @moduletag :capture_log

  @sagents_available Code.ensure_loaded?(Sagents.Middleware)

  setup_all do
    unless @sagents_available do
      raise "Sagents not available — required for these tests"
    end

    :ok
  end

  describe "init/1" do
    test "initializes with default config" do
      {:ok, config} = AgentObs.Sagents.init(agent_id: "test-agent", model: nil)

      assert config.agent_id == "test-agent"
      assert config.trace_tools == true
    end

    test "initializes with custom options" do
      {:ok, config} =
        AgentObs.Sagents.init(
          agent_id: "test-agent",
          model: nil,
          trace_tools: false
        )

      assert config.trace_tools == false
    end

    test "extracts model from opts" do
      llm = struct!(LangChain.ChatModels.ChatAnthropic, model: "claude-sonnet-4-5-20250929")

      {:ok, config} = AgentObs.Sagents.init(agent_id: "test", model: llm)

      assert config.model == llm
    end
  end

  describe "on_server_start/2" do
    test "emits agent start event" do
      handler_id = "test-sagents-start-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:agent_obs, :agent],
        fn event_name, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      state = State.new!(%{agent_id: "test-agent"})
      config = %{agent_id: "test-agent", model: nil, trace_tools: true}

      {:ok, returned_state} = AgentObs.Sagents.on_server_start(state, config)

      assert returned_state == state

      assert_receive {:telemetry_event, [:agent_obs, :agent], %{},
                      %{name: "test-agent", input: "agent_started", event: :server_start}}

      :telemetry.detach(handler_id)
    end
  end

  describe "before_model/2" do
    test "emits agent start event and stores span context" do
      handler_id = "test-sagents-before-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:agent_obs, :agent, :start],
        fn _event_name, _measurements, metadata, _config ->
          send(self(), {:agent_start, metadata})
        end,
        nil
      )

      state =
        State.new!(%{
          agent_id: "test-agent",
          messages: [Message.new_user!("Hello")]
        })

      config = %{agent_id: "test-agent", model: nil, trace_tools: true}

      {:ok, returned_state} = AgentObs.Sagents.before_model(state, config)

      assert returned_state == state

      # Verify agent start event was emitted
      assert_receive {:agent_start, metadata}
      assert metadata.name == "test-agent"
      assert metadata.input == "Hello"
      assert is_integer(metadata.start_time)

      # Verify span context was stored
      span_key = {AgentObs.Sagents, :agent_span, "test-agent"}
      span_data = Process.get(span_key)
      assert span_data != nil
      assert span_data.message_count_before == 1

      # Clean up
      Process.delete(span_key)
      :telemetry.detach(handler_id)
    end
  end

  describe "after_model/2" do
    test "emits agent stop telemetry event with output" do
      handler_id = "test-sagents-agent-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:agent_obs, :agent, :start],
          [:agent_obs, :agent, :stop]
        ],
        fn event_name, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      config = %{agent_id: "test-agent", model: nil, trace_tools: true}

      # Simulate before_model with 1 message
      state_before =
        State.new!(%{
          agent_id: "test-agent",
          messages: [Message.new_user!("Hello")]
        })

      {:ok, _} = AgentObs.Sagents.before_model(state_before, config)

      # Simulate after_model with LLM response added
      state_after =
        State.new!(%{
          agent_id: "test-agent",
          messages: [
            Message.new_user!("Hello"),
            Message.new_assistant!("Hi there!")
          ]
        })

      {:ok, returned_state} = AgentObs.Sagents.after_model(state_after, config)

      assert returned_state == state_after

      # Agent start emitted in before_model
      assert_receive {:telemetry_event, [:agent_obs, :agent, :start], %{},
                      %{name: "test-agent", input: "Hello"}}

      # Agent stop emitted in after_model
      assert_receive {:telemetry_event, [:agent_obs, :agent, :stop], _measurements,
                      %{output: "Hi there!"}}

      :telemetry.detach(handler_id)
    end

    test "start event metadata contains start_time" do
      handler_id = "test-sagents-start-time-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:agent_obs, :agent, :start],
        fn _event_name, _measurements, metadata, _config ->
          send(self(), {:start_metadata, metadata})
        end,
        nil
      )

      config = %{agent_id: "test-start-time", model: nil, trace_tools: true}

      state_before =
        State.new!(%{
          agent_id: "test-start-time",
          messages: [Message.new_user!("Hello")]
        })

      {:ok, _} = AgentObs.Sagents.before_model(state_before, config)

      assert_receive {:start_metadata, metadata}
      assert is_integer(metadata.start_time)

      # Clean up the stored span data
      Process.delete({AgentObs.Sagents, :agent_span, "test-start-time"})
      :telemetry.detach(handler_id)
    end

    test "handles after_model without prior before_model gracefully" do
      config = %{agent_id: "no-before-agent", model: nil, trace_tools: true}

      state =
        State.new!(%{
          agent_id: "no-before-agent",
          messages: [Message.new_assistant!("Response")]
        })

      {:ok, returned_state} = AgentObs.Sagents.after_model(state, config)

      assert returned_state == state
    end

    test "extracts model name from config" do
      handler_id = "test-sagents-model-#{System.unique_integer()}"

      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:agent_obs, :agent, :start],
        fn _event_name, _measurements, metadata, _config ->
          if metadata[:name] == "test-model" do
            send(test_pid, {:model_name, metadata[:model]})
          end
        end,
        nil
      )

      llm = struct!(LangChain.ChatModels.ChatAnthropic, model: "claude-sonnet-4-5-20250929")
      config = %{agent_id: "test-model", model: llm, trace_tools: true}

      state_before = State.new!(%{agent_id: "test-model", messages: []})
      {:ok, _} = AgentObs.Sagents.before_model(state_before, config)

      assert_receive {:model_name, "anthropic/claude-sonnet-4-5-20250929"}

      # Clean up
      Process.delete({AgentObs.Sagents, :agent_span, "test-model"})
      :telemetry.detach(handler_id)
    end
  end

  describe "tools/1" do
    test "returns empty list" do
      config = %{agent_id: "test", model: nil, trace_tools: true}
      assert AgentObs.Sagents.tools(config) == []
    end
  end

  describe "callbacks/1" do
    test "returns a callback map with expected keys" do
      config = %{agent_id: "test", model: nil, trace_tools: true}
      callbacks = AgentObs.Sagents.callbacks(config)

      assert is_map(callbacks)
      assert Map.has_key?(callbacks, :on_message_processed)
      assert Map.has_key?(callbacks, :on_llm_token_usage)
      assert Map.has_key?(callbacks, :on_tool_response_created)
    end

    test "includes tool callbacks when trace_tools is true" do
      config = %{trace_tools: true}
      callbacks = AgentObs.Sagents.callbacks(config)

      assert Map.has_key?(callbacks, :on_tool_execution_started)
      assert Map.has_key?(callbacks, :on_tool_execution_completed)
      assert Map.has_key?(callbacks, :on_tool_execution_failed)
    end

    test "excludes tool callbacks when trace_tools is false" do
      config = %{trace_tools: false}
      callbacks = AgentObs.Sagents.callbacks(config)

      refute Map.has_key?(callbacks, :on_tool_execution_started)
      refute Map.has_key?(callbacks, :on_tool_execution_completed)
      refute Map.has_key?(callbacks, :on_tool_execution_failed)
    end
  end

  describe "on_fork_context/2" do
    test "adds a restore function to context" do
      config = %{agent_id: "test", model: nil, trace_tools: true}
      context = %{}

      updated = AgentObs.Sagents.on_fork_context(context, config)

      assert Map.has_key?(updated, :otel_ctx)
      assert Map.has_key?(updated, :__context_restore_fns__)
      assert length(updated.__context_restore_fns__) == 1
    end

    test "captures current OTel context" do
      config = %{agent_id: "test", model: nil, trace_tools: true}
      context = %{}

      # The OTel context should be a map (even if empty)
      updated = AgentObs.Sagents.on_fork_context(context, config)
      assert is_map(updated.otel_ctx)
    end
  end

  describe "middleware behaviour compliance" do
    test "implements Sagents.Middleware behaviour" do
      behaviours =
        AgentObs.Sagents.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Sagents.Middleware in behaviours
    end
  end
end
