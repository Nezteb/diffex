defmodule Diffex do
  @moduledoc """
  Minimal diffs between nested maps, structs, lists, and tuples.

  Returns a map describing what needs to change to turn the first argument
  into the second.

  Lists and tuples are compared by index position. Everything else is compared
  with `==`.
  """

  @type diff_op :: :added | :removed | :changed
  @type diff_value ::
          {diff_op, any()}
          | {diff_op, any(), any()}
          | {:list_diff, %{non_neg_integer() => diff_value}}
          | {:tuple_diff, %{non_neg_integer() => diff_value}}
          | %{optional(any()) => diff_value}

  @doc """
  Returns the diff between two maps or structs.

  ## Return format

  Each key in the result maps to one of:
  - `{:added, new_value}` - key exists only in `new`
  - `{:removed, old_value}` - key exists only in `old`
  - `{:changed, old_value, new_value}` - scalar value changed
  - `%{...}` - nested diff for nested maps/structs

  Returns `%{}` if there are no differences.

  ## Examples

      iex> Diffex.diff(%{a: 1, b: 2}, %{a: 1, b: 3})
      %{b: {:changed, 2, 3}}

      iex> Diffex.diff(%{a: 1}, %{a: 1, b: 2})
      %{b: {:added, 2}}

      iex> Diffex.diff(%{a: %{x: 1, y: 2}}, %{a: %{x: 1, y: 3}})
      %{a: %{y: {:changed, 2, 3}}}
  """
  @spec diff(map(), map()) :: %{optional(any()) => diff_value()}
  def diff(old, new) when is_struct(old) and is_struct(new) do
    diff(Map.from_struct(old), Map.from_struct(new))
  end

  def diff(old, new) when is_map(old) and is_map(new) do
    old_keys = Map.keys(old) |> MapSet.new()
    new_keys = Map.keys(new) |> MapSet.new()

    removed_keys = MapSet.difference(old_keys, new_keys)
    added_keys = MapSet.difference(new_keys, old_keys)
    common_keys = MapSet.intersection(old_keys, new_keys)

    removed = Map.new(removed_keys, fn key -> {key, {:removed, Map.fetch!(old, key)}} end)
    added = Map.new(added_keys, fn key -> {key, {:added, Map.fetch!(new, key)}} end)

    common =
      Enum.reduce(common_keys, %{}, fn key, acc ->
        case diff_values(Map.fetch!(old, key), Map.fetch!(new, key)) do
          :equal -> acc
          change -> Map.put(acc, key, change)
        end
      end)

    Map.merge(removed, Map.merge(added, common))
  end

  defp diff_values(same, same), do: :equal

  defp diff_values(old_val, new_val) when is_map(old_val) and is_map(new_val) do
    nested_diff = diff(old_val, new_val)

    if nested_diff == %{} do
      :equal
    else
      nested_diff
    end
  end

  defp diff_values(old_val, new_val) when is_list(old_val) and is_list(new_val) do
    diff_indexed(old_val, new_val, :list_diff)
  end

  defp diff_values(old_val, new_val) when is_tuple(old_val) and is_tuple(new_val) do
    diff_indexed(Tuple.to_list(old_val), Tuple.to_list(new_val), :tuple_diff)
  end

  defp diff_values(old_val, new_val) do
    {:changed, old_val, new_val}
  end

  defp diff_indexed(old_list, new_list, tag) do
    old_map = old_list |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end)
    new_map = new_list |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end)

    old_keys = old_map |> Map.keys() |> MapSet.new()
    new_keys = new_map |> Map.keys() |> MapSet.new()

    removed =
      Map.new(MapSet.difference(old_keys, new_keys), fn i ->
        {i, {:removed, Map.fetch!(old_map, i)}}
      end)

    added =
      Map.new(MapSet.difference(new_keys, old_keys), fn i ->
        {i, {:added, Map.fetch!(new_map, i)}}
      end)

    common =
      Enum.reduce(MapSet.intersection(old_keys, new_keys), %{}, fn i, acc ->
        case diff_values(Map.fetch!(old_map, i), Map.fetch!(new_map, i)) do
          :equal -> acc
          change -> Map.put(acc, i, change)
        end
      end)

    changes = Map.merge(removed, Map.merge(added, common))

    if changes == %{} do
      :equal
    else
      {tag, changes}
    end
  end

  @doc """
  Counts the leaf-level changes in a diff.

  Each `:added`, `:removed`, or `:changed` counts as 1. Nested diffs are
  traversed recursively.

  ## Examples

      iex> Diffex.diff(%{a: 1, b: 2}, %{a: 1, b: 3}) |> Diffex.count_changes()
      1

      iex> Diffex.diff(%{a: 1}, %{b: 2}) |> Diffex.count_changes()
      2

      iex> Diffex.diff(
      ...>   %{user: %{name: "Alice", age: 30}},
      ...>   %{user: %{name: "Bob", age: 31}}
      ...> ) |> Diffex.count_changes()
      2
  """
  @spec count_changes(%{optional(any()) => diff_value()}) :: non_neg_integer()
  def count_changes(diff) when is_map(diff) do
    Enum.reduce(diff, 0, fn {_key, operation}, acc ->
      acc + count_operation(operation)
    end)
  end

  defp count_operation({:added, _value}), do: 1
  defp count_operation({:removed, _value}), do: 1
  defp count_operation({:changed, _old, _new}), do: 1
  defp count_operation({:list_diff, changes}), do: count_changes(changes)
  defp count_operation({:tuple_diff, changes}), do: count_changes(changes)
  defp count_operation(nested_diff) when is_map(nested_diff), do: count_changes(nested_diff)

  @doc """
  Applies a diff to a map or struct.

  For `:changed` and `:removed` operations, the current value must match the
  expected "before" value. Returns `{:ok, result}` on success or `{:error, reason}`
  if a value doesn't match.

  ## Examples

      iex> diff = %{b: {:changed, 2, 3}}
      iex> Diffex.apply_diff(%{a: 1, b: 2}, diff)
      {:ok, %{a: 1, b: 3}}

      iex> diff = %{b: {:changed, 2, 3}}
      iex> Diffex.apply_diff(%{a: 1, b: 999}, diff)
      {:error, {:value_mismatch, :b, %{expected: 2, actual: 999}}}
  """
  @spec apply_diff(map(), %{optional(any()) => diff_value()}) ::
          {:ok, map()}
          | {:error, {:value_mismatch, any(), map()}}
          | {:error, {:key_exists, any(), any()}}

  def apply_diff(original, diff) when is_struct(original) do
    struct_module = original.__struct__

    case apply_diff(Map.from_struct(original), diff) do
      {:ok, result} -> {:ok, struct(struct_module, result)}
      {:error, _} = error -> error
    end
  end

  def apply_diff(original, diff) when is_map(original) and is_map(diff) do
    Enum.reduce_while(diff, {:ok, original}, fn {key, operation}, {:ok, acc} ->
      case apply_operation(acc, key, operation) do
        {:ok, new_acc} -> {:cont, {:ok, new_acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp apply_operation(acc, key, {:added, value}) do
    if Map.has_key?(acc, key) do
      {:error, {:key_exists, key, Map.fetch!(acc, key)}}
    else
      {:ok, Map.put(acc, key, value)}
    end
  end

  defp apply_operation(acc, key, {:removed, expected}) do
    with :ok <- check_match(acc, key, expected), do: {:ok, Map.delete(acc, key)}
  end

  defp apply_operation(acc, key, {:changed, expected_old, new_val}) do
    with :ok <- check_match(acc, key, expected_old), do: {:ok, Map.put(acc, key, new_val)}
  end

  defp apply_operation(acc, key, {:list_diff, changes}) do
    current = Map.get(acc, key, [])

    case apply_indexed_diff(current, changes) do
      {:ok, new_list} ->
        {:ok, Map.put(acc, key, new_list)}

      {:error, {:value_mismatch, nested_key, details}} ->
        {:error, {:value_mismatch, [key | List.wrap(nested_key)], details}}

      {:error, _} = error ->
        error
    end
  end

  defp apply_operation(acc, key, {:tuple_diff, changes}) do
    current = acc |> Map.get(key, {}) |> Tuple.to_list()

    case apply_indexed_diff(current, changes) do
      {:ok, new_list} ->
        {:ok, Map.put(acc, key, List.to_tuple(new_list))}

      {:error, {:value_mismatch, nested_key, details}} ->
        {:error, {:value_mismatch, [key | List.wrap(nested_key)], details}}

      {:error, _} = error ->
        error
    end
  end

  defp apply_operation(acc, key, nested_diff) when is_map(nested_diff) do
    old_nested = Map.get(acc, key, %{})

    case apply_diff(old_nested, nested_diff) do
      {:ok, new_nested} ->
        {:ok, Map.put(acc, key, new_nested)}

      {:error, {:value_mismatch, nested_key, details}} ->
        {:error, {:value_mismatch, [key | List.wrap(nested_key)], details}}

      {:error, _} = error ->
        error
    end
  end

  defp check_match(acc, key, expected) do
    case Map.get(acc, key) do
      ^expected -> :ok
      actual -> {:error, {:value_mismatch, key, %{expected: expected, actual: actual}}}
    end
  end

  defp apply_indexed_diff(list, changes) do
    old_map = list |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end)

    result =
      Enum.reduce_while(changes, {:ok, old_map}, fn {i, op}, {:ok, acc} ->
        case apply_operation(acc, i, op) do
          {:ok, new_acc} -> {:cont, {:ok, new_acc}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, index_map} ->
        new_list = index_map |> Enum.sort_by(fn {i, _} -> i end) |> Enum.map(fn {_, v} -> v end)
        {:ok, new_list}

      error ->
        error
    end
  end

  @doc """
  Returns `true` if the two maps have no differences.

  ## Examples

      iex> Diffex.equal?(%{a: 1}, %{a: 1})
      true

      iex> Diffex.equal?(%{a: 1}, %{a: 2})
      false
  """
  @spec equal?(map(), map()) :: boolean()
  def equal?(old, new) do
    diff(old, new) |> map_size() == 0
  end

  @doc """
  Returns a list of strings describing each change in the diff.

  ## Examples

      iex> Diffex.diff(%{a: 1, b: 2}, %{a: 1, c: 3}) |> Diffex.summarize()
      ["added :c (value: 3)", "removed :b (was: 2)"]
  """
  @spec summarize(map()) :: [String.t()]
  def summarize(diff), do: summarize(diff, [])

  defp summarize(diff, path) do
    Enum.flat_map(diff, fn {key, operation} ->
      current_path = [key | path]
      path_str = current_path |> Enum.reverse() |> Enum.map_join(".", &inspect/1)

      case operation do
        {:added, value} ->
          ["added #{path_str} (value: #{inspect(value)})"]

        {:removed, value} ->
          ["removed #{path_str} (was: #{inspect(value)})"]

        {:changed, old, new} ->
          ["changed #{path_str} from #{inspect(old)} to #{inspect(new)}"]

        {:list_diff, changes} ->
          summarize(changes, current_path)

        {:tuple_diff, changes} ->
          summarize(changes, current_path)

        nested_diff when is_map(nested_diff) ->
          summarize(nested_diff, current_path)
      end
    end)
  end
end
