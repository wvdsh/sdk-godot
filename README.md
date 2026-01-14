# Wavedash SDK for Godot

A Godot Engine plugin that enables Godot Web Build games to use [Wavedash Online Services](https://docs.wavedash.com/).

## Features

- **Leaderboards** — Create competitive leaderboards with configurable sorting and pagination
- **Multiplayer Lobbies** — Build real-time multiplayer experiences with lobby management and messaging
- **P2P Networking** — Connect players directly with WebRTC-based peer-to-peer networking
- **Achievements & Stats** — Track player progress with achievements and stats that sync across sessions
- **Cloud Storage** — Save player data and files to the cloud with per-user isolated storage
- **User Generated Content** — Enable players to upload and share user-generated content

## Requirements

- **Godot 4.5** or higher
- **Web export** only (the SDK interfaces with JavaScript APIs available on Wavedash)

## Installation

1. Copy the `wavedash/` folder into your project's `addons/` directory:
   ```
   your-project/
   └── addons/
       └── wavedash/
           ├── plugin.cfg
           ├── WavedashConstants.gd
           ├── WavedashPlugin.gd
           └── WavedashSDK.gd
   ```

2. Enable the plugin in **Project → Project Settings → Plugins**

3. The SDK will be available as an autoload singleton named `WavedashSDK`

## Quick Start

### Initialize the SDK

```gdscript
func _ready():
    # Initialize with custom configuration
    WavedashSDK.init({
        debug: false,
        deferEvents: true
    })

    # ... game startup
    
    # Signal to JS SDK that game is ready to receive events
    WavedashSDK.ready_for_events()
```

### Get Current User

```gdscript
var user_id = WavedashSDK.get_user_id()
var username = WavedashSDK.get_username()
print("Welcome, %s!" % username)
```

## Leaderboards

### Get or Create a Leaderboard

```gdscript
# Connect to the signal first
WavedashSDK.got_leaderboard.connect(_on_got_leaderboard)

# Create a leaderboard (ascending scores, numeric display)
WavedashSDK.get_or_create_leaderboard(
    "high_scores",
    WavedashConstants.LEADERBOARD_SORT_DESCENDING,
    WavedashConstants.LEADERBOARD_DISPLAY_TYPE_NUMERIC
)

func _on_got_leaderboard(response: Dictionary):
    if response.get("success", false):
        var leaderboard = response["data"]
        print("Leaderboard ID: ", leaderboard["id"])
```

### Submit a Score

```gdscript
WavedashSDK.posted_leaderboard_score.connect(_on_score_posted)

# Submit score, keeping the player's best score
WavedashSDK.post_leaderboard_score(leaderboard_id, 1000, true)

func _on_score_posted(response: Dictionary):
    if response.get("success", false):
        print("Score submitted!")
```

### Get Leaderboard Entries

```gdscript
WavedashSDK.got_leaderboard_entries.connect(_on_got_entries)

# Get top 10 entries
WavedashSDK.get_leaderboard_entries(leaderboard_id, 0, 10, false)

# Or get entries around the current player
WavedashSDK.get_leaderboard_entries_around_player(leaderboard_id, 5, 5, false)

func _on_got_entries(response: Dictionary):
    if response.get("success", false):
        var entries = response["data"]
        for entry in entries:
            print("%s: %d" % [entry["username"], entry["score"]])
```

## Multiplayer Lobbies

### Create a Lobby

```gdscript
WavedashSDK.lobby_created.connect(_on_lobby_created)

# Create a public lobby with max 4 players
WavedashSDK.create_lobby(WavedashConstants.LOBBY_TYPE_PUBLIC, 4)

func _on_lobby_created(response: Dictionary):
    if response.get("success", false):
        var lobby_id = response["data"]
        print("Created lobby: ", lobby_id)
```

### Join a Lobby

```gdscript
WavedashSDK.lobby_joined.connect(_on_lobby_joined)

WavedashSDK.join_lobby(lobby_id)

func _on_lobby_joined(response: Dictionary):
    if response.get("success", false):
        print("Joined lobby!")
```

### List Available Lobbies

```gdscript
WavedashSDK.got_lobbies.connect(_on_got_lobbies)

WavedashSDK.list_available_lobbies()

func _on_got_lobbies(lobbies: Array):
    for lobby in lobbies:
        print("Lobby: ", lobby["lobbyId"])
```

### Lobby Data & Messaging

```gdscript
# Set lobby data (host only)
WavedashSDK.set_lobby_data(lobby_id, "game_mode", "deathmatch")

# Get lobby data
var game_mode = WavedashSDK.get_lobby_data(lobby_id, "game_mode")

# Send a chat message
WavedashSDK.send_lobby_chat_message(lobby_id, "Hello everyone!")

# Listen for messages
WavedashSDK.lobby_message.connect(_on_lobby_message)

func _on_lobby_message(data: Dictionary):
    print("%s: %s" % [data["username"], data["message"]])
```

### Lobby Events

```gdscript
# Users joining/leaving
WavedashSDK.lobby_users_updated.connect(_on_users_updated)

func _on_users_updated(data: Dictionary):
    var user_id = data["userId"]
    var change_type = data["changeType"]  # "JOINED" or "LEFT"
    print("User %s %s the lobby" % [user_id, change_type])
```

## P2P Networking

### Send Messages

```gdscript
# Send to a specific player
var payload = "Hello".to_utf8_buffer()
WavedashSDK.send_p2p_message(target_user_id, payload, 0, true)

# Broadcast to all peers
WavedashSDK.send_p2p_message("", payload, 0, true)
```

### Receive Messages

```gdscript
func _process(_delta):
    # Drain all messages from channel 0
    var messages = WavedashSDK.drain_p2p_channel(0)
    for msg in messages:
        var from_user = msg["identity"]
        var channel = msg["channel"]
        var payload: PackedByteArray = msg["payload"]
        print("Received from %s: %s" % [from_user, payload.get_string_from_utf8()])
```

### P2P Connection Events

```gdscript
WavedashSDK.p2p_connection_established.connect(_on_p2p_connected)
WavedashSDK.p2p_connection_failed.connect(_on_p2p_failed)
WavedashSDK.p2p_peer_disconnected.connect(_on_peer_disconnected)
```

## Achievements & Stats

### Stats

```gdscript
# Request current stats from server
WavedashSDK.current_stats_received.connect(_on_stats_received)
WavedashSDK.request_stats()

# Get a stat value
var kills = WavedashSDK.get_stat_int("total_kills")

# Set a stat (store_now=true to persist immediately)
WavedashSDK.set_stat_int("total_kills", kills + 1, true)
```

### Achievements

```gdscript
# Unlock an achievement
WavedashSDK.set_achievement("first_win")

# Check if achievement is unlocked
var unlocked = WavedashSDK.get_achievement("first_win")
```

## Cloud Storage

```gdscript
# Upload a file
WavedashSDK.remote_file_uploaded.connect(_on_file_uploaded)
WavedashSDK.upload_remote_file("user://save_data.json")

# Download a file
WavedashSDK.remote_file_downloaded.connect(_on_file_downloaded)
WavedashSDK.download_remote_file("user://save_data.json")

# Download an entire directory
WavedashSDK.remote_directory_downloaded.connect(_on_directory_downloaded)
WavedashSDK.download_remote_directory("user://saves/")
```

## User Generated Content (UGC)

### Create UGC Item

```gdscript
WavedashSDK.ugc_item_created.connect(_on_ugc_created)

WavedashSDK.create_ugc_item(
    WavedashConstants.UGC_TYPE_COMMUNITY,
    "My Level",
    "A custom level I made",
    WavedashConstants.UGC_VISIBILITY_PUBLIC,
    "user://levels/my_level.dat"
)

func _on_ugc_created(response: Dictionary):
    if response.get("success", false):
        var ugc_id = response["data"]
        print("Created UGC item: ", ugc_id)
```

### Download UGC Item

```gdscript
WavedashSDK.ugc_item_downloaded.connect(_on_ugc_downloaded)
WavedashSDK.download_ugc_item(ugc_id, "user://downloads/level.dat")
```

## Signals Reference

| Signal | Description |
|--------|-------------|
| `lobby_joined(payload)` | Emitted when joining a lobby |
| `lobby_created(payload)` | Emitted when creating a lobby |
| `lobby_message(payload)` | Emitted when receiving a lobby chat message |
| `lobby_left(payload)` | Emitted when leaving a lobby |
| `lobby_data_updated(payload)` | Emitted when lobby data changes |
| `lobby_users_updated(payload)` | Emitted when users join/leave |
| `lobby_kicked(payload)` | Emitted when kicked from a lobby |
| `got_lobbies(payload)` | Emitted with list of available lobbies |
| `got_leaderboard(payload)` | Emitted with leaderboard info |
| `got_leaderboard_entries(payload)` | Emitted with leaderboard entries |
| `posted_leaderboard_score(payload)` | Emitted after submitting a score |
| `ugc_item_created(payload)` | Emitted after creating UGC |
| `ugc_item_updated(payload)` | Emitted after updating UGC |
| `ugc_item_downloaded(payload)` | Emitted after downloading UGC |
| `remote_file_downloaded(payload)` | Emitted after downloading a file |
| `remote_file_uploaded(payload)` | Emitted after uploading a file |
| `remote_directory_downloaded(payload)` | Emitted after downloading a directory |
| `p2p_connection_established(payload)` | Emitted when P2P connection is ready |
| `p2p_connection_failed(payload)` | Emitted when P2P connection fails |
| `p2p_peer_disconnected(payload)` | Emitted when a peer disconnects |
| `current_stats_received(payload)` | Emitted with current player stats |
| `backend_connected(payload)` | Emitted when connected to backend |
| `backend_reconnecting(payload)` | Emitted when reconnecting |
| `backend_disconnected(payload)` | Emitted when disconnected |

## Constants Reference

### Lobby Types
- `LOBBY_TYPE_PUBLIC` (0)
- `LOBBY_TYPE_FRIENDS_ONLY` (1)
- `LOBBY_TYPE_PRIVATE` (2)

### Leaderboard Sort Methods
- `LEADERBOARD_SORT_ASCENDING` (0)
- `LEADERBOARD_SORT_DESCENDING` (1)

### Leaderboard Display Types
- `LEADERBOARD_DISPLAY_TYPE_NUMERIC` (0)
- `LEADERBOARD_DISPLAY_TYPE_TIME_SECONDS` (1)
- `LEADERBOARD_DISPLAY_TYPE_TIME_MILLISECONDS` (2)
- `LEADERBOARD_DISPLAY_TYPE_TIME_GAME_TICKS` (3)

### UGC Types
- `UGC_TYPE_SCREENSHOT` (0)
- `UGC_TYPE_VIDEO` (1)
- `UGC_TYPE_COMMUNITY` (2)
- `UGC_TYPE_GAME_MANAGED` (3)
- `UGC_TYPE_OTHER` (4)

### UGC Visibility
- `UGC_VISIBILITY_PUBLIC` (0)
- `UGC_VISIBILITY_FRIENDS_ONLY` (1)
- `UGC_VISIBILITY_PRIVATE` (2)

## Documentation

For complete documentation, guides, and API reference, visit the [Wavedash Developer Docs](https://docs.wavedash.com/).
