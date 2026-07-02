# Diffex

A dependency-free Elixir library for computing minimal diffs between nested maps, structs, lists, and tuples.

## Installation

```elixir
def deps do
  [
    {:diffex, "~> 0.1"}
  ]
end
```

## Overview

Diffex compares two maps (or structs) and returns a plain map describing what changed. You can inspect it, serialize it, store it, or apply it later.

```elixir
Diffex.diff(%{name: "Alice", age: 30}, %{name: "Alice", age: 31})
#=> %{age: {:changed, 30, 31}}
```

Unchanged keys are omitted. An empty map means no differences.

## Functions

- [`diff/2`](#diff2) - compute what changed
- [`apply_diff/2`](#apply_diff2) - apply a diff to a map/struct
- [`equal?/2`](#equal2) - check whether two maps are identical
- [`count_changes/1`](#count_changes1) - count leaf-level changes in a diff
- [`summarize/1`](#summarize1) - human-readable list of changes

---

## `diff/2`

```elixir
Diffex.diff(old, new) :: %{key => diff_value}
```

Returns a map describing the differences. Each value is one of:

| Shape | Meaning |
|---|---|
| `{:added, value}` | Key exists only in `new` |
| `{:removed, value}` | Key exists only in `old` |
| `{:changed, old, new}` | Scalar value changed |
| `%{...}` | Nested diff (recursive) |
| `{:list_diff, %{index => diff_value}}` | List diffed by index position |
| `{:tuple_diff, %{index => diff_value}}` | Tuple diffed by index position |

### Basic map diff

```elixir
old = %{status: :active, score: 10, label: "foo"}
new = %{status: :active, score: 15, tag: "bar"}

Diffex.diff(old, new)
#=> %{
#=>   score: {:changed, 10, 15},
#=>   label: {:removed, "foo"},
#=>   tag:   {:added, "bar"}
#=> }
```

### Nested maps

Nested maps are diffed recursively. Only changed leaves appear; unchanged subtrees are omitted.

```elixir
old = %{user: %{name: "Alice", role: :admin, settings: %{theme: :dark}}}
new = %{user: %{name: "Bob",   role: :admin, settings: %{theme: :light}}}

Diffex.diff(old, new)
#=> %{
#=>   user: %{
#=>     name:     {:changed, "Alice", "Bob"},
#=>     settings: %{theme: {:changed, :dark, :light}}
#=>   }
#=> }
```

### Structs

Structs are compared field-by-field. Both sides must be the same struct type (or plain maps).

```elixir
defmodule Point, do: defstruct [:x, :y]

Diffex.diff(%Point{x: 0, y: 5}, %Point{x: 3, y: 5})
#=> %{x: {:changed, 0, 3}}
```

### Lists and tuples

Lists and tuples are diffed by index position.

```elixir
Diffex.diff(%{coords: [1, 2, 3]}, %{coords: [1, 9, 3]})
#=> %{coords: {:list_diff, %{1 => {:changed, 2, 9}}}}

Diffex.diff(%{coords: [1, 2]}, %{coords: [1, 2, 3]})
#=> %{coords: {:list_diff, %{2 => {:added, 3}}}}
```

Nested structures inside lists are diffed recursively:

```elixir
old = %{items: [%{id: 1, qty: 5}, %{id: 2, qty: 3}]}
new = %{items: [%{id: 1, qty: 5}, %{id: 2, qty: 9}]}

Diffex.diff(old, new)
#=> %{items: {:list_diff, %{1 => %{qty: {:changed, 3, 9}}}}}
```

### No differences

An empty map means the inputs are identical.

```elixir
Diffex.diff(%{a: 1, b: %{c: 2}}, %{a: 1, b: %{c: 2}})
#=> %{}
```

---

## `apply_diff/2`

```elixir
Diffex.apply_diff(original, diff) :: {:ok, map()} | {:error, reason}
```

Applies a diff to a map or struct. Before applying `:changed` and `:removed` operations, the current value is checked against the expected "before" value. If they don't match, `apply_diff/2` returns an error rather than applying a stale or conflicting diff.

### Round-trip

```elixir
old = %{name: "Alice", score: 10}
new = %{name: "Alice", score: 15, badge: :gold}

diff = Diffex.diff(old, new)
Diffex.apply_diff(old, diff)
#=> {:ok, %{name: "Alice", score: 15, badge: :gold}}
```

### Applying to structs

```elixir
defmodule Config, do: defstruct [:host, :port]

old = %Config{host: "localhost", port: 4000}
diff = %{port: {:changed, 4000, 8080}}

Diffex.apply_diff(old, diff)
#=> {:ok, %Config{host: "localhost", port: 8080}}
```

### Error: value mismatch

If the current value doesn't match the expected "before" value, the application fails:

```elixir
diff = %{score: {:changed, 10, 15}}

Diffex.apply_diff(%{score: 99}, diff)
#=> {:error, {:value_mismatch, :score, %{expected: 10, actual: 99}}}
```

For nested mismatches the key is a list representing the path:

```elixir
diff = Diffex.diff(
  %{user: %{age: 30}},
  %{user: %{age: 31}}
)

Diffex.apply_diff(%{user: %{age: 99}}, diff)
#=> {:error, {:value_mismatch, [:user, :age], %{expected: 30, actual: 99}}}
```

### Error: key already exists

Applying an `:added` operation to a map that already has that key fails:

```elixir
diff = %{name: {:added, "Bob"}}

Diffex.apply_diff(%{name: "Alice"}, diff)
#=> {:error, {:key_exists, :name, "Alice"}}
```

---

## `equal?/2`

```elixir
Diffex.equal?(old, new) :: boolean()
```

Returns `true` if the two maps are structurally identical (no diff).

```elixir
Diffex.equal?(%{a: 1, b: %{c: 2}}, %{a: 1, b: %{c: 2}})
#=> true

Diffex.equal?(%{a: 1}, %{a: 2})
#=> false
```

---

## `count_changes/1`

```elixir
Diffex.count_changes(diff) :: non_neg_integer()
```

Counts leaf-level changes in a diff. Each `:added`, `:removed`, or `:changed` entry counts as 1; nested diffs are traversed recursively.

```elixir
diff = Diffex.diff(
  %{user: %{name: "Alice", age: 30}, active: true},
  %{user: %{name: "Bob",   age: 31}, active: true}
)

Diffex.count_changes(diff)
#=> 2
```

Useful for gating behavior on "how much changed":

```elixir
diff = Diffex.diff(old_config, new_config)

if Diffex.count_changes(diff) > 10 do
  Logger.warning("Large config change detected")
end
```

---

## `summarize/1`

```elixir
Diffex.summarize(diff) :: [String.t()]
```

Returns a list of strings describing each leaf change. Nested paths are joined with `.`.

```elixir
old = %{user: %{name: "Alice", role: :viewer}, plan: :free}
new = %{user: %{name: "Alice", role: :admin},  plan: :pro}

Diffex.diff(old, new) |> Diffex.summarize()
#=> [
#=>   "changed :user.:role from :viewer to :admin",
#=>   "changed :plan from :free to :pro"
#=> ]
```

List index changes include the numeric index in the path:

```elixir
Diffex.diff(%{tags: ["a", "b", "c"]}, %{tags: ["a", "x", "c"]})
|> Diffex.summarize()
#=> ["changed :tags.1 from \"b\" to \"x\""]
```

Returns an empty list when there are no changes:

```elixir
Diffex.diff(%{a: 1}, %{a: 1}) |> Diffex.summarize()
#=> []
```

---

## Common patterns

### Audit logging

Store a diff alongside each update to record what changed and when.

```elixir
def update_user(user, params) do
  new_user = User.changeset(user, params) |> Repo.update!()
  diff = Diffex.diff(user, new_user)

  unless diff == %{} do
    AuditLog.insert(%{entity_id: user.id, changes: diff})
  end

  new_user
end
```

### Conditional re-rendering / side effects

Only trigger expensive work when the relevant fields actually changed.

```elixir
diff = Diffex.diff(old_settings, new_settings)

if Map.has_key?(diff, :email) do
  Mailer.send_confirmation(new_settings.email)
end
```

### Optimistic apply with conflict detection

Apply a stored diff and detect whether the record changed since the diff was computed.

```elixir
case Diffex.apply_diff(current_record, stored_diff) do
  {:ok, updated} ->
    Repo.update!(updated)

  {:error, {:value_mismatch, path, %{expected: exp, actual: got}}} ->
    {:error, "Conflict at #{inspect(path)}: expected #{inspect(exp)}, got #{inspect(got)}"}
end
```
