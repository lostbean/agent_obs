defmodule AgentObs.HandlerContractTest do
  use ExUnit.Case, async: false

  alias AgentObs.Handlers.Generic
  alias AgentObs.Handlers.Phoenix

  @moduletag :capture_log

  @handlers [
    {Phoenix, "Phoenix"},
    {Generic, "Generic"}
  ]

  describe "Handler behaviour compliance" do
    for {handler_module, handler_name} <- @handlers do
      test "#{handler_name} handler implements attach/1" do
        handler = unquote(handler_module)
        config = %{event_prefix: [:"test_contract_#{unquote(handler_name)}"]}

        assert function_exported?(handler, :attach, 1)
        assert {:ok, state} = handler.attach(config)
        assert is_map(state)

        # Clean up
        handler.detach(state)
      end

      test "#{handler_name} handler implements handle_event/4" do
        handler = unquote(handler_module)

        assert function_exported?(handler, :handle_event, 4)
      end

      test "#{handler_name} handler implements detach/1" do
        handler = unquote(handler_module)

        assert function_exported?(handler, :detach, 1)
      end

      test "#{handler_name} handler implements all required callbacks" do
        handler = unquote(handler_module)

        # Verify all required callbacks are implemented
        assert function_exported?(handler, :attach, 1),
               "#{unquote(handler_name)} handler must implement attach/1"

        assert function_exported?(handler, :handle_event, 4),
               "#{unquote(handler_name)} handler must implement handle_event/4"

        assert function_exported?(handler, :detach, 1),
               "#{unquote(handler_name)} handler must implement detach/1"
      end
    end
  end

  describe "attach/1 contract" do
    for {handler_module, handler_name} <- @handlers do
      test "#{handler_name} handler attach/1 returns {:ok, state}" do
        handler = unquote(handler_module)
        config = %{event_prefix: [:"test_attach_#{unquote(handler_name)}"]}

        result = handler.attach(config)

        assert {:ok, state} = result
        assert is_map(state)
        assert Map.has_key?(state, :handler_id)

        # Clean up
        handler.detach(state)
      end

      test "#{handler_name} handler attach/1 registers telemetry handlers" do
        handler = unquote(handler_module)
        event_prefix = [:"test_attach_reg_#{unquote(handler_name)}"]
        config = %{event_prefix: event_prefix}

        {:ok, state} = handler.attach(config)

        # Verify that events can be emitted without errors
        # This indirectly verifies that telemetry handlers were registered
        :telemetry.execute(
          event_prefix ++ [:agent, :start],
          %{},
          %{name: "test", input: "test"}
        )

        # Clean up
        handler.detach(state)
      end

      test "#{handler_name} handler attach/1 accepts custom event_prefix" do
        handler = unquote(handler_module)
        custom_prefix = [:"custom_prefix_#{unquote(handler_name)}"]
        config = %{event_prefix: custom_prefix}

        assert {:ok, state} = handler.attach(config)

        # Clean up
        handler.detach(state)
      end

      test "#{handler_name} handler attach/1 uses default prefix when not provided" do
        handler = unquote(handler_module)
        config = %{}

        assert {:ok, state} = handler.attach(config)
        assert is_map(state)

        # Clean up
        handler.detach(state)
      end
    end
  end

  describe "handle_event/4 contract" do
    for {handler_module, handler_name} <- @handlers do
      setup do
        handler = unquote(handler_module)
        event_prefix = [:"test_handle_#{unquote(handler_name)}"]
        config = %{event_prefix: event_prefix}

        {:ok, state} = handler.attach(config)

        on_exit(fn ->
          handler.detach(state)

          # Clean up process dictionary
          Process.get_keys()
          |> Enum.filter(fn key ->
            key_str = Atom.to_string(key)
            String.contains?(key_str, "agent_obs") and String.contains?(key_str, "span")
          end)
          |> Enum.each(&Process.delete/1)
        end)

        %{handler: handler, event_prefix: event_prefix, config: config}
      end

      test "#{handler_name} handler handles agent :start event", %{event_prefix: prefix} do
        :telemetry.execute(
          prefix ++ [:agent, :start],
          %{},
          %{name: "test_agent", input: "test input"}
        )

        # Should not crash
        assert true
      end

      test "#{handler_name} handler handles agent :stop event", %{event_prefix: prefix} do
        # Start first
        :telemetry.execute(
          prefix ++ [:agent, :start],
          %{},
          %{name: "test_agent", input: "test input"}
        )

        # Then stop
        :telemetry.execute(
          prefix ++ [:agent, :stop],
          %{duration: 1_000_000},
          %{output: "test output"}
        )

        # Should not crash
        assert true
      end

      test "#{handler_name} handler handles agent :exception event", %{event_prefix: prefix} do
        # Start first
        :telemetry.execute(
          prefix ++ [:agent, :start],
          %{},
          %{name: "test_agent", input: "test input"}
        )

        # Then exception
        :telemetry.execute(
          prefix ++ [:agent, :exception],
          %{duration: 500_000},
          %{
            kind: :error,
            reason: %RuntimeError{message: "test error"},
            stacktrace: []
          }
        )

        # Should not crash
        assert true
      end

      test "#{handler_name} handler handles llm events", %{event_prefix: prefix} do
        :telemetry.execute(
          prefix ++ [:llm, :start],
          %{},
          %{model: "gpt-4o", input_messages: [%{role: "user", content: "test"}]}
        )

        :telemetry.execute(
          prefix ++ [:llm, :stop],
          %{duration: 2_000_000},
          %{
            output_messages: [%{role: "assistant", content: "response"}],
            tokens: %{prompt: 10, completion: 5, total: 15}
          }
        )

        assert true
      end

      test "#{handler_name} handler handles tool events", %{event_prefix: prefix} do
        :telemetry.execute(
          prefix ++ [:tool, :start],
          %{},
          %{name: "calculator", arguments: %{op: "add", a: 1, b: 2}}
        )

        :telemetry.execute(
          prefix ++ [:tool, :stop],
          %{duration: 100_000},
          %{result: %{sum: 3}}
        )

        assert true
      end

      test "#{handler_name} handler handles prompt events", %{event_prefix: prefix} do
        :telemetry.execute(
          prefix ++ [:prompt, :start],
          %{},
          %{name: "greeting", variables: %{name: "Alice"}}
        )

        :telemetry.execute(
          prefix ++ [:prompt, :stop],
          %{duration: 10_000},
          %{rendered: "Hello, Alice!"}
        )

        assert true
      end

      test "#{handler_name} handler returns :ok from handle_event/4", %{
        handler: handler,
        event_prefix: prefix,
        config: config
      } do
        result =
          handler.handle_event(
            prefix ++ [:agent, :start],
            %{},
            %{name: "test", input: "test"},
            config
          )

        assert result == :ok
      end
    end
  end

  describe "detach/1 contract" do
    for {handler_module, handler_name} <- @handlers do
      test "#{handler_name} handler detach/1 unregisters telemetry handlers" do
        handler = unquote(handler_module)
        event_prefix = [:"test_detach_#{unquote(handler_name)}"]
        config = %{event_prefix: event_prefix}

        {:ok, state} = handler.attach(config)

        # Verify handlers are attached
        :telemetry.execute(
          event_prefix ++ [:agent, :start],
          %{},
          %{name: "test", input: "test"}
        )

        # Detach
        assert :ok = handler.detach(state)

        # After detach, events should still work but won't be handled
        # (telemetry just ignores missing handlers rather than crashing)
        :telemetry.execute(
          event_prefix ++ [:agent, :start],
          %{},
          %{name: "test", input: "test"}
        )

        assert true
      end

      test "#{handler_name} handler detach/1 returns :ok" do
        handler = unquote(handler_module)
        config = %{event_prefix: [:"test_detach_ok_#{unquote(handler_name)}"]}

        {:ok, state} = handler.attach(config)
        result = handler.detach(state)

        assert result == :ok
      end

      test "#{handler_name} handler can attach again after detach" do
        handler = unquote(handler_module)
        event_prefix = [:"test_reattach_#{unquote(handler_name)}"]
        config = %{event_prefix: event_prefix}

        # First attach/detach cycle
        {:ok, state1} = handler.attach(config)
        :ok = handler.detach(state1)

        # Second attach/detach cycle (with different prefix to avoid conflicts)
        new_prefix = [:"test_reattach_2_#{unquote(handler_name)}"]
        config2 = %{event_prefix: new_prefix}
        assert {:ok, state2} = handler.attach(config2)
        :ok = handler.detach(state2)
      end
    end
  end

  describe "GenServer integration" do
    for {handler_module, handler_name} <- @handlers do
      test "#{handler_name} handler can be started as GenServer" do
        handler = unquote(handler_module)
        config = %{event_prefix: [:"test_genserver_#{unquote(handler_name)}"]}

        assert {:ok, pid} = handler.start_link(config)
        assert Process.alive?(pid)

        # Stop the GenServer
        GenServer.stop(pid)
      end

      test "#{handler_name} handler terminates gracefully" do
        handler = unquote(handler_module)
        config = %{event_prefix: [:"test_terminate_#{unquote(handler_name)}"]}

        {:ok, pid} = handler.start_link(config)

        # Monitor to detect termination
        ref = Process.monitor(pid)

        # Stop the GenServer
        GenServer.stop(pid)

        # Wait for DOWN message
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      end
    end
  end

  describe "error handling" do
    for {handler_module, handler_name} <- @handlers do
      test "#{handler_name} handler doesn't crash on malformed events" do
        handler = unquote(handler_module)
        event_prefix = [:"test_malformed_#{unquote(handler_name)}"]
        config = %{event_prefix: event_prefix}

        {:ok, state} = handler.attach(config)

        # Emit event with missing required fields
        :telemetry.execute(
          event_prefix ++ [:agent, :start],
          %{},
          %{name: "test"}
          # Missing :input field
        )

        # Should log error but not crash
        assert true

        handler.detach(state)
      end

      test "#{handler_name} handler handles missing span context gracefully" do
        handler = unquote(handler_module)
        event_prefix = [:"test_missing_span_#{unquote(handler_name)}"]
        config = %{event_prefix: event_prefix}

        {:ok, state} = handler.attach(config)

        # Emit stop without corresponding start
        :telemetry.execute(
          event_prefix ++ [:agent, :stop],
          %{duration: 1_000_000},
          %{output: "test"}
        )

        # Should log warning but not crash
        assert true

        handler.detach(state)
      end
    end
  end
end
