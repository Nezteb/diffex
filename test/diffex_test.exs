defmodule DiffexTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Diffex

  defmodule Point do
    defstruct [:x, :y]
  end

  defmodule Color do
    defstruct [:r, :g, :b]
  end

  defmodule Widget do
    defstruct [:color, :size]
  end

  # ---------------------------------------------------------------------------
  # Unit tests
  # ---------------------------------------------------------------------------

  describe "diff/2" do
    test "equal maps return empty diff" do
      assert Diffex.diff(%{a: 1, b: 2}, %{a: 1, b: 2}) == %{}
    end

    test "empty maps are equal" do
      assert Diffex.diff(%{}, %{}) == %{}
    end

    test "added key" do
      assert Diffex.diff(%{a: 1}, %{a: 1, b: 2}) == %{b: {:added, 2}}
    end

    test "removed key" do
      assert Diffex.diff(%{a: 1, b: 2}, %{a: 1}) == %{b: {:removed, 2}}
    end

    test "changed scalar value" do
      assert Diffex.diff(%{a: 1}, %{a: 2}) == %{a: {:changed, 1, 2}}
    end

    test "all three operations in one diff" do
      old = %{keep: :same, remove: :gone, change: 1}
      new = %{keep: :same, add: :new, change: 2}

      assert Diffex.diff(old, new) == %{
               remove: {:removed, :gone},
               add: {:added, :new},
               change: {:changed, 1, 2}
             }
    end

    test "nested map with no changes returns empty diff" do
      assert Diffex.diff(%{a: %{x: 1}}, %{a: %{x: 1}}) == %{}
    end

    test "nested map with change returns nested diff" do
      assert Diffex.diff(%{a: %{x: 1, y: 2}}, %{a: %{x: 1, y: 3}}) ==
               %{a: %{y: {:changed, 2, 3}}}
    end

    test "deeply nested change" do
      old = %{a: %{b: %{c: 1}}}
      new = %{a: %{b: %{c: 2}}}
      assert Diffex.diff(old, new) == %{a: %{b: %{c: {:changed, 1, 2}}}}
    end

    test "nil values are compared correctly" do
      assert Diffex.diff(%{a: nil}, %{a: nil}) == %{}
      assert Diffex.diff(%{a: nil}, %{a: 1}) == %{a: {:changed, nil, 1}}
      assert Diffex.diff(%{a: 1}, %{a: nil}) == %{a: {:changed, 1, nil}}
    end

    test "string keys" do
      assert Diffex.diff(%{"a" => 1}, %{"a" => 2}) == %{"a" => {:changed, 1, 2}}
    end

    test "mixed key types" do
      old = %{:a => 1, "b" => 2}
      new = %{:a => 1, "b" => 3}
      assert Diffex.diff(old, new) == %{"b" => {:changed, 2, 3}}
    end

    test "value changing from map to scalar is a :changed operation" do
      assert Diffex.diff(%{a: %{x: 1}}, %{a: 42}) == %{a: {:changed, %{x: 1}, 42}}
    end

    test "value changing from scalar to map is a :changed operation" do
      assert Diffex.diff(%{a: 42}, %{a: %{x: 1}}) == %{a: {:changed, 42, %{x: 1}}}
    end

    test "structs are diffed by field" do
      assert Diffex.diff(%Point{x: 1, y: 2}, %Point{x: 1, y: 3}) == %{y: {:changed, 2, 3}}
    end

    test "struct equal to itself returns empty diff" do
      assert Diffex.diff(%Color{r: 255, g: 0, b: 0}, %Color{r: 255, g: 0, b: 0}) == %{}
    end
  end

  describe "count_changes/1 on a diff" do
    test "empty diff has zero changes" do
      assert Diffex.count_changes(%{}) == 0
    end

    test "single added key" do
      assert Diffex.diff(%{}, %{a: 1}) |> Diffex.count_changes() == 1
    end

    test "single removed key" do
      assert Diffex.diff(%{a: 1}, %{}) |> Diffex.count_changes() == 1
    end

    test "single changed key" do
      assert Diffex.diff(%{a: 1}, %{a: 2}) |> Diffex.count_changes() == 1
    end

    test "nested changes each count separately" do
      diff = Diffex.diff(%{user: %{name: "Alice", age: 30}}, %{user: %{name: "Bob", age: 31}})
      assert Diffex.count_changes(diff) == 2
    end

    test "multiple top-level changes" do
      assert Diffex.diff(%{a: 1, b: 2}, %{a: 1, b: 3, c: 4}) |> Diffex.count_changes() == 2
    end
  end

  describe "apply_diff/2" do
    test "apply added key" do
      assert Diffex.apply_diff(%{a: 1}, %{b: {:added, 2}}) == {:ok, %{a: 1, b: 2}}
    end

    test "apply removed key" do
      assert Diffex.apply_diff(%{a: 1, b: 2}, %{b: {:removed, 2}}) == {:ok, %{a: 1}}
    end

    test "apply changed key" do
      assert Diffex.apply_diff(%{a: 1, b: 2}, %{b: {:changed, 2, 3}}) == {:ok, %{a: 1, b: 3}}
    end

    test "apply empty diff is identity" do
      original = %{a: 1, b: 2}
      assert Diffex.apply_diff(original, %{}) == {:ok, original}
    end

    test "apply nested diff" do
      original = %{user: %{name: "Alice", age: 30}}
      diff = %{user: %{name: {:changed, "Alice", "Bob"}}}
      assert Diffex.apply_diff(original, diff) == {:ok, %{user: %{name: "Bob", age: 30}}}
    end

    test "removed with mismatched expected value returns error" do
      diff = %{b: {:removed, 2}}

      assert Diffex.apply_diff(%{a: 1, b: 999}, diff) ==
               {:error, {:value_mismatch, :b, %{expected: 2, actual: 999}}}
    end

    test "changed with mismatched expected value returns error" do
      diff = %{b: {:changed, 2, 3}}

      assert Diffex.apply_diff(%{a: 1, b: 999}, diff) ==
               {:error, {:value_mismatch, :b, %{expected: 2, actual: 999}}}
    end

    test "nested value mismatch returns path as list" do
      original = %{user: %{age: 99}}
      diff = %{user: %{age: {:changed, 30, 31}}}

      assert Diffex.apply_diff(original, diff) ==
               {:error, {:value_mismatch, [:user, :age], %{expected: 30, actual: 99}}}
    end

    test "apply diff to struct returns struct" do
      original = %Widget{color: :red, size: 5}
      diff = %{size: {:changed, 5, 10}}
      assert Diffex.apply_diff(original, diff) == {:ok, %Widget{color: :red, size: 10}}
    end

    test "added on existing key returns key_exists error" do
      assert Diffex.apply_diff(%{a: 1}, %{a: {:added, 99}}) ==
               {:error, {:key_exists, :a, 1}}
    end

    test "apply diff to struct with unknown field silently drops it" do
      original = %Point{x: 1, y: 2}
      diff = %{z: {:added, 99}}
      assert Diffex.apply_diff(original, diff) == {:ok, %Point{x: 1, y: 2}}
    end

    test "apply diff to struct returns error on value mismatch" do
      original = %Point{x: 1, y: 2}
      diff = %{x: {:changed, 99, 5}}

      assert Diffex.apply_diff(original, diff) ==
               {:error, {:value_mismatch, :x, %{expected: 99, actual: 1}}}
    end

    test "tuple_diff mismatch returns error with key path" do
      diff = %{a: {:tuple_diff, %{1 => {:changed, 2, 9}}}}

      assert Diffex.apply_diff(%{a: {1, 99, 3}}, diff) ==
               {:error, {:value_mismatch, [:a, 1], %{expected: 2, actual: 99}}}
    end

    test "tuple_diff with key_exists error passes through" do
      diff = %{a: {:tuple_diff, %{0 => {:added, 99}}}}

      assert Diffex.apply_diff(%{a: {1, 2}}, diff) == {:error, {:key_exists, 0, 1}}
    end

    test "nested map diff with key_exists error passes through" do
      diff = %{user: %{name: {:added, "Bob"}}}

      assert Diffex.apply_diff(%{user: %{name: "Alice"}}, diff) ==
               {:error, {:key_exists, :name, "Alice"}}
    end
  end

  describe "equal?/2" do
    test "identical maps" do
      assert Diffex.equal?(%{a: 1}, %{a: 1})
    end

    test "different maps" do
      refute Diffex.equal?(%{a: 1}, %{a: 2})
    end

    test "empty maps" do
      assert Diffex.equal?(%{}, %{})
    end

    test "nested equal maps" do
      assert Diffex.equal?(%{a: %{b: 1}}, %{a: %{b: 1}})
    end
  end

  describe "summarize/1" do
    test "added key" do
      diff = Diffex.diff(%{}, %{a: 1})
      assert Diffex.summarize(diff) == ["added :a (value: 1)"]
    end

    test "removed key" do
      diff = Diffex.diff(%{a: 1}, %{})
      assert Diffex.summarize(diff) == ["removed :a (was: 1)"]
    end

    test "changed key" do
      diff = Diffex.diff(%{a: 1}, %{a: 2})
      assert Diffex.summarize(diff) == ["changed :a from 1 to 2"]
    end

    test "empty diff returns empty list" do
      assert Diffex.summarize(%{}) == []
    end

    test "nested change includes full path" do
      diff = Diffex.diff(%{user: %{name: "Alice"}}, %{user: %{name: "Bob"}})
      assert Diffex.summarize(diff) == ["changed :user.:name from \"Alice\" to \"Bob\""]
    end

    test "multiple changes" do
      diff = Diffex.diff(%{a: 1, b: 2}, %{a: 1, c: 3})
      summary = Diffex.summarize(diff)
      assert length(summary) == 2
      assert "added :c (value: 3)" in summary
      assert "removed :b (was: 2)" in summary
    end
  end

  describe "diff/2 lists and tuples" do
    test "equal lists produce no diff entry" do
      assert Diffex.diff(%{a: [1, 2, 3]}, %{a: [1, 2, 3]}) == %{}
    end

    test "equal tuples produce no diff entry" do
      assert Diffex.diff(%{a: {1, 2}}, %{a: {1, 2}}) == %{}
    end

    test "changed element at index" do
      assert Diffex.diff(%{a: [1, 2, 3]}, %{a: [1, 9, 3]}) ==
               %{a: {:list_diff, %{1 => {:changed, 2, 9}}}}
    end

    test "added tail element" do
      assert Diffex.diff(%{a: [1, 2]}, %{a: [1, 2, 3]}) ==
               %{a: {:list_diff, %{2 => {:added, 3}}}}
    end

    test "removed tail element" do
      assert Diffex.diff(%{a: [1, 2, 3]}, %{a: [1, 2]}) ==
               %{a: {:list_diff, %{2 => {:removed, 3}}}}
    end

    test "changed tuple element at index" do
      assert Diffex.diff(%{a: {1, 2, 3}}, %{a: {1, 9, 3}}) ==
               %{a: {:tuple_diff, %{1 => {:changed, 2, 9}}}}
    end

    test "nested map inside list is diffed recursively" do
      old = %{a: [%{x: 1}, %{y: 2}]}
      new = %{a: [%{x: 1}, %{y: 9}]}

      assert Diffex.diff(old, new) ==
               %{a: {:list_diff, %{1 => %{y: {:changed, 2, 9}}}}}
    end

    test "list inside tuple is diffed recursively" do
      old = %{a: {[1, 2], :ok}}
      new = %{a: {[1, 9], :ok}}

      assert Diffex.diff(old, new) ==
               %{a: {:tuple_diff, %{0 => {:list_diff, %{1 => {:changed, 2, 9}}}}}}
    end

    test "list vs non-list is a :changed operation" do
      assert Diffex.diff(%{a: [1, 2]}, %{a: 42}) == %{a: {:changed, [1, 2], 42}}
    end

    test "tuple vs non-tuple is a :changed operation" do
      assert Diffex.diff(%{a: {1, 2}}, %{a: 42}) == %{a: {:changed, {1, 2}, 42}}
    end
  end

  describe "apply_diff/2 lists and tuples" do
    test "apply list_diff" do
      original = %{a: [1, 2, 3]}
      diff = Diffex.diff(original, %{a: [1, 9, 3]})
      assert Diffex.apply_diff(original, diff) == {:ok, %{a: [1, 9, 3]}}
    end

    test "apply tuple_diff" do
      original = %{a: {1, 2, 3}}
      diff = Diffex.diff(original, %{a: {1, 9, 3}})
      assert Diffex.apply_diff(original, diff) == {:ok, %{a: {1, 9, 3}}}
    end

    test "apply list_diff with added element" do
      original = %{a: [1, 2]}
      diff = Diffex.diff(original, %{a: [1, 2, 3]})
      assert Diffex.apply_diff(original, diff) == {:ok, %{a: [1, 2, 3]}}
    end

    test "apply list_diff with removed element" do
      original = %{a: [1, 2, 3]}
      diff = Diffex.diff(original, %{a: [1, 2]})
      assert Diffex.apply_diff(original, diff) == {:ok, %{a: [1, 2]}}
    end

    test "list_diff mismatch returns error" do
      diff = %{a: {:list_diff, %{1 => {:changed, 2, 9}}}}

      assert Diffex.apply_diff(%{a: [1, 99, 3]}, diff) ==
               {:error, {:value_mismatch, [:a, 1], %{expected: 2, actual: 99}}}
    end

    test "apply list_diff removing a middle element compacts correctly" do
      # Hand-crafted diff: remove index 1 from [1,2,3] -> [1,3]
      diff = %{a: {:list_diff, %{1 => {:removed, 2}}}}
      assert Diffex.apply_diff(%{a: [1, 2, 3]}, diff) == {:ok, %{a: [1, 3]}}
    end

    test "added on existing list index returns key_exists error" do
      diff = %{a: {:list_diff, %{0 => {:added, 99}}}}
      assert Diffex.apply_diff(%{a: [1, 2]}, diff) == {:error, {:key_exists, 0, 1}}
    end
  end

  describe "count_changes/1 lists and tuples" do
    test "list_diff counts leaf changes" do
      diff = Diffex.diff(%{a: [1, 2, 3]}, %{a: [1, 9, 3, 4]})
      assert Diffex.count_changes(diff) == 2
    end

    test "tuple_diff counts leaf changes" do
      diff = Diffex.diff(%{a: {1, 2}}, %{a: {9, 9}})
      assert Diffex.count_changes(diff) == 2
    end
  end

  describe "summarize/1 lists and tuples" do
    test "list change includes index in path" do
      diff = Diffex.diff(%{a: [1, 2, 3]}, %{a: [1, 9, 3]})
      assert Diffex.summarize(diff) == ["changed :a.1 from 2 to 9"]
    end

    test "tuple change includes index in path" do
      diff = Diffex.diff(%{a: {1, 2}}, %{a: {1, 9}})
      assert Diffex.summarize(diff) == ["changed :a.1 from 2 to 9"]
    end
  end

  # ---------------------------------------------------------------------------
  # Property-based tests
  # ---------------------------------------------------------------------------

  # Generator for simple scalar values (avoiding maps so we control nesting depth)
  defp scalar_gen do
    one_of([
      integer(),
      string(:alphanumeric),
      atom(:alphanumeric),
      boolean(),
      constant(nil)
    ])
  end

  # Generator for a flat map with atom keys
  defp flat_map_gen do
    map_of(atom(:alphanumeric), scalar_gen(), min_length: 0, max_length: 10)
  end

  # Generator for a shallow-nested map (one level of nesting at most)
  defp shallow_nested_map_gen do
    map_of(
      atom(:alphanumeric),
      one_of([scalar_gen(), flat_map_gen()]),
      min_length: 0,
      max_length: 8
    )
  end

  describe "diff/2 properties" do
    property "diff of a map with itself is always empty" do
      check all(map <- flat_map_gen()) do
        assert Diffex.diff(map, map) == %{}
      end
    end

    property "diff of nested map with itself is always empty" do
      check all(map <- shallow_nested_map_gen()) do
        assert Diffex.diff(map, map) == %{}
      end
    end

    property "all keys in diff are keys from old or new" do
      check all(
              old <- flat_map_gen(),
              new <- flat_map_gen()
            ) do
        diff = Diffex.diff(old, new)
        all_source_keys = Map.keys(old) ++ Map.keys(new)

        for key <- Map.keys(diff) do
          assert key in all_source_keys
        end
      end
    end

    property "added keys exist only in new" do
      check all(
              old <- flat_map_gen(),
              new <- flat_map_gen()
            ) do
        diff = Diffex.diff(old, new)

        for {key, {:added, _val}} <- diff do
          assert Map.has_key?(new, key)
          refute Map.has_key?(old, key)
        end
      end
    end

    property "removed keys exist only in old" do
      check all(
              old <- flat_map_gen(),
              new <- flat_map_gen()
            ) do
        diff = Diffex.diff(old, new)

        for {key, {:removed, _val}} <- diff do
          assert Map.has_key?(old, key)
          refute Map.has_key?(new, key)
        end
      end
    end

    property "changed keys exist in both old and new with different values" do
      check all(
              old <- flat_map_gen(),
              new <- flat_map_gen()
            ) do
        diff = Diffex.diff(old, new)

        for {key, {:changed, old_val, new_val}} <- diff do
          assert Map.has_key?(old, key)
          assert Map.has_key?(new, key)
          assert old_val == Map.get(old, key)
          assert new_val == Map.get(new, key)
          refute old_val == new_val
        end
      end
    end

    property "keys equal in both maps never appear in diff" do
      check all(
              old <- flat_map_gen(),
              extra <- flat_map_gen()
            ) do
        # Build new by changing all values that exist in extra
        new = Map.merge(old, extra)

        diff = Diffex.diff(old, new)
        diff_keys = MapSet.new(Map.keys(diff))

        # Keys whose values are identical should not be in the diff
        for key <- Map.keys(old), Map.get(new, key) == Map.get(old, key) do
          refute MapSet.member?(diff_keys, key)
        end
      end
    end

    property "diff is asymmetric: swapping old and new inverts operations" do
      check all(
              old <- flat_map_gen(),
              new <- flat_map_gen()
            ) do
        forward = Diffex.diff(old, new)
        backward = Diffex.diff(new, old)

        for {key, op} <- forward do
          inverse = Map.get(backward, key)

          case op do
            {:added, val} -> assert inverse == {:removed, val}
            {:removed, val} -> assert inverse == {:added, val}
            {:changed, old_val, new_val} -> assert inverse == {:changed, new_val, old_val}
            nested when is_map(nested) -> assert is_map(inverse)
          end
        end
      end
    end

    property "count_changes is non-negative" do
      check all(
              old <- flat_map_gen(),
              new <- flat_map_gen()
            ) do
        count = Diffex.diff(old, new) |> Diffex.count_changes()
        assert count >= 0
      end
    end

    property "count_changes of identical maps is zero" do
      check all(map <- flat_map_gen()) do
        assert Diffex.diff(map, map) |> Diffex.count_changes() == 0
      end
    end

    property "count_changes is symmetric" do
      check all(
              old <- flat_map_gen(),
              new <- flat_map_gen()
            ) do
        assert Diffex.diff(old, new) |> Diffex.count_changes() ==
                 Diffex.diff(new, old) |> Diffex.count_changes()
      end
    end

    property "equal? is reflexive" do
      check all(map <- flat_map_gen()) do
        assert Diffex.equal?(map, map)
      end
    end

    property "equal? is symmetric" do
      check all(
              old <- flat_map_gen(),
              new <- flat_map_gen()
            ) do
        assert Diffex.equal?(old, new) == Diffex.equal?(new, old)
      end
    end
  end

  describe "apply_diff/2 properties" do
    property "round-trip holds for maps containing lists" do
      check all(
              old <- map_of(atom(:alphanumeric), list_of(integer(), max_length: 5), max_length: 5),
              new <- map_of(atom(:alphanumeric), list_of(integer(), max_length: 5), max_length: 5)
            ) do
        diff = Diffex.diff(old, new)
        assert Diffex.apply_diff(old, diff) == {:ok, new}
      end
    end

    property "applying a diff of map to itself succeeds and returns original" do
      check all(map <- flat_map_gen()) do
        diff = Diffex.diff(map, map)
        assert Diffex.apply_diff(map, diff) == {:ok, map}
      end
    end

    property "round-trip: diff then apply transforms old into new" do
      check all(
              old <- flat_map_gen(),
              new <- flat_map_gen()
            ) do
        diff = Diffex.diff(old, new)
        assert Diffex.apply_diff(old, diff) == {:ok, new}
      end
    end

    property "round-trip holds for nested maps" do
      check all(
              old <- shallow_nested_map_gen(),
              new <- shallow_nested_map_gen()
            ) do
        diff = Diffex.diff(old, new)
        assert Diffex.apply_diff(old, diff) == {:ok, new}
      end
    end

    property "applying to wrong map returns error" do
      check all(
              old <- flat_map_gen(),
              new <- flat_map_gen(),
              # Only relevant when at least one key changed
              old != new
            ) do
        diff = Diffex.diff(old, new)

        # Flip every value in old to something distinct - application should
        # fail on the first :changed key whose expected value no longer matches.
        changed_keys =
          for {key, {:changed, _old_val, _new_val}} <- diff, do: key

        if changed_keys != [] do
          wrong_key = hd(changed_keys)
          wrong_map = Map.put(old, wrong_key, :__wrong_sentinel__)

          result = Diffex.apply_diff(wrong_map, diff)
          assert match?({:error, {:value_mismatch, _, _}}, result)
        end
      end
    end
  end

  describe "summarize/1 properties" do
    property "summarize returns one entry per leaf change" do
      check all(
              old <- flat_map_gen(),
              new <- flat_map_gen()
            ) do
        diff = Diffex.diff(old, new)
        summary = Diffex.summarize(diff)

        # For flat maps each diff key is a leaf - count should match
        assert length(summary) == map_size(diff)
      end
    end

    property "summarize returns empty list for empty diff" do
      check all(map <- flat_map_gen()) do
        assert Diffex.summarize(Diffex.diff(map, map)) == []
      end
    end

    property "all summary strings are non-empty binaries" do
      check all(
              old <- flat_map_gen(),
              new <- flat_map_gen()
            ) do
        for entry <- Diffex.summarize(Diffex.diff(old, new)) do
          assert is_binary(entry)
          assert entry != ""
        end
      end
    end
  end
end
