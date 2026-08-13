@tool
extends HBoxContainer

## "Wavedash Account: <status> [Sign In.../Recheck]" dock row. See WavedashAuth
## for why signing in needs no CLI.

const WavedashAuth = preload("wavedash_auth.gd")
const WavedashProjectApi = preload("wavedash_project_api.gd")
const WavedashDialogs = preload("wavedash_dialogs.gd")
const WavedashIconTheme = preload("wavedash_icon_theme.gd")
const RecheckIcon = preload("assets/refresh_cw_white.svg")
const SignInIcon = preload("assets/user_round_key_white.svg")
const LogOutIcon = preload("assets/log_out_white.svg")
const WavedashCompat = preload("wavedash_compat.gd")

signal log_line(text: String)
signal status_changed

## Setup here would dirty the open scene and bake session state into a shipped .tscn.
@onready var _in_edited_scene := WavedashCompat.is_part_of_edited_scene(self)

@onready var _status_label: Label = $SignInStatus
## Both live in one expanding container, so together they occupy the width a
## single button gets in the other rows -- and Sign In fills it alone when Log Out
## is hidden.
@onready var _action_button: Button = $Buttons/ActionButton
@onready var _logout_button: Button = $Buttons/LogoutButton

## What the button should do next, so dispatch doesn't depend on label wording.
var _authenticated := false

func _ready() -> void:
	if _in_edited_scene:
		return
	_action_button.pressed.connect(_on_action_pressed)
	_logout_button.pressed.connect(_on_logout_pressed)
	_refresh_status()

func _refresh_status() -> void:
	# Sign-in state decides which teams and games are visible at all, so the
	# cached answers can't outlive a change here.
	WavedashProjectApi.invalidate()
	var result := WavedashAuth.check_status()
	_authenticated = result.authenticated
	_logout_button.visible = result.authenticated
	if result.authenticated:
		# Email moves to the tooltip: the row is narrow and clips, and the key
		# preview is the more useful of the two at a glance.
		# "with key" so the preview doesn't read as a username.
		_status_label.text = ("Signed in with key %s" % result.key_preview) if result.key_preview != "" else "Signed in"
		_status_label.tooltip_text = ("Signed in as %s" % result.email) if result.email != "" else ""
		_action_button.text = "Recheck"
	else:
		_status_label.text = "Not signed in"
		_status_label.tooltip_text = ""
		_action_button.text = "Sign In"
	_apply_icons()
	status_changed.emit()

## The action button is two actions in one, so its icon follows the same state
## its label does.
func _apply_icons() -> void:
	_action_button.icon = RecheckIcon if _authenticated else SignInIcon
	WavedashIconTheme.apply_to_button(_action_button)
	_logout_button.icon = LogOutIcon
	WavedashIconTheme.apply_to_button(_logout_button)

func _notification(what: int) -> void:
	if _in_edited_scene:
		return
	if what == NOTIFICATION_THEME_CHANGED and _action_button:
		_apply_icons()

## Recheck only ever updates the display, even if it finds the token gone: the
## sign-in dialog must open from a deliberate click, never as a side effect.
func _on_action_pressed() -> void:
	if _authenticated:
		_refresh_status()
	else:
		_prompt_sign_in()

func _prompt_sign_in() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Connect Wavedash Account"
	dialog.get_ok_button().text = "Save"
	dialog.get_ok_button().disabled = true
	dialog.add_button("Create API Key", false, "open_portal")

	# AcceptDialog assigns every direct Control child the same content rect, so
	# multiple children overlap instead of stacking. One container child fixes it.
	var content_box := VBoxContainer.new()
	content_box.add_theme_constant_override("separation", 8)
	dialog.add_child(content_box)

	var message := Label.new()
	message.text = "Generate an API key in the Wavedash Developer Portal, then paste it below."
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.custom_minimum_size = Vector2(WavedashDialogs.CONTENT_MIN_WIDTH, 0)
	content_box.add_child(message)

	var token_edit := LineEdit.new()
	token_edit.placeholder_text = "Paste API key..."
	token_edit.secret = true
	content_box.add_child(token_edit)

	token_edit.text_changed.connect(func(new_text: String) -> void:
		dialog.get_ok_button().disabled = new_text.strip_edges().is_empty()
	)
	dialog.custom_action.connect(func(action: StringName) -> void:
		if action == "open_portal":
			OS.shell_open(WavedashAuth.DEV_PORTAL_KEYS_URL)
	)
	dialog.confirmed.connect(func() -> void:
		_save_token(token_edit.text.strip_edges())
	)
	WavedashDialogs.show_dialog(dialog)
	token_edit.grab_focus()

func _save_token(token: String) -> void:
	var err := WavedashAuth.save_token(token)
	if err != OK:
		log_line.emit("Failed to save Wavedash API key: %s" % error_string(err))
		return
	log_line.emit("Saved Wavedash API key to %s" % WavedashAuth.get_credentials_path())
	_refresh_status()

func _on_logout_pressed() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Log Out of Wavedash"
	dialog.dialog_text = "You'll need to paste your API key again to sign back in. Continue?"
	dialog.get_ok_button().text = "Log Out"
	dialog.confirmed.connect(_do_logout)
	WavedashDialogs.show_dialog(dialog)

func _do_logout() -> void:
	var err := WavedashAuth.log_out()
	if err != OK:
		log_line.emit("Failed to log out: %s" % error_string(err))
		return
	log_line.emit("Logged out of Wavedash.")
	_refresh_status()
