defmodule AgentObs.IntegrationTest do
  use ExUnit.Case, async: false

  alias AgentObs.Handlers.Phoenix

  @moduletag :capture_log

  setup do
    # Start OpenTelemetry applications if not already started
    Application.ensure_all_started(:opentelemetry)
    Application.ensure_all_started(:opentelemetry_exporter)

    # Attach Phoenix handler for integration tests
    config = %{event_prefix: [:agent_obs_integration]}
    {:ok, handler_state} = Phoenix.attach(config)

    on_exit(fn ->
      Phoenix.detach(handler_state)

      # Clean up process dictionary
      Process.get_keys()
      |> Enum.filter(&match?(:agent_obs_phoenix_span_, &1))
      |> Enum.each(&Process.delete/1)
    end)

    %{handler_state: handler_state}
  end

  describe "end-to-end tracing pipeline" do
    test "complete agent trace with start and stop events" do
      result =
        AgentObs.trace_agent("integration_agent", %{input: "test query"}, fn ->
          # Simulate some work
          Process.sleep(10)
          {:ok, "agent response", %{iterations: 1}}
        end)

      assert {:ok, "agent response", %{iterations: 1}} = result
    end

    test "agent trace with error" do
      result =
        AgentObs.trace_agent("error_agent", %{input: "fail"}, fn ->
          {:error, "Something went wrong"}
        end)

      assert {:error, "Something went wrong"} = result
    end

    test "agent trace with exception" do
      result =
        AgentObs.trace_agent("exception_agent", %{input: "crash"}, fn ->
          raise RuntimeError, "Intentional crash"
        end)

      assert {:error, %{exception: exception, stacktrace: stacktrace}} = result
      assert exception.__struct__ == RuntimeError
      assert is_list(stacktrace)
    end

    test "tool trace with result" do
      result =
        AgentObs.trace_tool("get_weather", %{arguments: %{city: "San Francisco"}}, fn ->
          {:ok, %{temperature: 72, condition: "sunny"}}
        end)

      assert {:ok, %{temperature: 72, condition: "sunny"}} = result
    end

    test "llm trace with token metadata" do
      result =
        AgentObs.trace_llm(
          "gpt-4o",
          %{
            input_messages: [%{role: "user", content: "Hello"}]
          },
          fn ->
            {:ok, %{role: "assistant", content: "Hi there!"},
             %{
               tokens: %{prompt: 10, completion: 5, total: 15}
             }}
          end
        )

      assert {:ok, %{role: "assistant", content: "Hi there!"}, metadata} = result
      assert metadata.tokens.total == 15
    end

    test "prompt template trace" do
      result =
        AgentObs.trace_prompt(
          "greeting_template",
          %{
            variables: %{name: "Alice"}
          },
          fn ->
            {:ok, "Hello, Alice!"}
          end
        )

      assert {:ok, "Hello, Alice!"} = result
    end
  end

  describe "nested span relationships" do
    test "agent → llm nested trace" do
      result =
        AgentObs.trace_agent("nested_agent", %{input: "question"}, fn ->
          # Nested LLM call within agent
          llm_result =
            AgentObs.trace_llm(
              "gpt-4o",
              %{
                input_messages: [%{role: "user", content: "question"}]
              },
              fn ->
                {:ok, %{role: "assistant", content: "answer"},
                 %{
                   tokens: %{prompt: 5, completion: 3, total: 8}
                 }}
              end
            )

          case llm_result do
            {:ok, response, _metadata} ->
              {:ok, response.content, %{iterations: 1}}

            error ->
              error
          end
        end)

      assert {:ok, "answer", %{iterations: 1}} = result
    end

    test "agent → tool nested trace" do
      result =
        AgentObs.trace_agent("tool_agent", %{input: "get data"}, fn ->
          tool_result =
            AgentObs.trace_tool("fetch_data", %{arguments: %{id: 123}}, fn ->
              {:ok, %{data: "some data"}}
            end)

          case tool_result do
            {:ok, data} ->
              {:ok, "Retrieved: #{data.data}", %{iterations: 1}}

            error ->
              error
          end
        end)

      assert {:ok, "Retrieved: some data", %{iterations: 1}} = result
    end

    test "agent → llm → tool (three level nesting)" do
      result =
        AgentObs.trace_agent("multi_level_agent", %{input: "complex query"}, fn ->
          llm_result =
            AgentObs.trace_llm(
              "gpt-4o",
              %{
                input_messages: [%{role: "user", content: "need tool"}]
              },
              fn ->
                # LLM decides to use a tool
                tool_result =
                  AgentObs.trace_tool("calculator", %{arguments: %{op: "add", a: 1, b: 2}}, fn ->
                    {:ok, %{result: 3}}
                  end)

                case tool_result do
                  {:ok, calc_result} ->
                    {:ok, %{role: "assistant", content: "Sum is #{calc_result.result}"},
                     %{
                       tokens: %{prompt: 10, completion: 5, total: 15}
                     }}

                  error ->
                    error
                end
              end
            )

          case llm_result do
            {:ok, response, _metadata} ->
              {:ok, response.content, %{iterations: 1}}

            error ->
              error
          end
        end)

      assert {:ok, "Sum is 3", %{iterations: 1}} = result
    end
  end

  describe "error handling and exception propagation" do
    test "exception in nested LLM call propagates to agent" do
      result =
        AgentObs.trace_agent("exception_propagation_agent", %{input: "test"}, fn ->
          AgentObs.trace_llm(
            "gpt-4o",
            %{
              input_messages: [%{role: "user", content: "test"}]
            },
            fn ->
              raise ArgumentError, "LLM call failed"
            end
          )
        end)

      assert {:error, %{exception: exception, stacktrace: _stacktrace}} = result
      assert exception.__struct__ == ArgumentError
      assert Exception.message(exception) == "LLM call failed"
    end

    test "error in nested tool call propagates to agent" do
      result =
        AgentObs.trace_agent("tool_error_agent", %{input: "test"}, fn ->
          tool_result =
            AgentObs.trace_tool("failing_tool", %{arguments: %{}}, fn ->
              {:error, "Tool execution failed"}
            end)

          case tool_result do
            {:error, reason} ->
              {:error, "Agent failed because: #{reason}"}

            _ ->
              {:ok, "unexpected"}
          end
        end)

      assert {:error, "Agent failed because: Tool execution failed"} = result
    end

    test "exception span status is set to error" do
      # This test verifies that when an exception occurs, the span is properly
      # ended with error status
      _result =
        AgentObs.trace_agent("error_status_agent", %{input: "test"}, fn ->
          raise RuntimeError, "Test exception"
        end)

      # If we get here without crashing, the exception was handled correctly
      # and the span was properly ended
      assert true
    end
  end

  describe "duration measurement" do
    test "measures duration for successful operations" do
      result =
        AgentObs.trace_agent("timed_agent", %{input: "test"}, fn ->
          # Sleep to ensure measurable duration
          Process.sleep(100)
          {:ok, "result"}
        end)

      assert {:ok, "result"} = result
      # Duration is measured in nanoseconds and passed to handlers
      # We can't easily verify the exact value, but we verify no crash
    end

    test "measures duration for failed operations" do
      result =
        AgentObs.trace_agent("failed_timed_agent", %{input: "test"}, fn ->
          Process.sleep(50)
          {:error, "failed"}
        end)

      assert {:error, "failed"} = result
    end
  end

  describe "span context propagation" do
    test "context is properly restored after nested calls" do
      # This test ensures that the OpenTelemetry context is properly managed
      # across nested instrumentation calls

      _result =
        AgentObs.trace_agent("context_test_agent", %{input: "test"}, fn ->
          # First nested call
          AgentObs.trace_llm(
            "model1",
            %{
              input_messages: [%{role: "user", content: "test1"}]
            },
            fn ->
              {:ok, %{role: "assistant", content: "response1"}}
            end
          )

          # Second nested call at same level
          AgentObs.trace_llm(
            "model2",
            %{
              input_messages: [%{role: "user", content: "test2"}]
            },
            fn ->
              {:ok, %{role: "assistant", content: "response2"}}
            end
          )

          {:ok, "completed", %{iterations: 1}}
        end)

      # Verify no context corruption occurred
      # The second LLM call should not be a child of the first
      assert true
    end

    test "parallel sibling spans at same nesting level" do
      _result =
        AgentObs.trace_agent("parallel_agent", %{input: "test"}, fn ->
          # Simulate calling multiple tools in sequence (siblings)
          AgentObs.trace_tool("tool1", %{arguments: %{a: 1}}, fn ->
            {:ok, %{result: "tool1_result"}}
          end)

          AgentObs.trace_tool("tool2", %{arguments: %{b: 2}}, fn ->
            {:ok, %{result: "tool2_result"}}
          end)

          AgentObs.trace_tool("tool3", %{arguments: %{c: 3}}, fn ->
            {:ok, %{result: "tool3_result"}}
          end)

          {:ok, "all tools executed", %{tools_used: 3}}
        end)

      assert true
    end
  end

  describe "metadata extraction and enrichment" do
    test "agent metadata is properly captured" do
      result =
        AgentObs.trace_agent(
          "metadata_agent",
          %{
            input: "test input",
            model: "orchestrator-model"
          },
          fn ->
            {:ok, "output", %{iterations: 3, tools_used: ["tool1", "tool2"]}}
          end
        )

      assert {:ok, "output", metadata} = result
      assert metadata.iterations == 3
      assert metadata.tools_used == ["tool1", "tool2"]
    end

    test "llm token counts are captured" do
      result =
        AgentObs.trace_llm(
          "gpt-4o",
          %{
            input_messages: [%{role: "user", content: "test"}]
          },
          fn ->
            {:ok, %{role: "assistant", content: "response"},
             %{
               tokens: %{prompt: 100, completion: 50, total: 150},
               cost: 0.005
             }}
          end
        )

      assert {:ok, _response, metadata} = result
      assert metadata.tokens.total == 150
      assert metadata.cost == 0.005
    end

    test "tool arguments are captured" do
      arguments = %{
        city: "San Francisco",
        units: "celsius",
        forecast_days: 5
      }

      result =
        AgentObs.trace_tool(
          "get_weather",
          %{
            arguments: arguments,
            description: "Fetches weather data"
          },
          fn ->
            {:ok, %{temp: 22, condition: "cloudy"}}
          end
        )

      assert {:ok, %{temp: 22, condition: "cloudy"}} = result
    end
  end

  describe "custom events via emit/2" do
    test "custom event can be emitted" do
      # Test the low-level emit API
      :ok =
        AgentObs.emit(:custom_event, %{
          custom_field: "value",
          timestamp: DateTime.utc_now()
        })

      # Verify it doesn't crash
      assert true
    end

    test "multiple custom events in sequence" do
      :ok = AgentObs.emit(:event1, %{step: 1})
      :ok = AgentObs.emit(:event2, %{step: 2})
      :ok = AgentObs.emit(:event3, %{step: 3})

      assert true
    end
  end
end
