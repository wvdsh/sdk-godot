# API design

What to expect from a call before you reach the reference: whether it awaits, what it
hands back when it fails, and the few places the API is deliberately strict.

## What a name tells you

- It says whether the call awaits. A synchronous call is answered from memory, or from a
  value the page already holds; an awaited call is a round trip, usually onward to the
  backend, and is never named as a plain read — `fetch_lobby()`, `list_friends()`,
  `create_lobby()`.
- A synchronous read is spelled like the value it answers — `is_muted()`, `get_stat_int()`,
  `has_lobby_data()` — and answers that value's own default when it has nothing better.

Forgetting `await` is a parse error — except when you discard the result, where a bare
`upload_remote_file(path)` statement starts the call and does not wait for it.

## What a call returns when it fails

Every call answers the bare type it names. Nothing is boxed, so there is no field to read
and no null to check on a `String`, `bool` or `Array`.

| what you called | on failure |
|---|---|
| anything awaited that answers with a model — `fetch_lobby`, `fetch_leaderboard`, … | `null` |
| anything awaited that answers with a `String` — `fetch_user_jwt`, `create_lobby`, … | `""` |
| anything awaited that answers with an `Array` — `list_friends`, `list_entitlements`, … | `[]` |
| anything awaited that answers with a `bool` — `fetch_entitlement`, `check_remote_file`, … | `false` |
| `download_content` | `null` |
| `get_username`, `get_lobby_host_id`, `get_user_avatar_url` | `""` |
| `get_leaderboard_entry_count`, `get_num_lobby_users` | `-1` |
| a command, awaited or not — `init`, `set_stat_*`, `store_stats`, `join_lobby`, … | `false` |

- **Every failure carries a reason.** `get_last_error()` is never left at `OK` when a call
  failed — the same contract as Godot's `FileAccess.open()` / `get_open_error()`. Read it
  on the line *after* the call, and not inside a signal handler.
- **`if result:` is enough for a model or a `String`.** Neither is ever legitimately empty
  on success. An empty `Array` can be — a player with no friends, a lobby list with nothing
  in it — so when that difference matters, read `get_last_error()`.
- **A `bool` answer is `false` both for "no" and for "failed".** `fetch_entitlement()`
  answers `false` when the player does not own the content and when the check could not
  run; `get_last_error()` is how you tell the two apart.
- **Integers are the exception.** `0` is a real count, so failure is `-1` and the check is
  `count < 0`.
- `ERR_DOES_NOT_EXIST` means the thing you named is genuinely not there.

## The synchronous reads keep the 1.x contract

`is_fullscreen()`, `is_muted()`, `get_stat_*()`, `get_achievement()`, `get_lobby_users()`,
`has_lobby_data()` and the `get_lobby_data_*()` reads answer the value's own default —
`false`, `0`, `0.0`, `""`, `[]` — when the name is not one this game defines, the key is not
set, stats have not finished loading, or the build is not running on the web. None of them
touch `get_last_error()`. A default is not distinguishable from a real `0` or `false`, so
check the spelling and read them after stats have loaded. `has_lobby_data()` is the one
read that exists to tell an unset key from a stored `false` or `0`.

## Writes do not send defaults

An argument or args field left at its default is *not sent*, so `create_lobby(v)` and
`create_lobby(v, 0)` are the same call. A value that *is* the default therefore cannot be
sent — `UpdateUGCItemArgs.description = ""` will not blank a stored description.

## The rest

- A malformed id, or a path outside `user://`, is a caller bug: it stamps, prints a stack
  trace, and never reaches the network.
- Off the web, every call other than the synchronous reads above returns its failure value
  and reports `ERR_UNAVAILABLE`. Ask `is_available()` once at startup rather than per call.
- `get_launch_params()` and `drain_p2p_channel()` answer `{}` and `[]` both when empty and
  when they failed, because a Dictionary and an Array cannot be null. The error slot
  separates the two.
