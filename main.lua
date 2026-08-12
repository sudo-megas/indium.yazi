--- @since 26.5.6

--- INDIUM as yazi's archive previewer.
---
--- yazi ships a built-in `archive` previewer that shells out to `7zz` or `7z` and shows a name
--- and a size. This one runs `indium`, which reads the container in-process and states the mode,
--- the size, the packed size, the method, whether the member is encrypted, its timestamp and its
--- path, with a total underneath. On a machine with no 7-zip installed the built-in previewer
--- cannot list anything at all; this one can.
---
--- Nothing here parses INDIUM's output. `indium list --long` is documented as a listing for a
--- person to read rather than for a script to parse, and a preview pane is a person reading, so
--- its lines are printed as they arrive. The only thing this plugin decides is which of the two
--- listings to ask for, and it decides that from the width of the pane and nothing else.

local M = {}

--- `indium list --long` spends 79 columns on the fields before the member's path, and the path is
--- the *last* column — so a narrow pane truncates away the one field a listing exists for. Below
--- this width the plain `indium list` is asked for instead: paths only, undecorated, and legible
--- in a pane of any size.
---
--- **79 is the usual case rather than a constant.** Those columns are minimum widths and none of
--- them truncates, so an unusually long value pushes everything after it to the right: a cpio's
--- method reads `svr4 with no crc` and takes the prefix to 87. There is no width that fits every
--- archive, which is why what follows is a budget and not an arithmetic.
---
--- 96 is 79 plus a 17-character budget for the path — a judgement rather than a measurement, since
--- 80 would technically fit a one-character name and fit nothing else. It is the first number to
--- revisit once this has been pointed at real archives.
local LONG_MIN_WIDTH = 96

--- Starts `indium` in a session of its own.
---
--- **The `setsid` is load-bearing, and denying stdin is not enough on its own.** INDIUM asks for a
--- password on `/dev/tty` deliberately — neither stdin nor stdout, so that a prompt can never land
--- inside a pipeline or inside an extracted file. A child of yazi inherits yazi's controlling
--- terminal, so an archive with an encrypted header would *find* that terminal and sit there
--- asking: the pane hangs, and the keystrokes meant for yazi are swallowed by a prompt nobody can
--- see. A new session leaves no controlling terminal to find, and INDIUM's own documentation names
--- exactly this case — a `setsid` child "gets a sentence and an exit code rather than a process
--- that waits forever for a keystroke nobody is there to type". That sentence is what the pane
--- should show, so this is the supported route rather than a trick.
---@param args string[]
---@return Child?
local function spawn(args)
	local child = Command("setsid")
		:arg({ "indium", table.unpack(args) })
		:stdin(Command.NULL)
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()

	if child then
		return child
	end

	-- No `setsid` here. Preview anyway rather than refusing every archive over a case that only
	-- an encrypted header reaches: everything else behaves identically, and that one can still
	-- find the terminal. `setsid` is util-linux, so this fallback should be close to unreachable.
	return Command("indium")
		:arg(args)
		:stdin(Command.NULL)
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()
end

--- Runs `indium list` and returns its stdout as lines.
---
--- Reading stops as soon as `want` lines are in hand, so previewing the first screenful of an
--- archive with a hundred thousand members costs a screenful. The child is killed either way.
---
--- INDIUM writes its refusals to stderr and exits non-zero with an empty stdout — an unsupported
--- format, an archive whose header is encrypted, a file that is not an archive at all. Those
--- sentences are the useful thing to show, so they are handed back verbatim rather than replaced
--- with a sentence of the plugin's own.
---@param path string
---@param long boolean
---@param want integer
---@return string[]? lines
---@return Error? err
local function run(path, long, want)
	local args = { "list" }
	if long then
		args[#args + 1] = "--long"
	end
	args[#args + 1] = path

	local child = spawn(args)
	if not child then
		return nil, Err("Failed to start `indium`. Is INDIUM installed and on your PATH?")
	end

	-- A refusal is a line or two, so a handful is plenty, and the bound is what stops a program
	-- that talks endlessly on stderr without ever writing to stdout from spinning here forever.
	local out, errs, seen = {}, {}, 0
	while #out < want and seen < want + 64 do
		local next, event = child:read_line()
		seen = seen + 1
		if event == 0 then
			out[#out + 1] = next:gsub("\r?\n$", "")
		elseif event == 1 then
			if #errs < 8 then
				errs[#errs + 1] = next:gsub("\r?\n$", "")
			end
		else
			break
		end
	end
	child:start_kill()

	if #out == 0 and #errs > 0 then
		return nil, Err("%s", table.concat(errs, " "))
	end
	return out, nil
end

function M:peek(job)
	local limit = job.area.h
	local long = job.area.w >= LONG_MIN_WIDTH

	local lines, err = run(tostring(job.file.path), long, job.skip + limit)
	if err then
		return ya.preview_widget(job, err)
	elseif job.skip > 0 and #lines < job.skip + limit then
		-- Scrolled past the end: come back at the true bottom rather than showing a blank pane.
		return ya.emit("peek", {
			math.max(0, #lines - limit),
			only_if = job.file.url,
			upper_bound = true,
		})
	end

	local rows = {}
	for i = job.skip + 1, #lines do
		-- One line of output has to render as exactly one row, or `skip` stops counting what it
		-- says it counts and scrolling drifts. So lines are clipped, never wrapped.
		if long then
			-- The fields lead and the path trails, so clipping the right loses the tail of a long
			-- path rather than every field describing it.
			rows[#rows + 1] = ui.Line(ui.truncate(lines[i], { max = job.area.w }))
		else
			-- Here a line is only a path, and a path's useful half is its end, so this clips left.
			rows[#rows + 1] = ui.Line(ui.truncate(lines[i], { max = job.area.w, rtl = true }))
		end
	end

	if #rows == 0 and job.skip == 0 then
		rows[1] = ui.Line("(no entries)")
	end

	ya.preview_widget(job, ui.Text(rows):area(job.area))
end

function M:seek(job)
	local h = cx.active.current.hovered
	if not h or h.url ~= job.file.url then
		return
	end

	local step = math.floor(job.units * job.area.h / 10)
	step = step == 0 and ya.clamp(-1, job.units, 1) or step

	ya.emit("peek", {
		math.max(0, cx.active.preview.skip + step),
		only_if = job.file.url,
	})
end

return M
