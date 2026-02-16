defmodule AgentObs.TestHelper do
  @moduledoc """
  Test helpers for AgentObs test suite.

  Provides utilities for capturing and asserting on real OpenTelemetry spans
  using `:otel_exporter_pid` to receive span records in the test process.
  """

  import ExUnit.Assertions

  # Extract the #span{} record from otel_span.hrl so we can destructure the
  # Erlang tuple sent by :otel_exporter_pid.
  require Record

  Record.defrecord(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  Record.defrecord(
    :status,
    Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  @doc """
  Receives a single span message from `:otel_exporter_pid` and converts
  it to a readable Elixir map.

  ## Options

  - `:timeout` — milliseconds to wait (default 5_000)

  ## Returns

  A map with keys: `:name`, `:trace_id`, `:span_id`, `:parent_span_id`,
  `:attributes`, `:status`, `:kind`, `:start_time`, `:end_time`, `:events`,
  `:links`, `:trace_flags`, `:is_recording`, `:instrumentation_scope`.
  """
  def receive_span(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    receive do
      {:span, raw} when Record.is_record(raw, :span) ->
        span_to_map(raw)
    after
      timeout ->
        flunk("Expected to receive a span within #{timeout}ms but none arrived")
    end
  end

  @doc """
  Drains all `{:span, _}` messages currently in the mailbox and returns them
  as a list of maps. Does not wait for new messages.
  """
  def receive_all_spans do
    receive_all_spans_acc([])
  end

  defp receive_all_spans_acc(acc) do
    receive do
      {:span, raw} when Record.is_record(raw, :span) ->
        receive_all_spans_acc([span_to_map(raw) | acc])
    after
      100 ->
        Enum.reverse(acc)
    end
  end

  @doc """
  Flushes all pending `{:span, _}` messages from the mailbox.
  """
  def flush_spans do
    receive do
      {:span, _} -> flush_spans()
    after
      0 -> :ok
    end
  end

  @doc """
  Asserts that a span with the given name exists in the list of spans.
  """
  def assert_span_exists(spans, expected_name) do
    span_names = Enum.map(spans, & &1.name)

    assert expected_name in span_names,
           "Expected span named #{inspect(expected_name)} not found.\nAvailable spans: #{inspect(span_names)}"

    :ok
  end

  @doc """
  Finds a span by name in the list of spans.
  """
  def find_span(spans, name) do
    Enum.find(spans, &(&1.name == name))
  end

  @doc """
  Asserts that a span has a specific attribute with the expected value.
  """
  def assert_span_attribute(span_map, key, expected_value) do
    actual_value = span_map.attributes[key]

    assert actual_value == expected_value,
           "Span #{inspect(span_map.name)} attribute #{inspect(key)} mismatch.\nExpected: #{inspect(expected_value)}\nActual: #{inspect(actual_value)}"

    :ok
  end

  @doc """
  Asserts that a span has a specific attribute (regardless of value).
  """
  def assert_span_has_attribute(span_map, key) do
    assert Map.has_key?(span_map.attributes, key),
           "Span #{inspect(span_map.name)} missing attribute #{inspect(key)}.\nAvailable: #{inspect(Map.keys(span_map.attributes))}"

    :ok
  end

  @doc """
  Asserts parent-child relationship between two span maps.
  """
  def assert_span_parent(child_span, parent_span) do
    assert child_span.parent_span_id == parent_span.span_id,
           "Parent-child mismatch.\nParent span_id: #{inspect(parent_span.span_id)}\nChild parent_span_id: #{inspect(child_span.parent_span_id)}"

    :ok
  end

  # -- Private: convert Erlang #span{} record to Elixir map --

  defp span_to_map(raw) do
    attrs =
      case span(raw, :attributes) do
        a when is_tuple(a) -> :otel_attributes.map(a)
        :undefined -> %{}
        _ -> %{}
      end

    stat =
      case span(raw, :status) do
        s when Record.is_record(s, :status) ->
          %{code: status(s, :code), message: status(s, :message)}

        :undefined ->
          nil

        _ ->
          nil
      end

    %{
      name: span(raw, :name),
      trace_id: span(raw, :trace_id),
      span_id: span(raw, :span_id),
      parent_span_id: span(raw, :parent_span_id),
      tracestate: span(raw, :tracestate),
      kind: span(raw, :kind),
      start_time: span(raw, :start_time),
      end_time: span(raw, :end_time),
      attributes: attrs,
      events: span(raw, :events),
      links: span(raw, :links),
      status: stat,
      trace_flags: span(raw, :trace_flags),
      is_recording: span(raw, :is_recording),
      instrumentation_scope: span(raw, :instrumentation_scope)
    }
  end
end
