-- Drives one running Super PDF process for scripts/e2e.sh, through Accessibility (System Events), and only that one: every
-- command names the process by its unix id, brings it to the front first and refuses to type or click if it isn't in
-- front, so keystrokes and clicks never reach another app.
--   osascript scripts/e2e-drive.applescript <pid> <command> [arguments…]
-- Commands:
--   ready                          the process is known to System Events
--   wait-window <text> <seconds>   a window whose title contains <text>
--   keys <key> <modifiers>         a keystroke; modifiers: none, command, command+shift, option+command…
--   type <text>                    types text into what has focus
--   press <return|escape|tab>      a key
--   click <name> [prefix]          presses the button (or other control) named <name> in the front window or its sheet;
--                                  with "prefix", one whose name starts with it; failing both, one whose name contains it
--                                  (SwiftUI buttons with a symbol read "Add, Create signature…")
--   click-text <text>              clicks the middle of the text <text> (controls that only react to clicks)
--   fill <placeholder> <text>      types into the text field showing <placeholder>
--   click-in <name> <fx> <fy>      clicks inside the element named or described <name>, at fractions of its size
--   click-page <fx> <fy>           clicks the page in the document view at fractions of its size
--   goto <path>                    in an open or save panel: Go to Folder… <path>
--   wait-element <name> <seconds>  an element named or described <name> appears
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
	else if command is "wait-element" then
		return waitElement(p, item 3 of argv, (item 4 of argv) as integer)
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
	else if command is "click" then
		set controls to {"AXButton", "AXRadioButton", "AXCheckBox", "AXMenuButton", "AXPopUpButton", "AXCell"}
		set target to findElement(p, item 3 of argv, (count of argv) > 3, controls)
		if target is missing value then set target to findContaining(p, item 3 of argv, controls)
		if target is missing value then error "No control named " & (item 3 of argv)
		tell application "System Events"
			try
				perform action "AXPress" of target
			on error
				click target
			end try
		end tell
	else if command is "click-text" then
		set target to findElement(p, item 3 of argv, false, {"AXStaticText"})
		if target is missing value then error "No text " & (item 3 of argv)
		clickInside(target, 0.5, 0.5)
	else if command is "fill" then
		set target to findField(p, item 3 of argv)
		if target is missing value then error "No text field showing " & (item 3 of argv)
		tell application "System Events"
			set focused of target to true
			delay 0.2
			keystroke (item 4 of argv)
		end tell
	else if command is "click-in" then
		set target to findElement(p, item 3 of argv, false, {})
		if target is missing value then error "No element " & (item 3 of argv)
		clickInside(target, (item 4 of argv) as real, (item 5 of argv) as real)
	else if command is "click-page" then
		set target to largestScrollArea(p)
		if target is missing value then error "No document view"
		clickInside(target, (item 3 of argv) as real, (item 4 of argv) as real)
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
		set frontmost of p to true
		repeat 20 times
			if frontmost of p then exit repeat
			delay 0.1
		end repeat
		if not (frontmost of p) then error "Super PDF isn't in front; nothing was typed or clicked"
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

on waitWindow(p, needle, seconds)
	repeat (seconds * 4) times
		tell application "System Events"
			repeat with w in (every window of p)
				if (name of w as text) contains needle then return "ok"
			end repeat
		end tell
		delay 0.25
	end repeat
	error "No window with " & needle & " after " & seconds & " s"
end waitWindow

on waitElement(p, needle, seconds)
	repeat (seconds * 2) times
		if findElement(p, needle, false, {}) is not missing value then return "ok"
		delay 0.5
	end repeat
	error "No " & needle & " after " & seconds & " s"
end waitElement

-- The first element of the front window (sheets and dialogs included) whose title or description is `needle`, among
-- `roles` (any role when empty).
on findElement(p, needle, prefixOnly, roles)
	tell application "System Events"
		set candidates to {}
		try
			set candidates to entire contents of front window of p
		end try
		repeat with e in candidates
			try
				set r to role of e
				if (count of roles) is 0 or roles contains r then
					set n to ""
					try
						set n to name of e as text
					end try
					set d to ""
					try
						set d to description of e as text
					end try
					set t to ""
					try
						set t to value of attribute "AXTitle" of e as text
					end try
					if n is needle or d is needle or t is needle then return e
					if prefixOnly and (n starts with needle or d starts with needle or t starts with needle) then return e
				end if
			end try
		end repeat
	end tell
	return missing value
end findElement

-- The first element among `roles` whose title or description contains `needle`.
on findContaining(p, needle, roles)
	tell application "System Events"
		repeat with e in (entire contents of front window of p)
			try
				if roles contains (role of e) then
					set n to ""
					try
						set n to name of e as text
					end try
					set d to ""
					try
						set d to description of e as text
					end try
					if n contains needle or d contains needle then return e
				end if
			end try
		end repeat
	end tell
	return missing value
end findContaining

on findField(p, placeholder)
	tell application "System Events"
		repeat with e in (entire contents of front window of p)
			try
				if role of e is "AXTextField" then
					set shown to ""
					try
						set shown to value of attribute "AXPlaceholderValue" of e as text
					end try
					if shown is placeholder then return e
				end if
			end try
		end repeat
	end tell
	return missing value
end findField

on largestScrollArea(p)
	set best to missing value
	set bestArea to 0
	tell application "System Events"
		repeat with e in (entire contents of front window of p)
			try
				if role of e is "AXScrollArea" then
					set {w, h} to size of e
					if w * h > bestArea then
						set best to e
						set bestArea to w * h
					end if
				end if
			end try
		end repeat
	end tell
	return best
end largestScrollArea

on clickInside(target, fx, fy)
	tell application "System Events"
		set {x, y} to position of target
		set {w, h} to size of target
		click at {(x + w * fx) as integer, (y + h * fy) as integer}
	end tell
end clickInside
