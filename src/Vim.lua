--!strict
-- A modal vim. Separate from the nano overlay -- they share only the VFS
-- load/save plumbing, which lives in the shell command.
--
-- Input model: Roblox hands scripts KeyCodes, not characters, so shift-dependent
-- keys ($, :, G, O) are a nightmare to reconstruct. Instead a focused,
-- transparent TextBox acts purely as a *character stream* -- it is emptied on
-- every change and the typed characters are fed to the active mode. That yields
-- correct case and symbols for free. UserInputService handles only the keys that
-- produce no character: Esc, Backspace, Enter, Ctrl+R, arrows.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local Ansi = require(ReplicatedStorage.Shell.Ansi)
local UI = require(script.Parent.UI)

local HUGE = Vector2.new(math.huge, math.huge)

-- The pixel width of a run of text as the line labels actually draw it. This is
-- the only honest way to place the caret, because not every character is one
-- cell wide: a tab is a single *column* but renders four cells *wide*. Counting
-- columns and multiplying by CHAR_WIDTH -- which is what this used to do -- drifts
-- the caret three cells left of the text for every tab before it, so on an
-- indented line like "\treturn 0;" the caret sat in the middle of "return".
-- Measuring the real prefix asks the layout engine the same question the
-- TextLabel does, so the caret lands exactly where the glyph is drawn.
local function textWidth(text: string): number
	if text == "" then
		return 0
	end
	return TextService:GetTextSize(text, UI.TEXT_SIZE, UI.FONT, HUGE).X
end

local Vim = {}
Vim.__index = Vim

local MAX_UNDO = 200
local STATUS_HEIGHT = UI.LINE_HEIGHT + 4

-- Held keys repeat on this clock. Roblox fires InputBegan once per physical press
-- and never again while the key is held -- the engine has no auto-repeat for
-- scripts -- so everything vim handles itself (Backspace and the arrows produce no
-- character at all, so they can only arrive that way) simply never repeated. nano
-- was never affected because it is a real editable TextBox: Roblox does its
-- deleting, and the OS's own repeat drives it.
--
-- Character keys are the odd case: the OS keeps feeding repeated characters into
-- the focused capture TextBox on its own. This clock owns their repeat too, and
-- those duplicates are dropped where they arrive, so a held key repeats at one
-- rate whether or not the OS is also repeating it.
local REPEAT_DELAY = 0.4
local REPEAT_INTERVAL = 0.03

local function hex(color: string): Color3
	return Color3.fromHex(color)
end

local function splitLines(content: string): { string }
	local lines = {}
	local start = 1

	while true do
		local br = string.find(content, "\n", start, true)
		if not br then
			table.insert(lines, string.sub(content, start))
			break
		end
		table.insert(lines, string.sub(content, start, br - 1))
		start = br + 1
	end

	return lines
end

local function isWordChar(char: string): boolean
	return string.match(char, "[%w_]") ~= nil
end

function Vim.new(parent: Frame)
	return setmetatable({
		parent = parent,
		root = nil,
		conns = {},
		lineLabels = {},
		selectionFrames = {},
	}, Vim)
end

--[[ Buffer state ]]

function Vim:_text(): string
	return table.concat(self.lines, "\n")
end

function Vim:_isModified(): boolean
	return self:_text() ~= self.savedText
end

