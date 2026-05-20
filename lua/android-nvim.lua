local window = nil
local OUTPUT_FILETYPE = "android-nvim-output"

local function trim(s)
	return s:gsub("^%s*(.-)%s*$", "%1")
end

local function get_android_sdk()
	local sdk = vim.fn.expand(vim.env.ANDROID_HOME or vim.g.android_sdk or "")
	if sdk == "" then
		return nil
	end
	return sdk
end

local function android_cli_cmd(args)
	local cmd = { "android" }
	local sdk = get_android_sdk()
	if sdk then
		cmd[#cmd + 1] = "--sdk=" .. sdk
	end
	for _, arg in ipairs(args) do
		cmd[#cmd + 1] = arg
	end
	return cmd
end

local function select_modal(items, opts, on_choice)
	vim.validate("items", items, "table")
	vim.validate("on_choice", on_choice, "function")
	opts = opts or {}

	if #items == 0 then
		on_choice(nil, nil)
		return
	end

	local format_item = opts.format_item or tostring
	local title = opts.prompt or "Select one of:"

	local buf = vim.api.nvim_create_buf(false, true)
	local lines = {}
	local max_width = vim.fn.strdisplaywidth(title)
	for _, item in ipairs(items) do
		local line = format_item(item)
		lines[#lines + 1] = line
		max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"

	local width = math.min(
		math.max(max_width + 2, vim.fn.strdisplaywidth(title) + 2),
		math.floor(vim.o.columns * 0.8)
	)
	local height = math.min(#items, math.floor(vim.o.lines * 0.6))
	local border = vim.o.winborder ~= "" and vim.o.winborder or "rounded"

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2) - 1,
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = border,
		title = title,
	})

	vim.wo[win].winfixbuf = true
	vim.wo[win].cursorline = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false

	local done = false
	local function finish(choice, idx)
		if done then
			return
		end
		done = true
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		on_choice(choice, idx)
	end

	local keymap_opts = { buffer = buf, nowait = true, silent = true }

	vim.keymap.set("n", "<CR>", function()
		local idx = vim.api.nvim_win_get_cursor(win)[1]
		finish(items[idx], idx)
	end, keymap_opts)

	local function go_back()
		if done then
			return
		end
		done = true
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		if opts.on_back then
			opts.on_back()
		else
			on_choice(nil, nil)
		end
	end

	vim.keymap.set("n", "<Esc>", go_back, keymap_opts)
	vim.keymap.set("n", "q", go_back, keymap_opts)

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			if not done then
				finish(nil, nil)
			end
		end,
	})
end

local RECENT_PATH = vim.fn.stdpath("data") .. "/android-nvim/recent.json"
local MAX_RECENT = 3

