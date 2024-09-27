local function trim(s)
	return s:gsub("^%s*(.-)%s*$", "%1")
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

local function build_release()
	local gradlew = find_gradlew().gradlew
	if gradlew == nil then
		vim.notify("Build failed: gradlew is not found.", vim.log.levels.ERROR, {})
		return
	end

	vim.notify("Building release...", vim.log.levels.INFO, {})

	local time_passed = 0
	local timer = vim.uv.new_timer()
	timer:start(
		1000,
		1000,
		vim.schedule_wrap(function()
			time_passed = time_passed + 1
			vim.notify("Building release for " .. time_passed .. " seconds.", vim.log.levels.INFO, {})
		end)
	)

	vim.system(
		{ gradlew, "assembleRelease" },
		{ text = true },
		vim.schedule_wrap(function(obj)
			timer:stop()
			if obj.code == 0 then
				vim.notify("Build successful.", vim.log.levels.INFO, {})
			else
				vim.notify("Build failed: " .. obj.stderr, vim.log.levels.ERROR, {})
			end
		end)
	)
end

local function clean()
	local gradlew = find_gradlew()
	if gradlew == nil then
		vim.notify("Build failed: gradlew is not found.", vim.log.levels.ERROR, {})
		return
	end

	vim.system(
		{ gradlew.gradlew, "clean" },
		{ text = true },
		vim.schedule_wrap(function(obj)
			if obj.code == 0 then
				vim.notify("Clean successful.", vim.log.levels.INFO, {})
			else
				vim.notify("Clean failed.", vim.log.levels.ERROR, {})
			end
		end)
	)
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
		local obj = vim.system({adb, "-s", id, "emu", "avd", "name"}, {}):wait()
		if obj.code == 0 then
			local read = obj.stdout or ""
			local device_name = read:match('^(.-)\n') or read
			table.insert(devices, device_name)
		end
	end
	return devices
end

local function get_running_devices(adb)
	local devices = {}

	local adb_devices = get_adb_devices(adb)
	local device_names = get_device_names(adb, adb_devices)

	print(#adb_devices)
	print(#device_names)
	for i = 1, #adb_devices do
		table.insert(devices, {
			id = trim(adb_devices[i]),
			name = trim(device_names[i]),
		})
	end

	return devices
end

local function find_application_id(root_dir)
	local file_path = root_dir .. "/app/build.gradle"
	local file_path_kt = root_dir .. "/app/build.gradle.kts"

	local file = io.open(file_path, "r")
	if not file then
		file = io.open(file_path_kt, "r")
		if not file then
			return nil
		end
	end

	local content = file:read("*all")
	file:close()

	for line in content:gmatch("[^\r\n]+") do
		if line:find("applicationId") then
			local app_id = line:match(".*[\"']([^\"']+)[\"']")
			return app_id
		end
	end

	return nil
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

local function build_and_install(root_dir, gradle, adb, device)
	local time_passed = 0
	local timer = vim.uv.new_timer()
	timer:start(
		1000,
		1000,
		vim.schedule_wrap(function()
			time_passed = time_passed + 1
			vim.notify("Building for " .. time_passed .. " seconds.", vim.log.levels.DEBUG, {})
		end)
	)

	vim.system({ gradle, "assembleDebug" }, { text = true }, vim.schedule_wrap(function(obj)
		timer:stop()
		if obj.code ~= 0 then
			vim.notify("Build failed.", vim.log.levels.ERROR, {})
			return
		end

		-- Installing
		vim.notify("Installing...", vim.log.levels.INFO, {})
		local install_obj = vim.system({adb, '-s', device.id, "install", root_dir .. "/app/build/outputs/apk/debug/app-debug.apk"}, {}):wait()
		if install_obj.code ~= 0 then
			vim.notify("Installation failed: " .. install_obj.stderr, vim.log.levels.ERROR, {})
			return
		end

		-- Launch the app
		vim.notify("Launching...", vim.log.levels.INFO, {})
		local application_id = find_application_id(root_dir)
		if application_id == nil then
			vim.notify("Failed to launch application, did not find application id", vim.log.levels.ERROR, {})
			return
		end

		local main_activity = find_main_activity(adb, device.id, application_id)
		if main_activity == nil then
			vim.notify("Failed to launch application, did not find main activity", vim.log.levels.ERROR, {})
			return
		end

		local launch_obj = vim.system({adb, "-s", device.id, "shell", "am", "start", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", "-n", main_activity}, {}):wait()
		if launch_obj.code ~= 0 then
			vim.notify("Failed to launch application: " .. launch_obj.stderr, vim.log.levels.ERROR, {})
			return
		end

		vim.notify("Successfully built and launched the application!", vim.log.levels.INFO, {})
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

	print(running_devices[1].name)
	vim.ui.select(running_devices, {
		prompt = "Select device to run on",
		format_item = function(item)
			return item.name
		end,
	}, function(choice)
		if choice then
			vim.notify("Device selected: " .. choice.name, vim.log.levels.INFO, {})
			build_and_install(gradlew.cwd, gradlew.gradlew, adb, choice)
		else
			vim.notify("Build cancelled.", vim.log.levels.WARN, {})
		end
	end)
end

local function launch_avd()
	local android_sdk = vim.fn.expand(vim.fn.expand(vim.env.ANDROID_HOME or vim.g.android_sdk))
	local emulator = android_sdk .. "/emulator/emulator"

	local avds_obj = vim.system({ emulator, "-list-avds" }, {}):wait()
	if avds_obj.code ~= 0 then
		vim.notify("Cannot read emulators", vim.log.levels.WARN, {})
		return
	end

	local read = avds_obj.stdout or ""
	local avds = {}
	for line in read:gmatch("[^\r\n]+") do
		table.insert(avds, line)
	end
	table.remove(avds, 1)

	vim.ui.select(avds, {
		prompt = "AVD to start",
	}, function(choice)
		if choice then
			vim.notify("Device selected: " .. choice .. ". Launching!", vim.log.levels.INFO, {})
			vim.system({ emulator, "@" .. choice }, { text = true }, vim.schedule_wrap(function(obj)
				if obj.code ~= 0 then
					vim.notify("Launch failed: " .. obj.stderr, vim.log.levels.WARN, {})
				end
			end))
		else
			vim.notify("Launch cancelled.", vim.log.levels.WARN, {})
		end
	end)
end

local function setup()
	vim.api.nvim_create_user_command("AndroidBuildRelease", function()
		build_release()
	end, {})

	vim.api.nvim_create_user_command("AndroidRun", function()
		build_and_run()
	end, {})

	vim.api.nvim_create_user_command("AndroidClean", function()
		clean()
	end, {})

	vim.api.nvim_create_user_command("LaunchAvd", function()
		launch_avd()
	end, {})
end

return {
	setup = setup,
	build_release = build_release,
	build_and_run = build_and_run,
	launch_avd = launch_avd,
	clean = clean,
}
