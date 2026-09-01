@tool
extends RefCounted

## Team/project (organization/game) API surface, built on WavedashCliRunner.
## `list` and `create` are the only subcommands that exist.

const WavedashCompat = preload("wavedash_compat.gd")
const WavedashCliRunner = preload("wavedash_cli_runner.gd")
## Typed form of a `wavedash team list --json` entry, which carries exactly these
## three fields.
class Team:
	var id := ""
	var name := ""
	var slug := ""

	static func from_dict(d: Dictionary) -> Team:
		var team := Team.new()
		team.id = d.get("_id", "")
		team.name = d.get("name", "")
		team.slug = d.get("slug", "")
		return team

## `team_id` is not in the project JSON at all -- it is implicit in which team was
## queried, so from_dict() takes it separately.
class Project:
	var id := ""
	var title := ""
	var slug := ""
	var team_id := ""

	static func from_dict(d: Dictionary, team_id: String) -> Project:
		var project := Project.new()
		project.id = d.get("_id", "")
		project.title = d.get("title", "")
		project.slug = d.get("slug", "")
		project.team_id = team_id
		return project


## Every list call is a blocking CLI subprocess and find_project() costs 1+N of
## them, so results are held for the session. invalidate() is called wherever the
## answer can change: sign-in state, and creating a team or game.
## Absent rather than empty when uncached, so a genuine "no teams" answer is still a hit.
const TEAMS_KEY := "project_api_teams"
const PROJECTS_KEY := "project_api_projects"

static func invalidate() -> void:
	WavedashCompat.session_set(TEAMS_KEY, null)
	WavedashCompat.session_set(PROJECTS_KEY, null)

static func list_teams() -> Array[Team]:
	var cached = WavedashCompat.session_get(TEAMS_KEY, null)
	if cached != null:
		return _teams_from(cached)
	var result := WavedashCliRunner.run_json(["team", "list", "--json"])
	if not result.ok or not (result.data is Array):
		# Failures aren't cached -- they're usually transient (no key, no CLI).
		var none: Array[Team] = []
		return none
	var raw := []
	for entry in result.data:
		if entry is Dictionary:
			raw.append(entry)
	WavedashCompat.session_set(TEAMS_KEY, raw)
	return _teams_from(raw)

static func _teams_from(raw: Array) -> Array[Team]:
	var teams: Array[Team] = []
	for entry in raw:
		teams.append(Team.from_dict(entry))
	return teams

static func list_projects(team_id: String) -> Array[Project]:
	var by_team: Dictionary = WavedashCompat.session_get(PROJECTS_KEY, {})
	if by_team.has(team_id):
		return _projects_from(by_team[team_id], team_id)
	var result := WavedashCliRunner.run_json(["project", "list", "--team-id", team_id, "--json"])
	if not result.ok or not (result.data is Array):
		var none: Array[Project] = []
		return none
	var raw := []
	for entry in result.data:
		if entry is Dictionary:
			raw.append(entry)
	by_team[team_id] = raw
	WavedashCompat.session_set(PROJECTS_KEY, by_team)
	return _projects_from(raw, team_id)

static func _projects_from(raw: Array, team_id: String) -> Array[Project]:
	var projects: Array[Project] = []
	for entry in raw:
		projects.append(Project.from_dict(entry, team_id))
	return projects

## `create` has no --json; success is one line ending "(id: <id>)". Matched on
## that ASCII tail, never the leading "✓", which the Windows console codepage
## mangles. `slug` is left blank -- the plain-text output doesn't carry it.
static func create_team(name: String) -> Team:
	var result := WavedashCliRunner.run(["team", "create", "--name", name])
	if not result.ok:
		return null
	var id := _extract_id(result.output)
	if id == "":
		return null
	var team := Team.new()
	team.id = id
	team.name = name
	invalidate()
	return team

static func create_project(title: String, team_id: String) -> Project:
	var result := WavedashCliRunner.run(["project", "create", "--title", title, "--team-id", team_id])
	if not result.ok:
		return null
	var id := _extract_id(result.output)
	if id == "":
		return null
	var project := Project.new()
	project.id = id
	project.title = title
	project.team_id = team_id
	invalidate()
	return project

## Searches team by team, since no "get game by id" command exists. Both entries
## are null when the game was deleted or belongs to a team this account can't see.
static func find_project_with_team(game_id: String) -> Dictionary:
	if game_id != "":
		for team in list_teams():
			for project in list_projects(team.id):
				if project.id == game_id:
					return {"team": team, "project": project}
	return {"team": null, "project": null}

static func find_project(game_id: String) -> Project:
	return find_project_with_team(game_id).project

static func _id_regex() -> RegEx:
	return RegEx.create_from_string("\\(id:\\s*([^)]+)\\)")

static func _extract_id(output: String) -> String:
	var id_match := _id_regex().search(output)
	return id_match.get_string(1).strip_edges() if id_match else ""