local function load_recent_action_ids()
	local file = io.open(RECENT_PATH, "r")
	if not file then
		return {}
	end
	local content = file:read("*a")
	file:close()

	local ok, decoded = pcall(vim.json.decode, content)
	if not ok or type(decoded) ~= "table" then
		return {}
	end

	local recent = {}
	for _, id in ipairs(decoded) do
		if type(id) == "string" and id ~= "" then
			recent[#recent + 1] = id
		end
	end
	return recent
end

local function record_recent_action(id)
	local recent = load_recent_action_ids()
	local next_recent = { id }
	for _, existing in ipairs(recent) do
		if existing ~= id and #next_recent < MAX_RECENT then
			next_recent[#next_recent + 1] = existing
		end
	end

	vim.fn.mkdir(vim.fn.fnamemodify(RECENT_PATH, ":h"), "p")
	local file = io.open(RECENT_PATH, "w")
	if not file then
		return
	end
	file:write(vim.json.encode(next_recent))
	file:close()
end

local SEARCH_NS = vim.api.nvim_create_namespace("android-nvim-search")

local GROUP_ORDER = {
	"Build & deploy",
	"Emulator",
	"Android Studio",
	"Device",
	"Project",
}

local function actions_for_group(actions, group)
	local grouped = {}
	for _, action in ipairs(actions) do
		if action.group == group then
			grouped[#grouped + 1] = action
		end
	end
	return grouped
end

local function action_matches(action, search_query)
	if search_query == "" then
		return true
	end
	local haystack = (action.label .. " " .. action.group .. " " .. (action.keywords or "")):lower()
	return haystack:find(search_query, 1, true) ~= nil
end

local function run_action(action)
	record_recent_action(action.id)
	action.run()
end

local function ensure_menu_highlights()
	local ok, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
	local bg = ok and normal.bg or "NONE"
	vim.api.nvim_set_hl(0, "AndroidNvimMenuHeader", { fg = "#888899", bg = bg, bold = true })
	vim.api.nvim_set_hl(0, "AndroidNvimMenuRecent", { fg = "#b0b0c0", bg = bg, blend = 25 })
	vim.api.nvim_set_hl(0, "AndroidNvimMenuGroup", { fg = "#d0d0e0", bg = bg })
end

local function show_group_menu(group, actions, show_root)
	local group_actions = actions_for_group(actions, group)
	if #group_actions == 0 then
		vim.notify("No actions in " .. group .. ".", vim.log.levels.WARN, {})
		show_root()
		return
	end

	select_modal(group_actions, {
		prompt = group,
		format_item = function(action)
			return action.label
		end,
		on_back = show_root,
	}, function(choice)
		if choice then
			run_action(choice)
		end
	end)
end

local function select_root_menu(actions)
	ensure_menu_highlights()

	local action_by_id = {}
	for _, action in ipairs(actions) do
		action_by_id[action.id] = action
	end

	local recent_ids = load_recent_action_ids()
	local query = ""
	local selectable = {}
	local row_to_index = {}
	local done = false
	local width = math.min(72, math.floor(vim.o.columns * 0.85))
	local list_start_row = 3

	local function show_root()
		select_root_menu(actions)
	end

	local function build_display(search_query)
		search_query = trim(search_query):lower()
		local separator = string.rep("─", math.max(width - 2, 8))
		local result_lines = { separator }
		local highlights = {}
		local items = {}
		local row_map = {}

		local function buf_row()
			return 1 + #result_lines
		end

		local function add_header(label)
			result_lines[#result_lines + 1] = "  " .. label
			highlights[#highlights + 1] = { buf_row(), "AndroidNvimMenuHeader", 0, -1 }
		end

		local function add_item(text, entry, hl_group)
			result_lines[#result_lines + 1] = "  " .. text
			local row = buf_row()
			items[#items + 1] = entry
			row_map[row] = #items
			if hl_group then
				highlights[#highlights + 1] = { row, hl_group, 0, -1 }
			end
		end

		if search_query ~= "" then
			for _, action in ipairs(actions) do
				if action_matches(action, search_query) then
					add_item(action.group .. "  " .. action.label, {
						kind = "action",
						action = action,
					})
				end
			end
			return result_lines, items, row_map, highlights
		end

		local recent_actions = {}
		for _, id in ipairs(recent_ids) do
			local action = action_by_id[id]
			if action then
				recent_actions[#recent_actions + 1] = action
			end
		end

		if #recent_actions > 0 then
			add_header("Recent")
			for _, action in ipairs(recent_actions) do
				add_item(action.label, {
					kind = "action",
					action = action,
				}, "AndroidNvimMenuRecent")
			end
		end

		add_header("Browse")
		for _, group in ipairs(GROUP_ORDER) do
			if #actions_for_group(actions, group) > 0 then
				add_item(group, {
					kind = "group",
					group = group,
				}, "AndroidNvimMenuGroup")
			end
		end

		return result_lines, items, row_map, highlights
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "android-nvim-actions"

	local border = vim.o.winborder ~= "" and vim.o.winborder or "rounded"

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = 12,
		row = math.floor((vim.o.lines - 12) / 2) - 1,
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = border,
		title = " Android ",
	})

	vim.wo[win].winfixbuf = true
	vim.wo[win].cursorline = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false

	local function close_picker()
		if done then
			return
		end
		done = true
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function choose_entry(index)
		local entry = selectable[index]
		if entry == nil then
			return
		end

		if entry.kind == "group" then
			close_picker()
			show_group_menu(entry.group, actions, show_root)
			return
		end

		run_action(entry.action)
		close_picker()
	end

	local function highlight_search_area(separator, section_highlights)
		vim.api.nvim_buf_clear_namespace(buf, SEARCH_NS, 0, -1)
		vim.api.nvim_buf_add_highlight(buf, SEARCH_NS, "Visual", 0, 0, -1)
		vim.api.nvim_buf_add_highlight(buf, SEARCH_NS, "Comment", 1, 0, #separator)
		for _, hl in ipairs(section_highlights) do
			vim.api.nvim_buf_add_highlight(buf, SEARCH_NS, hl[2], hl[1] - 1, hl[3], hl[4])
		end
	end

	local function first_selectable_row()
		local line_count = vim.api.nvim_buf_line_count(buf)
		for row = list_start_row, line_count do
			if row_to_index[row] then
				return row
			end
		end
		return nil
	end

	local function refresh_results()
		local section_highlights
		local result_lines
		result_lines, selectable, row_to_index, section_highlights = build_display(query)

		if #selectable == 0 then
			result_lines[#result_lines + 1] = "  No matching actions"
		end

		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 1, -1, false, result_lines)
		highlight_search_area(result_lines[1], section_highlights)

		local height = math.min(
			math.max(#result_lines + (list_start_row - 1), 5),
			math.floor(vim.o.lines * 0.6)
		)
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_config(win, { height = height })
		end
	end

	local function sync_query()
		query = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
		refresh_results()
	end

	local function go_to_search()
		vim.api.nvim_win_set_cursor(win, { 1, #query })
		vim.cmd.startinsert()
	end

	local function go_to_first_entry()
		local row = first_selectable_row()
		if row == nil then
			return
		end
		vim.cmd.stopinsert()
		vim.api.nvim_win_set_cursor(win, { row, 0 })
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
	refresh_results()
	vim.api.nvim_win_set_cursor(win, { 1, 0 })

	local keymap_opts = { buffer = buf, nowait = true, silent = true }

	vim.keymap.set("i", "<Esc>", close_picker, keymap_opts)
	vim.keymap.set("n", "<Esc>", close_picker, keymap_opts)
	vim.keymap.set("n", "q", close_picker, keymap_opts)
	vim.keymap.set("i", "<Down>", go_to_first_entry, keymap_opts)

	local function move_cursor(delta)
		local row, col = unpack(vim.api.nvim_win_get_cursor(win))
		local line_count = vim.api.nvim_buf_line_count(buf)
		local target = row + delta
		while target >= list_start_row and target <= line_count do
			if row_to_index[target] then
				vim.api.nvim_win_set_cursor(win, { target, col })
				return
			end
			target = target + delta
		end
	end

	vim.keymap.set("n", "<Up>", function()
		local row = vim.api.nvim_win_get_cursor(win)[1]
		if row <= list_start_row then
			go_to_search()
		else
			move_cursor(-1)
		end
	end, keymap_opts)

	vim.keymap.set("n", "j", function()
		local row = vim.api.nvim_win_get_cursor(win)[1]
		if row < list_start_row then
			go_to_first_entry()
		else
			move_cursor(1)
		end
	end, keymap_opts)

	vim.keymap.set("n", "k", function()
		local row = vim.api.nvim_win_get_cursor(win)[1]
		if row <= list_start_row then
			go_to_search()
		else
			move_cursor(-1)
		end
	end, keymap_opts)

	vim.keymap.set("n", "<CR>", function()
		local row = vim.api.nvim_win_get_cursor(win)[1]
		if row < list_start_row then
			go_to_search()
			return
		end
		local index = row_to_index[row]
		if index then
			choose_entry(index)
		end
	end, keymap_opts)

	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		buffer = buf,
		callback = function()
			if done then
				return
			end
			sync_query()
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			close_picker()
		end,
	})

	vim.cmd.startinsert()
end

local function list_avds()
	local obj = vim.system(android_cli_cmd({ "emulator", "list" }), { text = true }):wait()
	if obj.code ~= 0 then
		return nil, trim(obj.stderr or "Failed to list emulators.")
	end

	local avds = {}
	for line in (obj.stdout or ""):gmatch("[^\r\n]+") do
		line = trim(line)
		if line ~= "" then
			avds[#avds + 1] = line
		end
	end

	return avds
end

local function with_adb(callback)
	local sdk = get_android_sdk()
	if sdk == nil then
		vim.notify("Android SDK is not defined.", vim.log.levels.ERROR, {})
		return
	end
	callback(sdk .. "/platform-tools/adb")
end

local function find_gradlew(directory)
	local cwd = directory
	if cwd == nil then
		cwd = vim.fn.getcwd()
	end
	local parent = vim.fn.fnamemodify(cwd, ":h")

	local obj = vim.system({'find', cwd, "-maxdepth", "1", "-name", "gradlew"}, {}):wait()
	local result = obj.stdout

	if result == nil or #result == 0 then
		if cwd == parent then
			-- we reached root
			return nil
		end

		-- recursive call
		return find_gradlew(parent)
	end

	return { cwd = cwd, gradlew = trim(result) }
end

local function read_file(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local content = file:read("*all")
	file:close()
	return content
end

local function parse_settings_modules(root_dir)
	local content = read_file(root_dir .. "/settings.gradle.kts")
		or read_file(root_dir .. "/settings.gradle")
	if not content then
		return {}
	end

	local modules = {}
	local seen = {}

	local function add_module(name)
		name = name:gsub("^:", "")
		if name ~= "" and not seen[name] then
			seen[name] = true
			modules[#modules + 1] = name
		end
	end

	for match in content:gmatch('include%s*%(?["\']([^"\']+)["\']') do
		add_module(match)
	end
	for match in content:gmatch("include%s+['\"]([^'\"]+)['\"]") do
		add_module(match)
	end

	return modules
end

local function is_application_module(root_dir, module)
	local content = read_file(root_dir .. "/" .. module .. "/build.gradle.kts")
		or read_file(root_dir .. "/" .. module .. "/build.gradle")
	if not content then
		return false
	end

	return content:find("com%.android%.application") ~= nil
		or content:find('"com.android.application"') ~= nil
		or content:find("'com.android.application'") ~= nil
end

local function find_application_modules(root_dir)
	local apps = {}
	for _, module in ipairs(parse_settings_modules(root_dir)) do
		if is_application_module(root_dir, module) then
			apps[#apps + 1] = module
		end
	end

	if #apps == 0 and is_application_module(root_dir, "app") then
		apps[#apps + 1] = "app"
	end

	return apps
end

local function find_application_id(root_dir, module)
	module = module or "app"
	local content = read_file(root_dir .. "/" .. module .. "/build.gradle.kts")
		or read_file(root_dir .. "/" .. module .. "/build.gradle")
	if not content then
		return nil
	end

	for line in content:gmatch("[^\r\n]+") do
		if line:find("applicationId") then
			local app_id = line:match("applicationId%s*%(?%s*[\"']([^\"']+)[\"']")
				or line:match("applicationId%s*=%s*[\"']([^\"']+)[\"']")
				or line:match(".*[\"']([^\"']+)[\"']")
			if app_id then
				return app_id
			end
		end
	end

	return nil
end

local function find_debug_apk(root_dir, module)
	module = module or "app"
	local module_dir = root_dir .. "/" .. module
	local patterns = {
		module_dir .. "/build/outputs/apk/**/debug/*.apk",
		module_dir .. "/build/outputs/apk/debug/*.apk",
	}

	local newest_path = nil
	local newest_time = 0
	for _, pattern in ipairs(patterns) do
		local files = vim.fn.glob(pattern, true, true)
		for _, path in ipairs(files) do
			local mtime = vim.fn.getftime(path)
			if mtime > newest_time then
				newest_time = mtime
				newest_path = path
			end
		end
	end

	return newest_path
end

local function gradle_module_name(module)
	return ":" .. module:gsub("^:", "")
end

local apply_to_window = function(buf, data)
	if window == nil or data == nil then
		return 0, 0
	end

	local result = {}
	for line in data:gmatch("[^\n]+") do
		result[#result + 1] = line
	end

	local buffer_lines = vim.api.nvim_buf_line_count(buf) or 0

	vim.api.nvim_set_option_value("modifiable", true, {buf=buf})
	vim.api.nvim_buf_set_lines(buf, buffer_lines, buffer_lines + #data, false, result)
	vim.api.nvim_set_option_value("modifiable", false, {buf=buf})

	vim.api.nvim_win_set_cursor(window, {buffer_lines + #result, 0})

	return buffer_lines, buffer_lines + #result
end

local function create_task_progress(title)
	local progress = { kind = "progress", source = "android-nvim", title = title }

	local function update(status, percent, message, replace)
		progress.status = status
		progress.percent = percent
		vim.api.nvim_echo({ { message } }, replace, progress)
		vim.cmd.redraw({ bang = true })
	end

	return {
		start = function(message)
			update("running", 0, message, true)
		end,
		tick = function(percent, message)
			update("running", percent, message, false)
		end,
		done = function(success, message)
			update(success and "success" or "failed", 100, message, true)
		end,
	}
end

local function start_progress_timer(progress, message)
	progress.start(message)

	local time_passed = 0
	local base_message = message:gsub("%.%.$", "")
	local timer = vim.uv.new_timer()
	timer:start(
		1000,
		1000,
		vim.schedule_wrap(function()
			time_passed = time_passed + 1
			local percent = math.min(90, time_passed * 5)
			progress.tick(percent, ("%s... %ds"):format(base_message, time_passed))
		end)
	)

	return timer
end

local function create_gradle_system_opts(buf)
	return {
		text = true,
		stdout = vim.schedule_wrap(function(_, data)
			apply_to_window(buf, data)
		end),
		stderr = vim.schedule_wrap(function(_, data)
			local start, finish = apply_to_window(buf, data)
			for line = start, finish do
				vim.api.nvim_buf_add_highlight(buf, -1, "Error", line, 0, -1)
			end
		end),
	}
end

local function create_build_window()
	local previous_win = vim.api.nvim_get_current_win()

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("buflisted", false, { buf = buf })
	vim.bo[buf].filetype = OUTPUT_FILETYPE

	if window ~= nil and vim.api.nvim_win_is_valid(window) then
		vim.api.nvim_win_close(window, true)
	end

	window = vim.api.nvim_open_win(buf, false, {
		split = "below",
		width = vim.o.columns,
		height = 10,
		style = "minimal",
	})

	vim.wo[window].winfixbuf = true
	vim.wo[window].number = false
	vim.wo[window].relativenumber = false
	vim.wo[window].signcolumn = "no"
	vim.wo[window].wrap = true

	if vim.api.nvim_win_is_valid(previous_win) then
		vim.api.nvim_set_current_win(previous_win)
	end

	return buf
end

local function run_cli_with_progress(title, message, args, opts)
	opts = opts or {}
	local progress = create_task_progress(title)
	local timer = start_progress_timer(progress, message)
	local buf = opts.show_output and create_build_window() or nil
	local system_opts = buf and create_gradle_system_opts(buf) or { text = true }
	if opts.env then
		system_opts.env = opts.env
	end

	vim.system(android_cli_cmd(args), system_opts, vim.schedule_wrap(function(obj)
		timer:stop()
		if obj.code == 0 then
			progress.done(true, opts.success or "Done.")
			if opts.on_success then
				opts.on_success(obj)
			end
		else
			progress.done(false, opts.failure or "Failed.")
			vim.notify(trim(obj.stderr or obj.stdout or "Command failed."), vim.log.levels.ERROR, {})
		end
	end))
end

local function build_release()
	local gradlew = find_gradlew()
	if gradlew == nil then
		vim.notify("Build failed: gradlew is not found.", vim.log.levels.ERROR, {})
		return
	end

	local progress = create_task_progress("AndroidBuildRelease")
	local timer = start_progress_timer(progress, "Building release")

	local buf = create_build_window()

	vim.system({ gradlew.gradlew, "assembleRelease" }, create_gradle_system_opts(buf), vim.schedule_wrap(function(obj)
		timer:stop()
		if obj.code == 0 then
			progress.done(true, "Build successful.")
			vim.notify("Build successful.", vim.log.levels.INFO, {})
		else
			progress.done(false, "Build failed.")
			vim.notify("Build failed: " .. (obj.stderr or ""), vim.log.levels.ERROR, {})
		end
	end))
end

local function clean()
	local gradlew = find_gradlew()
	if gradlew == nil then
		vim.notify("Clean failed: gradlew is not found.", vim.log.levels.ERROR, {})
		return
	end

	local progress = create_task_progress("AndroidClean")
	local timer = start_progress_timer(progress, "Cleaning")

	local buf = create_build_window()

	vim.system({ gradlew.gradlew, "clean" }, create_gradle_system_opts(buf), vim.schedule_wrap(function(obj)
		timer:stop()
		if obj.code == 0 then
			progress.done(true, "Clean successful.")
			vim.notify("Clean successful.", vim.log.levels.INFO, {})
		else
			progress.done(false, "Clean failed.")
			vim.notify("Clean failed: " .. (obj.stderr or ""), vim.log.levels.ERROR, {})
		end
	end))
end

local function get_adb_devices(adb)
	local ids = {}
	local obj = vim.system({ adb, "devices" }):wait()
	local read = obj.stdout or ""
	local rows = {}
	for row in string.gmatch(read, "[^\n]+") do
		table.insert(rows, row)
	end

	for i = 2, #rows do
		local items = {}
		for item in string.gmatch(rows[i], "%S+") do
			table.insert(items, item)
		end

		table.insert(ids, items[1])
	end
	return ids
end

local function get_device_names(adb, ids)
	local devices = {}
	for i = 1, #ids do
		local id = ids[i]
		local cmd
		if id:match("^emulator") then
			cmd = { adb, "-s", id, "emu", "avd", "name" }
		else
			cmd = { adb, "-s", id, "shell", "getprop", "ro.product.model" }
		end
		local obj = vim.system(cmd, {}):wait()
		if obj.code == 0 then
			local read = obj.stdout or ""
			local device_name = read:match("^(.-)\n") or read
			table.insert(devices, device_name)
		end
	end
	return devices

end

local function get_running_devices(adb)
	local devices = {}

	local adb_devices = get_adb_devices(adb)
	local device_names = get_device_names(adb, adb_devices)

	for i = 1, #adb_devices do
		table.insert(devices, {
			id = trim(adb_devices[i]),
			name = trim(device_names[i]),
		})
	end

	return devices
end

local function select_running_device(prompt, callback)
	with_adb(function(adb)
		local devices = get_running_devices(adb)
		if #devices == 0 then
			vim.notify("No devices are running.", vim.log.levels.WARN, {})
			return
		end

		select_modal(devices, {
			prompt = prompt,
			format_item = function(device)
				return device.name .. " (" .. device.id .. ")"
			end,
		}, function(choice)
			if choice then
				callback(adb, choice)
			end
		end)
	end)
end

local function find_main_activity(adb, device_id, application_id)
	local obj = vim.system({adb, "-s", device_id, "shell", "cmd", "package", "resolve-activity", "--brief", application_id}, {}):wait()
	if obj.code ~= 0 then
		return nil
	end

	local read = obj.stdout or ""

	local result = nil
	for line in read:gmatch("[^\r\n]+") do
		result = line
	end

	if result == nil then
		return nil
	end
	return trim(result)
end


local function build_and_install(root_dir, gradle, adb, device, module)
	module = module or "app"
	local application_id = find_application_id(root_dir, module)
	if application_id == nil then
		vim.notify("Build failed: could not find applicationId for module " .. module, vim.log.levels.ERROR, {})
		return
	end

	local progress = create_task_progress("AndroidRun")
	local timer = start_progress_timer(progress, "Building " .. module)

	local buf = create_build_window()

	vim.system({ gradle, gradle_module_name(module) .. ":assembleDebug" }, create_gradle_system_opts(buf), vim.schedule_wrap(function(obj)
		timer:stop()
		if obj.code ~= 0 then
			progress.done(false, "Build failed.")
			vim.notify("Build failed.", vim.log.levels.ERROR, {})
			return
		end

		local apk_path = find_debug_apk(root_dir, module)
		if apk_path == nil then
			progress.done(false, "Installation failed: debug APK not found.")
			vim.notify(
				"Installation failed: could not find debug APK for module " .. module,
				vim.log.levels.ERROR,
				{}
			)
			return
		end

		local apk_name = vim.fn.fnamemodify(apk_path, ":t")
		progress.tick(75, "Installing " .. apk_name .. "...")
		local install_obj = vim.system({ adb, "-s", device.id, "install", "-r", apk_path }, {}):wait()
		if install_obj.code ~= 0 then
			progress.done(false, "Installation failed.")
			vim.notify("Installation failed: " .. install_obj.stderr, vim.log.levels.ERROR, {})
			return
		end

		progress.tick(90, "Launching " .. application_id .. "...")
		local main_activity = find_main_activity(adb, device.id, application_id)
		if main_activity == nil then
			progress.done(false, "Launch failed: main activity not found.")
			vim.notify("Failed to launch application, did not find main activity", vim.log.levels.ERROR, {})
			return
		end

		local launch_obj = vim.system({adb, "-s", device.id, "shell", "am", "start", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", "-n", main_activity}, {}):wait()
		if launch_obj.code ~= 0 then
			progress.done(false, "Launch failed.")
			vim.notify("Failed to launch application: " .. launch_obj.stderr, vim.log.levels.ERROR, {})
			return
		end

		local success_message = "Launched " .. application_id .. " from " .. apk_name
		progress.done(true, success_message .. ".")
		vim.notify("Successfully built and launched " .. application_id .. " from " .. apk_name .. "!", vim.log.levels.INFO, {})

		vim.api.nvim_win_close(window, true)
	end))
end

local function build_and_run()
	local gradlew = find_gradlew()
	if gradlew == nil then
		vim.notify("Build failed: gradlew is not found.", vim.log.levels.ERROR, {})
		return
	end

	local android_sdk = vim.fn.expand(vim.fn.expand(vim.env.ANDROID_HOME or vim.g.android_sdk))
	if android_sdk == nil or #android_sdk == 0 then
		vim.notify("Android SDK is not defined.", vim.log.levels.ERROR, {})
		return
	end

	local adb = android_sdk .. "/platform-tools/adb"
	local running_devices = get_running_devices(adb)
	if #running_devices == 0 then
		vim.notify("Build failed: no devices are running.", vim.log.levels.WARN, {})
		return
	end

	local application_modules = find_application_modules(gradlew.cwd)
	if #application_modules == 0 then
		vim.notify("Build failed: no application module found.", vim.log.levels.ERROR, {})
		return
	end

	local function run_on_device(device, module)
		vim.notify(
			"Device selected: " .. device.name .. " | module: " .. module,
			vim.log.levels.INFO,
			{}
		)
		build_and_install(gradlew.cwd, gradlew.gradlew, adb, device, module)
	end

	local function select_device(module)
		select_modal(running_devices, {
			prompt = "Select device to run on",
			format_item = function(item)
				return item.name
			end,
		}, function(choice)
			if choice then
				run_on_device(choice, module)
			else
				vim.notify("Build cancelled.", vim.log.levels.WARN, {})
			end
		end)
	end

	if #application_modules == 1 then
		select_device(application_modules[1])
		return
	end

	select_modal(application_modules, {
		prompt = "Select application module",
		format_item = function(item)
			local app_id = find_application_id(gradlew.cwd, item)
			if app_id then
				return item .. " (" .. app_id .. ")"
			end
			return item
		end,
	}, function(module)
		if module then
			select_device(module)
		else
			vim.notify("Build cancelled.", vim.log.levels.WARN, {})
		end
	end)
end

local function uninstall()
	local gradlew = find_gradlew()
	if gradlew == nil then
		vim.notify("Uninstall failed: gradlew is not found.", vim.log.levels.ERROR, {})
		return
	end

	local application_modules = find_application_modules(gradlew.cwd)
	local application_id = application_modules[1] and find_application_id(gradlew.cwd, application_modules[1])
	if application_id == nil then
		vim.notify("Uninstall failed: could not find application id.", vim.log.levels.ERROR, {})
		return
	end

	local android_sdk = vim.fn.expand(vim.fn.expand(vim.env.ANDROID_HOME or vim.g.android_sdk))
	if android_sdk == nil or #android_sdk == 0 then
		vim.notify("Android SDK is not defined.", vim.log.levels.ERROR, {})
		return
	end

	local adb = android_sdk .. "/platform-tools/adb"
	local running_devices = get_running_devices(adb)
	if #running_devices == 0 then
		vim.notify("Uninstall failed: no devices are running.", vim.log.levels.WARN, {})
		return
	end

	select_modal(running_devices, {
		prompt = "Select device to uninstall from",
		format_item = function(item)
			return item.name
		end,
	}, function(choice)
		if choice then
			local progress = create_task_progress("AndroidUninstall")
			local timer = start_progress_timer(progress, "Uninstalling " .. application_id)
			local uninstall_obj = vim.system({ adb, "-s", choice.id, "uninstall", application_id }, {}):wait()
			timer:stop()
			if uninstall_obj.code == 0 then
				progress.done(true, "Uninstall successful.")
				vim.notify("Uninstall successful.", vim.log.levels.INFO, {})
			else
				progress.done(false, "Uninstall failed.")
				vim.notify("Uninstall failed: " .. uninstall_obj.stderr, vim.log.levels.ERROR, {})
			end
		else
			vim.notify("Uninstall cancelled.", vim.log.levels.WARN, {})
		end
	end)
end

local function launch_avd()
	start_emulator_picker()
end

local function stop_avd()
	with_adb(function(adb)
		local emulators = {}
		for _, device in ipairs(get_running_devices(adb)) do
			if device.id:match("^emulator") then
				emulators[#emulators + 1] = device
			end
		end

		if #emulators == 0 then
			vim.notify("No running emulators found.", vim.log.levels.WARN, {})
			return
		end

		local function stop_device(device)
			run_cli_with_progress("StopAvd", "Stopping " .. device.name, { "emulator", "stop", device.id }, {
				success = "Stopped " .. device.name .. ".",
			})
		end

		if #emulators == 1 then
			stop_device(emulators[1])
			return
		end

		select_modal(emulators, {
			prompt = "Emulator to stop",
			format_item = function(device)
				return device.name .. " (" .. device.id .. ")"
			end,
		}, function(choice)
			if choice then
				stop_device(choice)
			end
		end)
	end)
end

local function open_in_android_studio()
	local file = vim.api.nvim_buf_get_name(0)
	if file == "" or vim.bo[0].buftype ~= "" then
		vim.notify("Open a file buffer first.", vim.log.levels.WARN, {})
		return
	end

	file = vim.fn.fnamemodify(file, ":p")
	local gradlew = find_gradlew()
	local args = { "studio", "open-file", file }
	if gradlew then
		args[#args + 1] = "--project=" .. gradlew.cwd
	end

	run_cli_with_progress("AndroidStudio", "Opening in Android Studio", args, {
		success = "Opened in Android Studio.",
	})
end

local function studio_check()
	run_cli_with_progress("AndroidStudio", "Checking Android Studio", { "studio", "check" }, {
		show_output = true,
		success = "Studio check complete.",
	})
end

local function capture_screen()
	select_running_device("Select device for screenshot", function(_, device)
		local output = vim.fn.tempname() .. ".png"
		run_cli_with_progress("AndroidScreen", "Capturing screen", {
			"screen",
			"capture",
			"-o=" .. output,
		}, {
			env = { ANDROID_SERIAL = device.id },
			success = "Screenshot saved.",
			on_success = function()
				vim.notify("Screenshot: " .. output, vim.log.levels.INFO, {})
			end,
		})
	end)
end

local function dump_layout()
	select_running_device("Select device for layout dump", function(_, device)
		run_cli_with_progress("AndroidLayout", "Dumping layout", {
			"layout",
			"--device=" .. device.id,
			"-p",
		}, {
			show_output = true,
			success = "Layout dump complete.",
		})
	end)
end

local function describe_project()
	local gradlew = find_gradlew()
	if gradlew == nil then
		vim.notify("gradlew is not found.", vim.log.levels.ERROR, {})
		return
	end

	run_cli_with_progress("AndroidDescribe", "Describing project", {
		"describe",
		"--project_dir=" .. gradlew.cwd,
	}, {
		show_output = true,
		success = "Project describe complete.",
	})
end

local function show_android_info()
	run_cli_with_progress("AndroidInfo", "Fetching Android info", { "info" }, {
		show_output = true,
		success = "Environment info loaded.",
	})
end

local function android_run_cli()
	select_running_device("Select device to run on", function(_, device)
		run_cli_with_progress("AndroidRun", "Running app", {
			"run",
			"--debug",
			"--device=" .. device.id,
		}, {
			show_output = true,
			success = "App deployed.",
		})
	end)
end

local function start_emulator_picker()
	local avds, err = list_avds()
	if avds == nil then
		vim.notify(err, vim.log.levels.ERROR, {})
		return
	end
	if #avds == 0 then
		vim.notify("No emulators found.", vim.log.levels.WARN, {})
		return
	end

	select_modal(avds, {
		prompt = "AVD to start",
	}, function(choice)
		if choice then
			run_cli_with_progress("LaunchAvd", "Launching " .. choice, { "emulator", "start", choice }, {
				success = "Launched " .. choice .. ".",
			})
		end
	end)
end

local function get_actions()
	return {
		{
			id = "run_debug",
			label = "Run debug app",
			group = "Build & deploy",
			keywords = "run debug gradle install launch adb",
			run = build_and_run,
		},
		{
			id = "run_cli",
			label = "Run with android CLI",
			group = "Build & deploy",
			keywords = "run deploy android cli debug",
			run = android_run_cli,
		},
		{
			id = "build_release",
			label = "Build release",
			group = "Build & deploy",
			keywords = "build release gradle assemble",
			run = build_release,
		},
		{
			id = "clean",
			label = "Clean project",
			group = "Build & deploy",
			keywords = "clean gradle build",
			run = clean,
		},
		{
			id = "refresh_dependencies",
			label = "Refresh dependencies",
			group = "Build & deploy",
			keywords = "refresh dependencies gradle cache",
			run = refresh_dependencies,
		},
		{
			id = "uninstall",
			label = "Uninstall app",
			group = "Build & deploy",
			keywords = "uninstall remove adb app",
			run = uninstall,
		},
		{
			id = "start_emulator",
			label = "Start emulator",
			group = "Emulator",
			keywords = "emulator avd start launch",
			run = start_emulator_picker,
		},
		{
			id = "stop_emulator",
			label = "Stop emulator",
			group = "Emulator",
			keywords = "emulator avd stop",
			run = stop_avd,
		},
		{
			id = "open_studio_file",
			label = "Open current file in Android Studio",
			group = "Android Studio",
			keywords = "studio open file ide",
			run = open_in_android_studio,
		},
		{
			id = "studio_check",
			label = "Check Studio status",
			group = "Android Studio",
			keywords = "studio check status ide",
			run = studio_check,
		},
		{
			id = "capture_screen",
			label = "Capture screen",
			group = "Device",
			keywords = "screen screenshot capture device",
			run = capture_screen,
		},
		{
			id = "dump_layout",
			label = "Dump layout tree",
			group = "Device",
			keywords = "layout ui dump hierarchy device",
			run = dump_layout,
		},
		{
			id = "describe_project",
			label = "Describe project",
			group = "Project",
			keywords = "describe project metadata gradle",
			run = describe_project,
		},
		{
			id = "show_info",
			label = "Show environment info",
			group = "Project",
			keywords = "info sdk environment android",
			run = show_android_info,
		},
	}
end

local function show_android_menu()
	select_root_menu(get_actions())
end

local function refresh_dependencies()
	local gradlew = find_gradlew()
	if gradlew == nil then
		vim.notify("Refreshing dependencies failed, not able to find gradlew", vim.log.levels.ERROR, {})
		return
	end

	local progress = create_task_progress("AndroidRefreshDependencies")
	local timer = start_progress_timer(progress, "Refreshing dependencies")

	local buf = create_build_window()

	vim.system({ gradlew.gradlew, "--refresh-dependencies" }, create_gradle_system_opts(buf), vim.schedule_wrap(function(obj)
		timer:stop()
		if obj.code ~= 0 then
			progress.done(false, "Refreshing dependencies failed.")
			vim.notify("Refreshing dependencies failed: " .. (obj.stderr or ""), vim.log.levels.ERROR, {})
			return
		end
		progress.done(true, "Refreshing dependencies successful.")
		vim.notify("Refreshing dependencies sucessfully", vim.log.levels.INFO, {})
	end))
end

local function setup()
	vim.api.nvim_create_user_command("Android", function()
		show_android_menu()
	end, { desc = "Open Android action menu" })

	vim.api.nvim_create_user_command("AndroidBuildRelease", function()
		build_release()
	end, {})

	vim.api.nvim_create_user_command("AndroidRun", function()
		build_and_run()
	end, {})

	vim.api.nvim_create_user_command("AndroidUninstall", function()
		uninstall()
	end, {})

	vim.api.nvim_create_user_command("AndroidClean", function()
		clean()
	end, {})

	vim.api.nvim_create_user_command("AndroidRefreshDependencies", function()
		refresh_dependencies()
	end, {})

	vim.api.nvim_create_user_command("LaunchAvd", function()
		launch_avd()
	end, {})
end

return {
	setup = setup,
	show_menu = show_android_menu,
	build_release = build_release,
	build_and_run = build_and_run,
	refresh_dependencies = refresh_dependencies,
	launch_avd = launch_avd,
	clean = clean,
	uninstall = uninstall
}
