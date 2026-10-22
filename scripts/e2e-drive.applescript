-- Drives one running Super PDF process for scripts/e2e.sh, through System Events, and only that one: every command names
-- the process by its unix id, brings it to the front first and refuses to type if it isn't in front, so keystrokes never
-- reach another app. Finding and pressing controls is scripts/e2e-ax.swift (System Events can't read the labels SwiftUI
-- controls give VoiceOver).
--   osascript scripts/e2e-drive.applescript <pid> <command> [arguments…]
-- Commands:
--   ready                          the process is known to System Events
--   wait-window <text> <seconds>   a window whose title contains <text>
--   keys <key> <modifiers>         a keystroke; modifiers: none, command, command+shift, option+command…
--   type <text>                    types text into what has focus
--   press <return|escape|tab>      a key
--   goto <path>                    in an open or save panel: Go to Folder… <path>
--   windows                        the titles of its windows (for the log)

on run argv
	set thePID to (item 1 of argv) as integer
	set command to item 2 of argv
	if command is "ready" then
		tell application "System Events" to return (exists (first process whose unix id is thePID)) as text
	end if
	tell application "System Events"
		set p to first process whose unix id is thePID
	end tell
	if command is "windows" then
		tell application "System Events" to return name of every window of p
	else if command is "wait-window" then
		return waitWindow(p, item 3 of argv, (item 4 of argv) as integer)
	end if
	bringToFront(p)
	if command is "keys" then
		pressKeys(p, item 3 of argv, item 4 of argv)
	else if command is "type" then
		tell application "System Events" to keystroke (item 3 of argv)
	else if command is "press" then
		set keyName to item 3 of argv
		tell application "System Events"
			if keyName is "return" then key code 36
			if keyName is "escape" then key code 53
			if keyName is "tab" then key code 48
		end tell
	else if command is "goto" then
		pressKeys(p, "g", "command+shift")
		delay 0.8
		tell application "System Events"
			keystroke (item 3 of argv)
			delay 0.5
			key code 36
		end tell
	else
		error "Unknown command " & command
	end if
	return "ok"
end run

on bringToFront(p)
	tell application "System Events"
		repeat 50 times
			if frontmost of p then exit repeat
			set frontmost of p to true
			delay 0.1
		end repeat
		if not (frontmost of p) then error "Super PDF isn't in front; nothing was typed"
	end tell
end bringToFront

on pressKeys(p, theKey, modifiers)
	set mods to {}
	if modifiers contains "command" then set end of mods to command down
	if modifiers contains "shift" then set end of mods to shift down
	if modifiers contains "option" then set end of mods to option down
	if modifiers contains "control" then set end of mods to control down
	tell application "System Events"
		if (count of mods) is 0 then
			keystroke theKey
		else
			keystroke theKey using mods
		end if
	end tell
end pressKeys

on waitWindow(p, needle, waitSecs)
	repeat (waitSecs * 4) times
		tell application "System Events"
			-- A process that isn't in front lists no windows.
			set frontmost of p to true
			repeat with w in (every window of p)
				if (name of w as text) contains needle then return "ok"
			end repeat
		end tell
		delay 0.25
	end repeat
	error "No window with " & needle & " after " & waitSecs & " s"
end waitWindow
