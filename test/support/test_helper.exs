defmodule AgentObs.TestHelper do
  @moduledoc """
  Test helpers for AgentObs test suite.

  Provides utilities for capturing and asserting on OpenTelemetry spans
  during testing without requiring actual backend connections.

  Uses `otel_exporter_pid` to route exported spans to the test process
  as `{:span, SpanRecord}` messages.
  """

  require Record

  # Define Elixir record accessors from the Erlang #span{} record.
  # Fields: trace_id, span_id, tracestate, parent_span_id, parent_span_is_remote,
  #         name, kind, start_time, end_time, attributes, events, links,
  #         status, trace_flags, is_recording, instrumentation_scope
  Record.defrecord(
    :span,
    Record.extract(:span, from: Application.app_dir(:opentelemetry, "include/otel_span.hrl"))
  )

  @doc """
  Configures `otel_exporter_pid` to send spans to the calling process,
  then executes the given function, flushes the processor, and collects
  all exported spans.

  Returns `{function_result, spans}` where spans is a list of Erlang
  span records.
  """
  def capture_spans(fun) when is_function(fun, 0) do
    pid = self()

    # Point the exporter at this process.
    # Detect whether the test env uses batch or simple processor.
    set_exporter(pid)

    result =
      try do
        fun.()
      after
        # Force flush to ensure all spans are exported
        force_flush()
        Process.sleep(100)
      end

    # Collect all span messages
    spans = collect_span_messages(500)

    {result, spans}
  end

  defp set_exporter(pid) do
    cond do
      Process.whereis(:otel_batch_processor_global) ->
        :otel_batch_processor.set_exporter(:otel_exporter_pid, pid)

      Process.whereis(:otel_simple_processor_global) ->
        :otel_simple_processor.set_exporter(:otel_exporter_pid, pid)

      true ->
        raise "No OTel span processor found. Ensure :opentelemetry is started."
    end
  end

  defp force_flush do
    cond do
      Process.whereis(:otel_batch_processor_global) ->
        :otel_batch_processor.force_flush(%{reg_name: :otel_batch_processor_global})

      Process.whereis(:otel_simple_processor_global) ->
        :otel_simple_processor.force_flush(%{reg_name: :otel_simple_processor_global})

      true ->
        :ok
    end
  end

  defp collect_span_messages(timeout) do
    receive do
      {:span, span_record} ->
        [span_record | collect_span_messages(timeout)]
    after
      timeout -> []
    end
  end

  @doc """
  Asserts that a span with the given name exists in the list of spans.
  """
  def assert_span_exists(spans, expected_name) do
    span_names = Enum.map(spans, &span_name/1)

    if expected_name in span_names do
      :ok
    else
      raise ExUnit.AssertionError,
        message: """
        Expected span named "#{expected_name}" not found.
        Available spans: #{inspect(span_names)}
        """
    end
  end

  @doc """
  Finds a span by name in the list of spans.

  Returns the first matching span or nil if not found.
  """
  def find_span(spans, name) do
    Enum.find(spans, &(span_name(&1) == name))
  end

  @doc """
  Asserts that a span has a specific attribute with the expected value.
  """
  def assert_span_attribute(span_record, key, expected_value) do
    attrs = span_attributes(span_record)
    actual_value = Map.get(attrs, key)

    if actual_value == expected_value do
      :ok
    else
      raise ExUnit.AssertionError,
        message: """
        Span attribute mismatch for "#{key}":
        Expected: #{inspect(expected_value)}
        Actual: #{inspect(actual_value)}
        Available: #{inspect(attrs)}
        """
    end
  end

  @doc """
  Asserts that a span has a specific attribute (regardless of value).
  """
  def assert_span_has_attribute(span_record, key) do
    attrs = span_attributes(span_record)

    if Map.has_key?(attrs, key) do
      :ok
    else
      raise ExUnit.AssertionError,
        message: """
        Span does not have attribute "#{key}".
        Available attributes: #{inspect(Map.keys(attrs))}
        """
    end
  end

  @doc """
  Asserts parent-child relationship between two spans.

  Verifies that child_span's parent_span_id matches parent_span's span_id.
  """
  def assert_span_parent(child_span, parent_span) do
    parent_id = extract_span_id(parent_span)
    child_parent_id = extract_parent_span_id(child_span)

    if child_parent_id == parent_id do
      :ok
    else
      raise ExUnit.AssertionError,
        message: """
        Span parent mismatch:
          Parent: #{inspect(span_name(parent_span))} (span_id: #{inspect(parent_id)})
          Child:  #{inspect(span_name(child_span))} (parent_span_id: #{inspect(child_parent_id)})
          Expected child's parent_span_id to match parent's span_id.
        """
    end
  end

  @doc """
  Asserts that two spans are siblings (have the same parent_span_id).
  """
  def assert_span_siblings(span_a, span_b) do
    parent_a = extract_parent_span_id(span_a)
    parent_b = extract_parent_span_id(span_b)

    if parent_a == parent_b do
      :ok
    else
      raise ExUnit.AssertionError,
        message: """
        Spans are not siblings:
          Span A: #{inspect(span_name(span_a))} (parent_span_id: #{inspect(parent_a)})
          Span B: #{inspect(span_name(span_b))} (parent_span_id: #{inspect(parent_b)})
          Expected both to have the same parent_span_id.
        """
    end
  end

  # -- Span record accessors --

  @doc "Extract span_id from a span record."
  def extract_span_id(span_record), do: span(span_record, :span_id)

  @doc "Extract parent_span_id from a span record."
  def extract_parent_span_id(span_record), do: span(span_record, :parent_span_id)

  @doc "Extract name from a span record."
  def span_name(span_record), do: span(span_record, :name)

  @doc "Extract attributes as a plain map from a span record."
  def span_attributes(span_record) do
    attrs = span(span_record, :attributes)
    otel_attributes_to_map(attrs)
  end

  # -- Private helpers --

  defp otel_attributes_to_map(attrs) when is_map(attrs) do
    case Map.get(attrs, :map) do
      map when is_map(map) -> map
      _ -> attrs
    end
  end

  defp otel_attributes_to_map(attrs) when is_list(attrs), do: Map.new(attrs)

  defp otel_attributes_to_map({:attributes, _limit, _value_limit, _count, map})
       when is_map(map),
       do: map

  defp otel_attributes_to_map(_), do: %{}
end
