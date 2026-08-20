# API design

What to expect from a call before you reach the reference: whether it awaits, what it
hands back when it fails, and the few places the API is deliberately strict.

## What a name tells you

- It does not promise a bare value. A call that can fail answers with a box or `null`, so
  it is spelled `try_get_muted()` rather than `is_muted()`.
- It says whether the call awaits. A synchronous call is answered from memory, or from a
  value the page already holds; an awaited call is a round trip, usually onward to the
  backend, and is never named as a plain read.

Forgetting `await` is a parse error — except when you discard the result, where a bare
`upload_remote_file(path)` statement starts the call and does not wait for it.

## What a call returns when it fails

| what you called | on failure |
|---|---|
| anything awaited that answers with data, and every `try_get_*` | `null` |
| `download_content` | `null` |
| `get_username`, `get_lobby_host_id`, `get_user_avatar_url` | `""` |
| `get_leaderboard_entry_count`, `get_num_lobby_users` | `-1` |
| a command, awaited or not — `init`, `set_stat_*`, `store_stats`, `join_lobby`, … | `false` |

- **`if result:` means it worked, `if not result:` means it did not** — every failure value
  above is falsy, so one check covers `null`, `""` and `false` alike.
- **Integers are the exception.** `0` is a real count, so failure is `-1` and the check is
  `count < 0`.
- **Every failure carries a reason.** `get_last_error()` is never left at `OK` when a call
  failed — the same contract as Godot's `FileAccess.open()` / `get_open_error()`. Read it
  on the line *after* the call, and not inside a signal handler.
- `ERR_DOES_NOT_EXIST` means a key genuinely is not set; `ERR_INVALID_DATA` means it holds
  another type, and the message says which.

## Boxes

- A `String`, `bool`, `int`, `float` or `Array` result comes back in an `…Optional` box,
  because GDScript has no nullable primitive. Null-check, then read the field.
- The field is named for what it holds — `bool_value`, `friends` — never a bare `value`.
- A box holding `false` is an **answer**; only `null` is a failure. `fetch_entitlement()`
  answering `false` means the player does not own the content.
- A model comes back bare, since an object reference is already nullable.

## Typed getters do not coerce

A getter answers only for the type it names, and returns `null` rather than inventing a
plausible value.

- `try_get_lobby_data_int()` on a stored `"dust2"` is `null`, not the `2` that GDScript's
  `int(String)` would produce.
- `try_get_lobby_data_int()` on `2.5` is `null`, because an int cannot round-trip it —
  read it with `try_get_lobby_data_float()`.
- The bool getters are `null` if the page answers with anything but a bool, since
  `bool("false")` would otherwise be `true`.

## Reads and writes disagree about defaults, deliberately

- **Reading**: there are no `default` arguments. `""` and `0` are values a game may have
  stored, so a getter hands back a box or `null` and you apply your own default.
- **Writing**: an argument or args field left at its default is *not sent*, so
  `create_lobby(v)` and `create_lobby(v, 0)` are the same call. A value that *is* the
  default therefore cannot be sent — `UpdateUGCItemArgs.description = ""` will not blank a
  stored description.

## The rest

- A malformed id, or a path outside `user://`, is a caller bug: it stamps, prints a stack
  trace, and never reaches the network.
- Off the web every call returns its failure value and reports `ERR_UNAVAILABLE`. Ask
  `is_available()` once at startup rather than per call.
- `get_launch_params()` and `drain_p2p_channel()` answer `{}` and `[]` both when empty and
  when they failed, because a Dictionary and an Array cannot be null. The error slot
  separates the two.
- `try_get_stat_*()` and `try_get_achievement()` answer a box holding `0` / `false` for a
  name this game does not define, and again before stats have finished loading. Neither is
  distinguishable from a real `0` or a locked achievement, so check the spelling and read
  them after stats have loaded.