function Vim:_clamp()
	self.cursorLine = math.clamp(self.cursorLine, 1, #self.lines)

	local length = #self.lines[self.cursorLine]
	-- Insert mode may sit one past the last character; normal mode may not.
	local maxCol = if self.mode == "insert" then length + 1 else math.max(length, 1)
	self.cursorCol = math.clamp(self.cursorCol, 1, maxCol)
end

function Vim:_snapshot()
	table.insert(self.undoStack, {
		lines = table.clone(self.lines),
		line = self.cursorLine,
		col = self.cursorCol,
	})
	if #self.undoStack > MAX_UNDO then
		table.remove(self.undoStack, 1)
	end
	-- A fresh change invalidates the redo branch, same as vim.
	self.redoStack = {}
end

function Vim:_undo()
	local snapshot = table.remove(self.undoStack)
	if not snapshot then
		self:_setStatus("Already at oldest change", false)
		return
	end

	table.insert(self.redoStack, {
		lines = table.clone(self.lines),
		line = self.cursorLine,
		col = self.cursorCol,
	})

	self.lines = snapshot.lines
	self.cursorLine, self.cursorCol = snapshot.line, snapshot.col
	self:_clamp()
end

function Vim:_redo()
	local snapshot = table.remove(self.redoStack)
	if not snapshot then
		self:_setStatus("Already at newest change", false)
		return
	end

	table.insert(self.undoStack, {
		lines = table.clone(self.lines),
		line = self.cursorLine,
		col = self.cursorCol,
	})

	self.lines = snapshot.lines
	self.cursorLine, self.cursorCol = snapshot.line, snapshot.col
	self:_clamp()
end

--[[ Motions ]]

function Vim:_wordForward()
	local line = self.lines[self.cursorLine]
	local col = self.cursorCol

	-- Step off the current word, then over any run of spaces.
	while col <= #line and isWordChar(string.sub(line, col, col)) do
		col += 1
	end
	while col <= #line and not isWordChar(string.sub(line, col, col)) do
		col += 1
	end

	if col > #line then
		if self.cursorLine < #self.lines then
			self.cursorLine += 1
			self.cursorCol = 1
			local next = self.lines[self.cursorLine]
			while self.cursorCol <= #next and not isWordChar(string.sub(next, self.cursorCol, self.cursorCol)) do
				self.cursorCol += 1
			end
		else
			self.cursorCol = math.max(#line, 1)
		end
	else
		self.cursorCol = col
	end
end

function Vim:_wordBackward()
	local col = self.cursorCol - 1

	if col < 1 then
		if self.cursorLine > 1 then
			self.cursorLine -= 1
			self.cursorCol = math.max(#self.lines[self.cursorLine], 1)
		end
		return
	end

	local line = self.lines[self.cursorLine]
	while col >= 1 and not isWordChar(string.sub(line, col, col)) do
		col -= 1
	end
	while col > 1 and isWordChar(string.sub(line, col - 1, col - 1)) do
		col -= 1
	end

	self.cursorCol = math.max(col, 1)
end

--[[ Register / edits ]]

function Vim:_yankLines(from: number, to: number)
	local yanked = {}
	for index = from, to do
		table.insert(yanked, self.lines[index])
	end
	self.register = { lines = yanked, linewise = true }
end

function Vim:_deleteLines(from: number, to: number)
	for _ = from, to do
		table.remove(self.lines, from)
	end
	if #self.lines == 0 then
		self.lines = { "" }
	end
end

-- Charwise span between two positions, inclusive of both ends (vim's `v`).
function Vim:_span(): (number, number, number, number)
	local aLine, aCol = self.anchorLine, self.anchorCol
	local bLine, bCol = self.cursorLine, self.cursorCol

	if aLine > bLine or (aLine == bLine and aCol > bCol) then
		aLine, bLine = bLine, aLine
		aCol, bCol = bCol, aCol
	end
	return aLine, aCol, bLine, bCol
end

function Vim:_yankSpan(startLine: number, startCol: number, endLine: number, endCol: number)
	if startLine == endLine then
		local line = self.lines[startLine]
		self.register = { lines = { string.sub(line, startCol, endCol) }, linewise = false }
		return
	end

	local chunk = { string.sub(self.lines[startLine], startCol) }
	for index = startLine + 1, endLine - 1 do
		table.insert(chunk, self.lines[index])
	end
	table.insert(chunk, string.sub(self.lines[endLine], 1, endCol))
	self.register = { lines = chunk, linewise = false }
end

function Vim:_deleteSpan(startLine: number, startCol: number, endLine: number, endCol: number)
	if startLine == endLine then
		local line = self.lines[startLine]
		self.lines[startLine] = string.sub(line, 1, startCol - 1) .. string.sub(line, endCol + 1)
	else
		local head = string.sub(self.lines[startLine], 1, startCol - 1)
		local tail = string.sub(self.lines[endLine], endCol + 1)
		for _ = startLine + 1, endLine do
			table.remove(self.lines, startLine + 1)
		end
		self.lines[startLine] = head .. tail
	end

	self.cursorLine = startLine
	self.cursorCol = startCol
	if #self.lines == 0 then
		self.lines = { "" }
	end
end

function Vim:_paste()
	local register = self.register
	if not register or #register.lines == 0 then
		return
	end

	self:_snapshot()

	if register.linewise then
		-- p puts linewise text on the line *after* the cursor.
		for offset, line in register.lines do
			table.insert(self.lines, self.cursorLine + offset, line)
		end
		self.cursorLine += 1
		self.cursorCol = 1
	else
		local line = self.lines[self.cursorLine]
		local at = math.min(self.cursorCol + 1, #line + 1)

		if #register.lines == 1 then
			local text = register.lines[1]
			self.lines[self.cursorLine] = string.sub(line, 1, at - 1) .. text .. string.sub(line, at)
			self.cursorCol = at + #text - 1
		else
			local head = string.sub(line, 1, at - 1)
			local tail = string.sub(line, at)
			self.lines[self.cursorLine] = head .. register.lines[1]
			for index = 2, #register.lines do
				table.insert(self.lines, self.cursorLine + index - 1, register.lines[index])
			end
			local last = self.cursorLine + #register.lines - 1
			self.lines[last] ..= tail
			self.cursorLine = last
			self.cursorCol = 1
		end
	end

	self:_clamp()
end

--[[ Search ]]

function Vim:_matches(): { { line: number, col: number } }
	local found = {}
	if not self.lastSearch or self.lastSearch == "" then
		return found
	end

	for index, line in self.lines do
		local start = 1
		while true do
			-- Plain substring: no regex, per scope.
			local at = string.find(line, self.lastSearch, start, true)
			if not at then
				break
			end
			table.insert(found, { line = index, col = at })
			start = at + 1
		end
	end

	return found
end

function Vim:_jumpSearch(forward: boolean)
	local found = self:_matches()
	if #found == 0 then
		self:_setStatus("E486: Pattern not found: " .. tostring(self.lastSearch), true)
		return
	end

	if forward then
		for _, match in found do
			if match.line > self.cursorLine or (match.line == self.cursorLine and match.col > self.cursorCol) then
				self.cursorLine, self.cursorCol = match.line, match.col
				return
			end
		end
		self.cursorLine, self.cursorCol = found[1].line, found[1].col
		self:_setStatus("search hit BOTTOM, continuing at TOP", false)
	else
		for index = #found, 1, -1 do
			local match = found[index]
			if match.line < self.cursorLine or (match.line == self.cursorLine and match.col < self.cursorCol) then
				self.cursorLine, self.cursorCol = match.line, match.col
				return
			end
		end
		local last = found[#found]
		self.cursorLine, self.cursorCol = last.line, last.col
		self:_setStatus("search hit TOP, continuing at BOTTOM", false)
	end
end

--[[ Modes ]]

function Vim:_enterInsert()
	self:_snapshot()
	self.mode = "insert"
	self:_clamp()
end

function Vim:_leaveInsert()
	self.mode = "normal"
	-- vim steps the cursor back off the position past the last character.
	self.cursorCol = math.max(self.cursorCol - 1, 1)
	self:_clamp()
end

function Vim:_normalKey(char: string)
	local pending = self.pending
	self.pending = nil

	-- Two-key sequences: dd, yy, gg.
	if pending == "d" then
		if char == "d" then
			self:_snapshot()
			self:_yankLines(self.cursorLine, self.cursorLine)
			self:_deleteLines(self.cursorLine, self.cursorLine)
			self:_clamp()
		end
		return
	elseif pending == "y" then
		if char == "y" then
			self:_yankLines(self.cursorLine, self.cursorLine)
			self:_setStatus("1 line yanked", false)
		end
		return
	elseif pending == "g" then
		if char == "g" then
			self.cursorLine = 1
			self.cursorCol = 1
		end
		return
	end

	if char == "h" then
		self.cursorCol -= 1
	elseif char == "l" then
		self.cursorCol += 1
	elseif char == "j" then
		self.cursorLine += 1
	elseif char == "k" then
		self.cursorLine -= 1
	elseif char == "w" then
		self:_wordForward()
	elseif char == "b" then
		self:_wordBackward()
	elseif char == "0" then
		self.cursorCol = 1
	elseif char == "$" then
		self.cursorCol = math.max(#self.lines[self.cursorLine], 1)
	elseif char == "G" then
		self.cursorLine = #self.lines
		self.cursorCol = 1
	elseif char == "g" then
		self.pending = "g"
	elseif char == "d" then
		self.pending = "d"
	elseif char == "y" then
		self.pending = "y"
	elseif char == "x" then
		local line = self.lines[self.cursorLine]
		if #line > 0 then
			self:_snapshot()
			self.register = { lines = { string.sub(line, self.cursorCol, self.cursorCol) }, linewise = false }
			self.lines[self.cursorLine] = string.sub(line, 1, self.cursorCol - 1) .. string.sub(line, self.cursorCol + 1)
		end
	elseif char == "p" then
		self:_paste()
	elseif char == "u" then
		self:_undo()
	elseif char == "i" then
		self:_enterInsert()
	elseif char == "a" then
		self.cursorCol += 1
		self:_enterInsert()
	elseif char == "o" then
		self:_snapshot()
		table.insert(self.lines, self.cursorLine + 1, "")
		self.cursorLine += 1
		self.cursorCol = 1
		self.mode = "insert"
	elseif char == "O" then
		self:_snapshot()
		table.insert(self.lines, self.cursorLine, "")
		self.cursorCol = 1
		self.mode = "insert"
	elseif char == "v" then
		self.mode = "visual"
		self.anchorLine, self.anchorCol = self.cursorLine, self.cursorCol
	elseif char == "V" then
		self.mode = "vline"
		self.anchorLine, self.anchorCol = self.cursorLine, 1
	elseif char == "n" then
		self:_jumpSearch(true)
	elseif char == "N" then
		self:_jumpSearch(false)
	elseif char == ":" or char == "/" then
		self.mode = "command"
		self.cmdline = char
	end

	self:_clamp()
end

function Vim:_visualKey(char: string)
	local linewise = self.mode == "vline"

	if char == "h" then
		self.cursorCol -= 1
	elseif char == "l" then
		self.cursorCol += 1
	elseif char == "j" then
		self.cursorLine += 1
	elseif char == "k" then
		self.cursorLine -= 1
	elseif char == "0" then
		self.cursorCol = 1
	elseif char == "$" then
		self.cursorCol = math.max(#self.lines[self.cursorLine], 1)
	elseif char == "d" or char == "y" then
		local startLine, startCol, endLine, endCol = self:_span()

		if linewise then
			if char == "d" then
				self:_snapshot()
				self:_yankLines(startLine, endLine)
				self:_deleteLines(startLine, endLine)
				self.cursorLine = startLine
				self.cursorCol = 1
			else
				self:_yankLines(startLine, endLine)
				self.cursorLine = startLine
			end
			self:_setStatus(string.format("%d lines %s", endLine - startLine + 1, if char == "d" then "deleted" else "yanked"), false)
		else
			if char == "d" then
				self:_snapshot()
				self:_yankSpan(startLine, startCol, endLine, endCol)
				self:_deleteSpan(startLine, startCol, endLine, endCol)
			else
				self:_yankSpan(startLine, startCol, endLine, endCol)
				self.cursorLine, self.cursorCol = startLine, startCol
			end
		end

		self.mode = "normal"
	end

	self:_clamp()
end

function Vim:_runCommand()
	local text = self.cmdline
	self.cmdline = ""
	self.mode = "normal"

	if string.sub(text, 1, 1) == "/" then
		local pattern = string.sub(text, 2)
		if pattern ~= "" then
			self.lastSearch = pattern
		end
		self:_jumpSearch(true)
		return
	end

	local command = string.sub(text, 2)

	if command == "w" or command == "w!" then
		self:_save()
	elseif command == "q" then
		if self:_isModified() then
			self:_setStatus("E37: No write since last change (add ! to override)", true)
		else
			self:_quit()
		end
	elseif command == "q!" then
		self:_quit()
	elseif command == "wq" or command == "x" or command == "wq!" then
		if self:_save() then
			self:_quit()
		end
	elseif command == "" then
		-- bare ":" -- nothing to do
	else
		self:_setStatus("E492: Not an editor command: " .. command, true)
	end
end

function Vim:_commandKey(char: string)
	if char == "\n" or char == "\r" then
		self:_runCommand()
	else
		self.cmdline ..= char
	end
end

--[[ Save / quit ]]

function Vim:_save(): boolean
	local text = self:_text()
	local ok, message = self.saveCallback(text)

	if ok then
		self.savedText = text
	end
	self:_setStatus(message, not ok)
	return ok
end

function Vim:_quit()
	self.quitting = true
	self.held = nil

	for _, conn in self.conns do
		conn:Disconnect()
	end
	self.conns = {}

	self.box:ReleaseFocus(false)
	if self.root then
		self.root:Destroy()
		self.root = nil
	end

	local resolve = self.resolve
	self.resolve = nil
	if resolve then
		resolve()
	end
end

--[[ Input ]]

function Vim:_ctrlDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
end

function Vim:_feed(char: string)
	-- vim clears the previous message on the next keystroke; without this a stale
	-- "2 lines deleted" lingers over unrelated later actions.
	self.statusMessage = ""
	self.statusIsError = false

	if self.mode == "insert" then
		if char == "\n" or char == "\r" then
			local line = self.lines[self.cursorLine]
			local head = string.sub(line, 1, self.cursorCol - 1)
			local tail = string.sub(line, self.cursorCol)
			self.lines[self.cursorLine] = head
			table.insert(self.lines, self.cursorLine + 1, tail)
			self.cursorLine += 1
			self.cursorCol = 1
		else
			local line = self.lines[self.cursorLine]
			self.lines[self.cursorLine] = string.sub(line, 1, self.cursorCol - 1)
				.. char
				.. string.sub(line, self.cursorCol)
			self.cursorCol += 1
		end
	elseif self.mode == "command" then
		self:_commandKey(char)
	elseif self.mode == "visual" or self.mode == "vline" then
		if char ~= "\n" and char ~= "\r" then
			self:_visualKey(char)
		end
	else
		if char ~= "\n" and char ~= "\r" then
			self:_normalKey(char)
		end
	end
end

-- Hold a key and `act` runs again every REPEAT_INTERVAL until it is released.
-- `char` is set for a character key, and names the character the key is repeating,
-- so the OS's own repeats of it can be told apart from a real keystroke.
function Vim:_arm(key: Enum.KeyCode, act: () -> (), char: string?)
	self.held = { key = key, act = act, char = char, due = os.clock() + REPEAT_DELAY }
end

function Vim:_backspace()
	if self.mode == "insert" then
		if self.cursorCol > 1 then
			local line = self.lines[self.cursorLine]
			self.lines[self.cursorLine] = string.sub(line, 1, self.cursorCol - 2) .. string.sub(line, self.cursorCol)
			self.cursorCol -= 1
		elseif self.cursorLine > 1 then
			local current = table.remove(self.lines, self.cursorLine) :: string
			self.cursorLine -= 1
			self.cursorCol = #self.lines[self.cursorLine] + 1
			self.lines[self.cursorLine] ..= current
		end
	elseif self.mode == "command" then
		self.cmdline = string.sub(self.cmdline, 1, #self.cmdline - 1)
		if self.cmdline == "" then
			self.mode = "normal"
		end
	end
end

-- The arrows are the same motions as hjkl, and insert mode gets them too (it is
-- the only way to move there).
function Vim:_motion(motion: string)
	if self.mode == "insert" then
		if motion == "h" then
			self.cursorCol -= 1
		elseif motion == "l" then
			self.cursorCol += 1
		elseif motion == "j" then
			self.cursorLine += 1
		else
			self.cursorLine -= 1
		end
		self:_clamp()
	elseif self.mode == "visual" or self.mode == "vline" then
		self:_visualKey(motion)
	else
		self:_normalKey(motion)
	end
end

-- Esc, Backspace, Ctrl+R and the arrows produce no character, so they come
-- through UserInputService instead of the TextBox stream.
function Vim:_onKey(input: InputObject)
	if input.UserInputType ~= Enum.UserInputType.Keyboard or not self.root then
		return
	end

	local key = input.KeyCode
	local ctrl = self:_ctrlDown()

	-- Which key the next character belongs to, so a held character key can be
	-- repeated on our clock (see the capture TextBox handler).
	self.lastKey = key

	-- Roblox never fires InputBegan for an auto-repeat, so an InputBegan for the key
	-- we are already repeating can only be a genuine second press: end the old repeat
	-- rather than let it mistake this press's character for one of the OS's.
	if self.held and self.held.key == key then
		self.held = nil
	end

	-- Roblox permanently binds Escape to the CoreGui menu, so it also pops the
	-- Roblox menu. Ctrl+[ and Ctrl+C are vim's own aliases for Esc and are the
	-- reliable way out here.
	local isEscape = key == Enum.KeyCode.Escape
		or (ctrl and (key == Enum.KeyCode.LeftBracket or key == Enum.KeyCode.C))

	if isEscape then
		if self.mode == "insert" then
			self:_leaveInsert()
		elseif self.mode == "command" then
			self.cmdline = ""
			self.mode = "normal"
		else
			self.mode = "normal"
		end
		self.pending = nil
		self:_render()
		return
	end

	if ctrl and key == Enum.KeyCode.R then
		self:_redo()
		self:_render()
		return
	end

	if key == Enum.KeyCode.Backspace then
		self:_backspace()
		self:_render()
		self:_arm(key, function()
			self:_backspace()
			self:_render()
		end)
		return
	end

	if key == Enum.KeyCode.Return then
		if self.mode == "command" then
			self:_runCommand()
			self:_render()
		end
		return
	end

	local arrows = {
		[Enum.KeyCode.Left] = "h",
		[Enum.KeyCode.Down] = "j",
		[Enum.KeyCode.Up] = "k",
		[Enum.KeyCode.Right] = "l",
	}
	local motion = arrows[key]
	if motion and self.mode ~= "command" then
		self:_motion(motion)
		self:_render()
		self:_arm(key, function()
			self:_motion(motion)
			self:_render()
		end)
	end
end

--[[ Render ]]

function Vim:_setStatus(message: string, isError: boolean)
	self.statusMessage = message
	self.statusIsError = isError
end

function Vim:_modeText(): string
	if self.mode == "insert" then
		return "-- INSERT --"
	elseif self.mode == "visual" then
		return "-- VISUAL --"
	elseif self.mode == "vline" then
		return "-- VISUAL LINE --"
	elseif self.mode == "command" then
		return self.cmdline
	end

	if self.statusMessage ~= "" then
		return self.statusMessage
	end

	local modified = if self:_isModified() then " [+]" else ""
	return string.format('"%s"%s %dL, %dB', self.filename, modified, #self.lines, #self:_text())
end

function Vim:_lineLabel(index: number): TextLabel
	local label = self.lineLabels[index]
	if not label then
		label = Instance.new("TextLabel")
		label.Name = "L" .. index
		label.BackgroundTransparency = 1
		label.Font = UI.FONT
		label.TextSize = UI.TEXT_SIZE
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.RichText = false
		label.Size = UDim2.new(1, 0, 0, UI.LINE_HEIGHT)
		label.ZIndex = 12
		label.Parent = self.buffer
		self.lineLabels[index] = label
	end
	return label
end

function Vim:_render()
	if not self.root then
		return
	end

	self:_clamp()

	local rows = math.max(math.floor(self.buffer.AbsoluteSize.Y / UI.LINE_HEIGHT), 1)
	local total = math.max(#self.lines, rows)

	for index = 1, total do
		local label = self:_lineLabel(index)
		label.Position = UDim2.new(0, 0, 0, (index - 1) * UI.LINE_HEIGHT)
		label.Visible = true

		if index <= #self.lines then
			label.Text = self.lines[index]
			label.TextColor3 = hex(Ansi.Colors.fg)
		else
			-- vim fills the space past end-of-file with blue tildes.
			label.Text = "~"
			label.TextColor3 = hex(Ansi.Colors.blue)
		end
	end

	for index = total + 1, #self.lineLabels do
		self.lineLabels[index].Visible = false
	end

	self.buffer.CanvasSize = UDim2.new(0, 0, 0, total * UI.LINE_HEIGHT)

	-- Selection highlight (RichText has no background colour, so this is drawn as
	-- frames behind the text).
	for _, frame in self.selectionFrames do
		frame.Visible = false
	end

	if self.mode == "visual" or self.mode == "vline" then
		local startLine, startCol, endLine, endCol = self:_span()
		local slot = 0

		for index = startLine, endLine do
			slot += 1
			local frame = self.selectionFrames[slot]
			if not frame then
				frame = Instance.new("Frame")
				frame.BorderSizePixel = 0
				frame.BackgroundColor3 = hex(Ansi.Colors.grey)
				frame.BackgroundTransparency = 0.45
				frame.ZIndex = 11
				frame.Parent = self.buffer
				self.selectionFrames[slot] = frame
			end

			local length = #self.lines[index]
			local from, to
			if self.mode == "vline" then
				from, to = 1, math.max(length, 1)
			else
				from = if index == startLine then startCol else 1
				to = if index == endLine then endCol else math.max(length, 1)
			end

			-- Pixel spans, not column spans, for the same reason as the caret: a tab
			-- inside a selection is wider than one cell, and the highlight has to cover
			-- what is actually drawn. `to` is inclusive, so the right edge is the width
			-- up to and including it.
			local lineText = self.lines[index]
			local x0 = textWidth(string.sub(lineText, 1, from - 1))
			local x1 = textWidth(string.sub(lineText, 1, to))

			frame.Visible = true
			frame.Position = UDim2.new(0, x0, 0, (index - 1) * UI.LINE_HEIGHT)
			frame.Size = UDim2.new(0, math.max(x1 - x0, UI.CHAR_WIDTH), 0, UI.LINE_HEIGHT)
		end
	end

	-- Cursor: a block in normal/visual, a thin bar in insert, like a real terminal vim.
	-- Its X is the measured width of everything to its left, so tabs push it along
	-- exactly as far as they push the text.
	local insert = self.mode == "insert"
	local lineText = self.lines[self.cursorLine]
	local caretX = textWidth(string.sub(lineText, 1, self.cursorCol - 1))

	-- A normal-mode block sits *on* a character, so it is as wide as that character
	-- is drawn -- four cells over a tab, one over anything else -- and covers the
	-- glyph exactly. The insert bar is a thin sliver with no glyph to cover.
	local onChar = string.sub(lineText, self.cursorCol, self.cursorCol)
	local blockWidth = if onChar == "" then UI.CHAR_WIDTH else textWidth(onChar)

	self.cursor.Visible = self.mode ~= "command"
	self.cursor.Size = UDim2.new(0, if insert then 2 else math.ceil(blockWidth), 0, UI.TEXT_SIZE)
	self.cursor.Position = UDim2.new(
		0,
		caretX,
		0,
		(self.cursorLine - 1) * UI.LINE_HEIGHT + (UI.LINE_HEIGHT - UI.TEXT_SIZE) / 2
	)

	-- Keep the cursor line on screen.
	local cursorY = (self.cursorLine - 1) * UI.LINE_HEIGHT
	local top = self.buffer.CanvasPosition.Y
	local viewHeight = self.buffer.AbsoluteWindowSize.Y
	if cursorY < top then
		self.buffer.CanvasPosition = Vector2.new(0, cursorY)
	elseif cursorY + UI.LINE_HEIGHT > top + viewHeight then
		self.buffer.CanvasPosition = Vector2.new(0, cursorY + UI.LINE_HEIGHT - viewHeight)
	end

	local status = self:_modeText()
	self.statusLabel.Text = status
	self.statusLabel.TextColor3 = if self.statusIsError then hex(Ansi.Colors.bg) else hex(Ansi.Colors.fg)
	self.statusLabel.BackgroundColor3 = hex(Ansi.Colors.red)
	self.statusLabel.BackgroundTransparency = if self.statusIsError then 0 else 1

	-- vim's ruler.
	self.rulerLabel.Text = string.format("%d,%d", self.cursorLine, self.cursorCol)
end

--[[ Entry point ]]

-- Blocks until the user quits.
function Vim:open(filename: string, content: string, save: (string) -> (boolean, string))
	local thread = coroutine.running()

	self.filename = filename
	self.lines = splitLines(content)
	self.savedText = content
	self.saveCallback = save
	self.mode = "normal"
	self.cursorLine = 1
	self.cursorCol = 1
	self.cmdline = ""
	self.pending = nil
	self.register = nil
	self.lastSearch = nil
	self.undoStack = {}
	self.redoStack = {}
	self.statusMessage = ""
	self.statusIsError = false
	self.quitting = false
	self.held = nil
	self.lastKey = nil
	self.lineLabels = {}
	self.selectionFrames = {}

	local root = Instance.new("Frame")
	root.Name = "Vim"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = hex(Ansi.Colors.bg)
	root.BorderSizePixel = 0
	root.ZIndex = 10
	root.Parent = self.parent
	self.root = root

	local buffer = Instance.new("ScrollingFrame")
	buffer.Name = "Buffer"
	buffer.Position = UDim2.new(0, UI.PADDING, 0, UI.PADDING)
	buffer.Size = UDim2.new(1, -UI.PADDING * 2, 1, -(STATUS_HEIGHT + UI.PADDING * 2))
	buffer.BackgroundTransparency = 1
	buffer.BorderSizePixel = 0
	buffer.CanvasSize = UDim2.new()
	buffer.ScrollBarThickness = 4
	buffer.ScrollBarImageTransparency = 0.7
	buffer.ZIndex = 11
	buffer.Parent = root
	self.buffer = buffer

	local cursor = Instance.new("Frame")
	cursor.Name = "Cursor"
	cursor.BackgroundColor3 = hex(Ansi.Colors.fg)
	cursor.BackgroundTransparency = 0.25
	cursor.BorderSizePixel = 0
	cursor.ZIndex = 13
	cursor.Parent = buffer
	self.cursor = cursor

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.AnchorPoint = Vector2.new(0, 1)
	status.Position = UDim2.new(0, 0, 1, 0)
	status.Size = UDim2.new(1, 0, 0, STATUS_HEIGHT)
	status.BackgroundTransparency = 1
	status.BorderSizePixel = 0
	status.Font = UI.FONT
	status.TextSize = UI.TEXT_SIZE
	status.TextColor3 = hex(Ansi.Colors.fg)
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Text = ""
	status.ZIndex = 12
	status.Parent = root
	self.statusLabel = status

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, UI.PADDING)
	padding.Parent = status

	local ruler = Instance.new("TextLabel")
	ruler.Name = "Ruler"
	ruler.AnchorPoint = Vector2.new(1, 1)
	ruler.Position = UDim2.new(1, -UI.PADDING * 2, 1, 0)
	ruler.Size = UDim2.new(0, 160, 0, STATUS_HEIGHT)
	ruler.BackgroundTransparency = 1
	ruler.Font = UI.FONT
	ruler.TextSize = UI.TEXT_SIZE
	ruler.TextColor3 = hex(Ansi.Colors.fg)
	ruler.TextXAlignment = Enum.TextXAlignment.Right
	ruler.Text = ""
	ruler.ZIndex = 12
	ruler.Parent = root
	self.rulerLabel = ruler

	-- Character-stream capture. Invisible; never holds text for more than an instant.
	local box = Instance.new("TextBox")
	box.Name = "Capture"
	box.Size = UDim2.fromScale(1, 1)
	box.BackgroundTransparency = 1
	box.TextTransparency = 1
	box.Text = ""
	box.MultiLine = true
	box.ClearTextOnFocus = false
	box.ZIndex = 14
	box.Parent = root
	self.box = box

	table.insert(
		self.conns,
		box:GetPropertyChangedSignal("Text"):Connect(function()
			if self.suppress or not self.root then
				return
			end

			local typed = box.Text
			if typed == "" then
				return
			end

			self.suppress = true
			box.Text = ""
			self.suppress = false

			-- Ctrl-chords are commands, not text: don't let Ctrl+R type an "r".
			if self:_ctrlDown() then
				return
			end

			-- The OS goes on sending characters of its own while a character key is
			-- held. Once this key is repeating on our clock those are duplicates, and
			-- feeding both would run the key at two rates at once. Only the character
			-- the held key is actually repeating is dropped: another key pressed
			-- mid-hold is a real keystroke and still lands.
			local held = self.held
			if
				held
				and held.char == typed
				and held.key == self.lastKey
				and UserInputService:IsKeyDown(held.key)
			then
				return
			end

			for index = 1, #typed do
				self:_feed(string.sub(typed, index, index))
			end
			self:_render()

			-- Hold h and it keeps moving; hold x and it keeps deleting. The character is
			-- whatever this key just produced, so shifted keys repeat as themselves
			-- without having to reconstruct them from the KeyCode.
			local key = self.lastKey
			if #typed == 1 and key and UserInputService:IsKeyDown(key) then
				self:_arm(key, function()
					self:_feed(typed)
					self:_render()
				end, typed)
			end
		end)
	)

	table.insert(
		self.conns,
		box.FocusLost:Connect(function()
			if self.root and not self.quitting then
				task.defer(function()
					if self.root and not self.quitting then
						box:CaptureFocus()
					end
				end)
			end
		end)
	)

	table.insert(
		self.conns,
		UserInputService.InputBegan:Connect(function(input)
			self:_onKey(input)
		end)
	)

	table.insert(
		self.conns,
		UserInputService.InputEnded:Connect(function(input)
			if self.held and input.KeyCode == self.held.key then
				self.held = nil
			end
		end)
	)

	-- The repeat clock.
	table.insert(
		self.conns,
		RunService.Heartbeat:Connect(function()
			local held = self.held
			if not held or not self.root then
				return
			end

			-- Alt-tabbing out of the window eats the InputEnded, and a key that is no
			-- longer down must not go on repeating for ever.
			if not UserInputService:IsKeyDown(held.key) then
				self.held = nil
				return
			end

			local now = os.clock()
			if now >= held.due then
				held.due = now + REPEAT_INTERVAL
				held.act()
			end
		end)
	)

	self.resolve = function()
		task.spawn(thread)
	end

	task.defer(function()
		if self.root then
			box:CaptureFocus()
			self:_render()
		end
	end)

	self:_render()
	coroutine.yield()
end

return Vim
