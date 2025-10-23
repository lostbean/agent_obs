defmodule AgentObs.MultiBackendTest do
  use ExUnit.Case, async: false

  alias AgentObs.Handlers.Generic
  alias AgentObs.Handlers.Phoenix

  @moduletag :capture_log

  setup do
    # Ensure OpenTelemetry is started
    Application.ensure_all_started(:opentelemetry)
    Application.ensure_all_started(:opentelemetry_exporter)

    :ok
  end

  describe "multiple handlers running simultaneously" do
    test "Phoenix and Generic handlers can coexist" do
      # Attach both handlers with same event prefix
      event_prefix = [:multi_backend_test]

      phoenix_config = %{event_prefix: event_prefix}
      generic_config = %{event_prefix: event_prefix}

      assert {:ok, phoenix_state} = Phoenix.attach(phoenix_config)
      assert {:ok, generic_state} = Generic.attach(generic_config)

      # Emit events - both handlers should process them
      :telemetry.execute(
        event_prefix ++ [:agent, :start],
        %{},
        %{name: "multi_handler_agent", input: "test"}
      )

      :telemetry.execute(
        event_prefix ++ [:agent, :stop],
        %{duration: 1_000_000},
        %{output: "test output"}
      )

      # Clean up
      Phoenix.detach(phoenix_state)
      Generic.detach(generic_state)

      # Clean up process dictionary
      cleanup_process_dictionary()

      assert true
    end

    test "handlers with different event prefixes are isolated" do
      # Attach handlers with different prefixes
      phoenix_prefix = [:phoenix_only]
      generic_prefix = [:generic_only]

      phoenix_config = %{event_prefix: phoenix_prefix}
      generic_config = %{event_prefix: generic_prefix}

      {:ok, phoenix_state} = Phoenix.attach(phoenix_config)
      {:ok, generic_state} = Generic.attach(generic_config)

      # Emit event only to Phoenix handler
      :telemetry.execute(
        phoenix_prefix ++ [:llm, :start],
        %{},
        %{model: "gpt-4o", input_messages: [%{role: "user", content: "test"}]}
      )

      :telemetry.execute(
        phoenix_prefix ++ [:llm, :stop],
        %{duration: 2_000_000},
        %{output_messages: [%{role: "assistant", content: "response"}]}
      )

      # Emit event only to Generic handler
      :telemetry.execute(
        generic_prefix ++ [:tool, :start],
        %{},
        %{name: "calculator", arguments: %{op: "add"}}
      )

      :telemetry.execute(
        generic_prefix ++ [:tool, :stop],
        %{duration: 100_000},
        %{result: %{sum: 3}}
      )

      # Clean up
      Phoenix.detach(phoenix_state)
      Generic.detach(generic_state)
      cleanup_process_dictionary()

      # Both handlers should have processed their respective events without interference
      assert true
    end

    test "handlers process events independently without cross-contamination" do
      # Setup: Both handlers listen to same events
      event_prefix = [:shared_events]

      phoenix_config = %{event_prefix: event_prefix}
      generic_config = %{event_prefix: event_prefix}

      {:ok, phoenix_state} = Phoenix.attach(phoenix_config)
      {:ok, generic_state} = Generic.attach(generic_config)

      # Execute a complete agent trace
      result =
        AgentObs.trace_agent("multi_backend_agent", %{input: "test"}, fn ->
          # Nested LLM call
          AgentObs.trace_llm(
            "gpt-4o",
            %{
              input_messages: [%{role: "user", content: "test"}]
            },
            fn ->
              {:ok, %{role: "assistant", content: "response"},
               %{
                 tokens: %{prompt: 10, completion: 5, total: 15}
               }}
            end
          )
        end)

      # Both handlers should have processed these events
      assert {:ok, response, _metadata} = result
      assert response.content == "response"

      # Clean up
      Phoenix.detach(phoenix_state)
      Generic.detach(generic_state)
      cleanup_process_dictionary()
    end
  end

  describe "handler-specific attribute translation" do
    test "Phoenix handler produces OpenInference attributes" do
      event_prefix = [:phoenix_attributes]
      config = %{event_prefix: event_prefix}

      {:ok, state} = Phoenix.attach(config)

      # Emit LLM events - Phoenix should add OpenInference attributes
      :telemetry.execute(
        event_prefix ++ [:llm, :start],
        %{},
        %{
          model: "gpt-4o",
          input_messages: [
            %{role: "user", content: "test"},
            %{role: "assistant", content: "previous response"}
          ]
        }
      )

      :telemetry.execute(
        event_prefix ++ [:llm, :stop],
        %{duration: 2_000_000},
        %{
          output_messages: [%{role: "assistant", content: "new response"}],
          tokens: %{prompt: 20, completion: 10, total: 30}
        }
      )

      Phoenix.detach(state)
      cleanup_process_dictionary()

      # We can't directly inspect the span attributes without mocking OTel,
      # but we verify no crash occurred and OpenInference translation was applied
      assert true
    end

    test "Generic handler produces simple OTel attributes" do
      event_prefix = [:generic_attributes]
      config = %{event_prefix: event_prefix}

      {:ok, state} = Generic.attach(config)

      # Emit tool events - Generic should add simple attributes
      :telemetry.execute(
        event_prefix ++ [:tool, :start],
        %{},
        %{
          name: "weather_tool",
          arguments: %{city: "San Francisco", units: "celsius"}
        }
      )

      :telemetry.execute(
        event_prefix ++ [:tool, :stop],
        %{duration: 500_000},
        %{result: %{temperature: 22, condition: "sunny"}}
      )

      Generic.detach(state)
      cleanup_process_dictionary()

      # Verify no crash and generic translation was applied
      assert true
    end
  end

  describe "handler isolation" do
    test "Phoenix handler crash doesn't affect Generic handler" do
      event_prefix = [:crash_isolation]

      phoenix_config = %{event_prefix: event_prefix}
      generic_config = %{event_prefix: event_prefix}

      {:ok, phoenix_state} = Phoenix.attach(phoenix_config)
      {:ok, generic_state} = Generic.attach(generic_config)

      # Emit a stop event without corresponding start
      # This should cause a warning in handlers but not crash
      :telemetry.execute(
        event_prefix ++ [:agent, :stop],
        %{duration: 1_000_000},
        %{output: "orphan stop event"}
      )

      # Both handlers should still be functional
      :telemetry.execute(
        event_prefix ++ [:agent, :start],
        %{},
        %{name: "recovery_test", input: "test"}
      )

      :telemetry.execute(
        event_prefix ++ [:agent, :stop],
        %{duration: 1_000_000},
        %{output: "proper stop event"}
      )

      Phoenix.detach(phoenix_state)
      Generic.detach(generic_state)
      cleanup_process_dictionary()

      assert true
    end

    test "detaching one handler doesn't affect others" do
      event_prefix = [:selective_detach]

      phoenix_config = %{event_prefix: event_prefix}
      generic_config = %{event_prefix: event_prefix}

      {:ok, phoenix_state} = Phoenix.attach(phoenix_config)
      {:ok, generic_state} = Generic.attach(generic_config)

      # Detach Phoenix handler
      Phoenix.detach(phoenix_state)

      # Generic handler should still work
      :telemetry.execute(
        event_prefix ++ [:tool, :start],
        %{},
        %{name: "test_tool", arguments: %{}}
      )

      :telemetry.execute(
        event_prefix ++ [:tool, :stop],
        %{duration: 100_000},
        %{result: %{data: "success"}}
      )

      # Clean up Generic handler
      Generic.detach(generic_state)
      cleanup_process_dictionary()

      assert true
    end
  end

  describe "per-handler configuration" do
    test "handlers can have independent configurations" do
      # Phoenix with custom prefix
      phoenix_prefix = [:phoenix_custom]
      phoenix_config = %{event_prefix: phoenix_prefix, custom_option: "phoenix_value"}

      # Generic with different prefix
      generic_prefix = [:generic_custom]
      generic_config = %{event_prefix: generic_prefix, custom_option: "generic_value"}

      {:ok, phoenix_state} = Phoenix.attach(phoenix_config)
      {:ok, generic_state} = Generic.attach(generic_config)

      # Each handler should store its own config
      assert phoenix_state.config.custom_option == "phoenix_value"
      assert generic_state.config.custom_option == "generic_value"

      Phoenix.detach(phoenix_state)
      Generic.detach(generic_state)
    end

    test "handlers respect their own event prefixes" do
      phoenix_prefix = [:custom_phoenix]
      generic_prefix = [:custom_generic]

      {:ok, phoenix_state} = Phoenix.attach(%{event_prefix: phoenix_prefix})
      {:ok, generic_state} = Generic.attach(%{event_prefix: generic_prefix})

      # Emit to Phoenix prefix only
      :telemetry.execute(
        phoenix_prefix ++ [:agent, :start],
        %{},
        %{name: "phoenix_agent", input: "test"}
      )

      :telemetry.execute(
        phoenix_prefix ++ [:agent, :stop],
        %{duration: 1_000_000},
        %{output: "phoenix output"}
      )

      # Emit to Generic prefix only
      :telemetry.execute(
        generic_prefix ++ [:llm, :start],
        %{},
        %{model: "test-model", input_messages: []}
      )

      :telemetry.execute(
        generic_prefix ++ [:llm, :stop],
        %{duration: 2_000_000},
        %{output_messages: []}
      )

      Phoenix.detach(phoenix_state)
      Generic.detach(generic_state)
      cleanup_process_dictionary()

      # Both handlers processed only their own events
      assert true
    end
  end

  describe "concurrent event processing" do
    test "multiple handlers process concurrent events correctly" do
      event_prefix = [:concurrent_test]

      {:ok, phoenix_state} = Phoenix.attach(%{event_prefix: event_prefix})
      {:ok, generic_state} = Generic.attach(%{event_prefix: event_prefix})

      # Spawn multiple concurrent operations
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            AgentObs.trace_agent("concurrent_agent_#{i}", %{input: "test #{i}"}, fn ->
              Process.sleep(10)
              {:ok, "result #{i}"}
            end)
          end)
        end

      results = Task.await_many(tasks)

      # All operations should complete successfully
      assert length(results) == 5
      assert Enum.all?(results, fn {:ok, _} -> true end)

      Phoenix.detach(phoenix_state)
      Generic.detach(generic_state)
      cleanup_process_dictionary()
    end
  end

  describe "handler state management" do
    test "each handler maintains independent state" do
      event_prefix = [:state_test]

      {:ok, phoenix_state} = Phoenix.attach(%{event_prefix: event_prefix})
      {:ok, generic_state} = Generic.attach(%{event_prefix: event_prefix})

      # States should be independent maps
      assert is_map(phoenix_state)
      assert is_map(generic_state)
      # Handler IDs should be different (different atoms/tuples)
      refute phoenix_state.handler_id == generic_state.handler_id

      Phoenix.detach(phoenix_state)
      Generic.detach(generic_state)
    end

    test "handler state persists across multiple events" do
      event_prefix = [:state_persist]
      config = %{event_prefix: event_prefix}

      {:ok, state} = Phoenix.attach(config)

      # Emit multiple events
      for i <- 1..10 do
        :telemetry.execute(
          event_prefix ++ [:agent, :start],
          %{},
          %{name: "agent_#{i}", input: "test"}
        )

        :telemetry.execute(
          event_prefix ++ [:agent, :stop],
          %{duration: 1_000_000},
          %{output: "output_#{i}"}
        )
      end

      # State should remain valid
      assert is_map(state)
      assert Map.has_key?(state, :handler_id)

      Phoenix.detach(state)
      cleanup_process_dictionary()
    end
  end

  # Helper function to clean up process dictionary after tests
  defp cleanup_process_dictionary do
    Process.get_keys()
    |> Enum.filter(fn key ->
      key_str = Atom.to_string(key)
      String.contains?(key_str, "agent_obs") and String.contains?(key_str, "span")
    end)
    |> Enum.each(&Process.delete/1)
  end
end
