-- Draft Mode for IKEMEN GO v0.0.1
-- by dionednd

draft = {}

function loadDraftAssets(defPath)
	local parsed = loadIni(defPath,true,true)
	motif.draft = main.f_tableMerge(motif.draft or {}, parsed and parsed.draft)
	local cfg = motif.draft

	if cfg.files then
		cfg.Sff = sffNew(cfg.files.sff, false)
		cfg.Snd = sndNew(cfg.files.snd)
		cfg.Air = loadAnimTable(cfg.files.air, cfg.Sff)
		for _, key in ipairs({"banned", "picked"}) do
			cfg.overlay[key].AnimData = animNew(cfg.Sff, cfg.Air[cfg.overlay[key].anim])
		end
		cfg.TextImg = textImgNew()
	end
	motif.draft = cfg
end

loadDraftAssets("external/mods/draftmode/draftmode.def")

draft.gameModes = {
	draftversus = true,
	netplaydraftversus = true,
}

local pending      = false
local draftActive  = false
local phase        = nil
local phase_ = 0
local activeSide    = nil
local banRemaining  = {0, 0}
local pickRemaining = {0, 0}
local bannedRefs    = {}
local pickedRefs    = {}
local lastBanner    = nil
local savedPaletteSelect = nil
local overlayDrawn = false
local original_timer = {
	count = motif.select_info.timer.count,
	framespercount = motif.select_info.timer.framespercount,
	displaytime = motif.select_info.timer.displaytime
}
local original_p1selectsnd = motif.select_info['p' .. 1].select.snd
local original_p2selectsnd = motif.select_info['p' .. 2].select.snd

local winner = {
	persistentBannedRefs = {}
}
local loser = {
	persistentBannedRefs = {}
}

local original_getInput = getInput
getInput = function(cmd, key)
	if draftActive then
		local c = motif.select_info.cell
		if key == c.up.key or key == c.down.key or key == c.left.key or key == c.right.key then
			return false
		end
	end
	return original_getInput(cmd, key)
end

local function otherSide(side)
	if side == 1 then return 2 end
	return 1
end

local function isPickedBlocking(ref)
	if motif.draft.mirrormatch == 1 then
		return false
	end
	return pickedRefs[ref] == true
end

local function buildPool()
	local pool = {}
	for _, ref in ipairs(main.t_randomChars) do
		if not bannedRefs[ref] and not isPickedBlocking(ref) then
			pool[ref] = true
		end
	end
	return pool
end

local function poolList(pool)
	local t = {}
	for ref in pairs(pool) do
		table.insert(t, ref)
	end
	table.sort(t)
	return t
end

local function poolSize(pool)
	local n = 0
	for _ in pairs(pool) do n = n + 1 end
	return n
end

local function firstByCount(remaining)
	if remaining[1] == remaining[2] then
		return math.random(2)
	elseif remaining[1] < remaining[2] then
		return 1
	else
		return 2
	end
end

local function shouldDraft()
	if not draft.gameModes[gameMode()] then
		return false
	end
	return true
end

local function isReservedForSide(side, ref)
	if gameOption('Options.Team.Duplicates') then
		return false
	end
	for _, v in ipairs(start.p[side].t_selected) do
		if v.ref == ref then
			return true
		end
	end
	return false
end

local function isPhaseTurnBased()
	local cfg = motif.draft
	if phase == 'ban' then
		return cfg.banphasedraft ~= 0
	elseif phase == 'pick' then
		return cfg.pickphasedraft ~= 0
	end
	return true
end

local function playDraftSound(key)
	local cfg = motif.draft
	if cfg and cfg.sounds == 1 and cfg.Snd and cfg.sound and cfg.sound[key] then
		sndPlay(cfg.Snd, cfg.sound[key][1], cfg.sound[key][2])
	end
end

local function cellIndex(x, y)
	return y * motif.select_info.columns + x + 1
end

local function isCellDraftBlocked(x, y)
	local i = cellIndex(x, y)
	local gridCell = main.t_selGrid[i]
	if gridCell == nil or #gridCell.chars == 0 then
		return false
	end
	for j = 1, #gridCell.chars do
		local charData = start.f_selGrid(i, j)
		if charData and charData.char ~= nil and charData.hidden ~= 2 then
			if charData.char == 'randomselect' or charData.hidden == 3 then
				return false
			end
			if not bannedRefs[charData.char_ref] and not isPickedBlocking(charData.char_ref) then
				return false
			end
		end
	end
	return true
end

local function mainCellValid(x, y)
	local cell = start.t_grid[y + 1] and start.t_grid[y + 1][x + 1]
	if cell == nil then return false end
	if not (cell.char ~= nil or motif.select_info.moveoveremptyboxes) then return false end
	if cell.skip == 1 then return false end
	if not (cell.char == 'randomselect' or not isCellDraftBlocked(x, y)) then return false end
	if cell.hidden == 2 then return false end
	return true
end

local function emptyBoxCellValid(x, y)
	local cell = start.t_grid[y + 1] and start.t_grid[y + 1][x + 1]
	if cell == nil then return false end
	if cell.skip == 1 then return false end
	if cell.char == nil then return false end
	if not (cell.char == 'randomselect' or not isCellDraftBlocked(x, y)) then return false end
	if cell.hidden == 2 then return false end
	return true
end

local function searchEmptyBoxes(x, y, direction)
	if direction > 0 then
		while true do
			x = x + 1
			if x >= motif.select_info.columns then
				return false, 0
			elseif emptyBoxCellValid(x, y) then
				return true, x
			end
		end
	elseif direction < 0 then
		while true do
			x = x - 1
			if x < 0 then
				return false, motif.select_info.columns - 1
			elseif emptyBoxCellValid(x, y) then
				return true, x
			end
		end
	end
	return false, x
end

local function draftCellMovement(selX, selY, cmd, dir)
	local tmpX, tmpY = selX, selY
	local found = false

	if original_getInput(cmd, motif.select_info.cell.up.key) or dir == 'U' then
		for i = 1, motif.select_info.rows do
			selY = selY - 1
			if selY < 0 then
				if motif.select_info.wrapping or dir ~= nil then
					selY = motif.select_info.rows - 1
				else
					selY = tmpY
				end
			end
			if dir ~= nil then
				found, selX = searchEmptyBoxes(selX, selY, -1)
			elseif mainCellValid(selX, selY) then
				break
			elseif motif.select_info.searchemptyboxesup then
				found, selX = searchEmptyBoxes(selX, selY, 1)
			end
			if found then break end
		end
	elseif original_getInput(cmd, motif.select_info.cell.down.key) or dir == 'D' then
		for i = 1, motif.select_info.rows do
			selY = selY + 1
			if selY >= motif.select_info.rows then
				if motif.select_info.wrapping or dir ~= nil then
					selY = 0
				else
					selY = tmpY
				end
			end
			if dir ~= nil then
				found, selX = searchEmptyBoxes(selX, selY, 1)
			elseif mainCellValid(selX, selY) then
				break
			elseif motif.select_info.searchemptyboxesdown then
				found, selX = searchEmptyBoxes(selX, selY, 1)
			end
			if found then break end
		end
	elseif original_getInput(cmd, motif.select_info.cell.left.key) or dir == 'B' then
		if dir ~= nil then
			found, selX = searchEmptyBoxes(selX, selY, -1)
		else
			for i = 1, motif.select_info.columns do
				selX = selX - 1
				if selX < 0 then
					if motif.select_info.wrapping then
						selX = motif.select_info.columns - 1
					else
						selX = tmpX
					end
				end
				if mainCellValid(selX, selY) then
					break
				end
			end
		end
	elseif original_getInput(cmd, motif.select_info.cell.right.key) or dir == 'F' then
		if dir ~= nil then
			found, selX = searchEmptyBoxes(selX, selY, 1)
		else
			for i = 1, motif.select_info.columns do
				selX = selX + 1
				if selX >= motif.select_info.columns then
					if motif.select_info.wrapping then
						selX = 0
					else
						selX = tmpX
					end
				end
				if mainCellValid(selX, selY) then
					break
				end
			end
		end
	end

	return selX, selY
end

local function scanForAvailable(x, y, dx, dy)
	local rows, cols = motif.select_info.rows, motif.select_info.columns
	local nx, ny = x + dx, y + dy
	while nx >= 0 and nx < cols and ny >= 0 and ny < rows do
		if mainCellValid(nx, ny) then
			return nx, ny
		end
		nx, ny = nx + dx, ny + dy
	end
	return nil, nil
end

local function shouldMoveUp(y, rows)
	if rows <= 1 then
		return math.random(2) == 1
	end
	local pct = y / (rows - 1) * 100
	if pct > 50 then
		return true
	elseif pct < 50 then
		return false
	end
	return math.random(2) == 1
end

local function pickSpawnDirection(x, y, side)
	local rightOk = scanForAvailable(x, y, 1, 0) ~= nil
	local leftOk  = scanForAvailable(x, y, -1, 0) ~= nil
	local upOk    = scanForAvailable(x, y, 0, -1) ~= nil
	local downOk  = scanForAvailable(x, y, 0, 1) ~= nil

	local primaryOk = (side == 1) and rightOk or leftOk
	if primaryOk then
		return (side == 1) and 1 or -1, 0
	end

	if upOk and downOk and not leftOk and not rightOk then
		if shouldMoveUp(y, motif.select_info.rows) then
			return 0, -1
		end
		return 0, 1
	end

	if downOk and not upOk and not leftOk and not rightOk then
		return 0, 1
	end
	if upOk and not leftOk and not rightOk and not downOk then
		return 0, -1
	end

	if (side == 1 and leftOk) or (side == 2 and rightOk) then
		return (side == 1) and -1 or 1, 0
	end
	if downOk then return 0, 1 end
	if upOk then return 0, -1 end

	return nil, nil
end

local function updateSideCursor(side)
	for _, v in ipairs(start.p[side].t_selCmd) do
		local c = start.c[v.player]
		if c then
			local oldX, oldY = c.selX, c.selY
			local newX, newY = draftCellMovement(c.selX, c.selY, v.cmd, v.dir)
			if newX ~= oldX or newY ~= oldY then
				c.selX, c.selY = newX, newY
				local snd = start.f_getCursorData(v.player).cursor.move.snd
				sndPlay(motif.Snd, snd[1], snd[2])
			elseif isCellDraftBlocked(c.selX, c.selY) then
				local dx, dy = pickSpawnDirection(c.selX, c.selY, side)
				if dx ~= nil then
					local fx, fy = scanForAvailable(c.selX, c.selY, dx, dy)
					if fx ~= nil then
						c.selX, c.selY = fx, fy
					end
				end
			end
		end
	end
end

local function updateActiveCursor()
	if isPhaseTurnBased() then
		if activeSide ~= nil then
			updateSideCursor(activeSide)
		end
	else
		updateSideCursor(1)
		updateSideCursor(2)
	end
end

local refToCellPixel = {}

local function buildRefToCellPixel()
	refToCellPixel = {}
	for y = 1, motif.select_info.rows do
		for x = 1, motif.select_info.columns do
			local i = (y - 1) * motif.select_info.columns + x
			local gridCell = main.t_selGrid[i]
			local pixel = start.t_grid[y][x]
			local c = x - 1
			local r = y - 1
			if gridCell and pixel then
				for j = 1, #gridCell.chars do
					local charData = start.f_selGrid(i, j)
					if charData and charData.char_ref ~= nil then
						refToCellPixel[charData.char_ref] = {
							x = motif.select_info.pos[1] + pixel.x,
							y = motif.select_info.pos[2] + pixel.y,
							col = c,
							row = r,
							randomselect = charData.char == 'randomselect'
						}
					end
				end
			end
		end
	end
end

local overlayAnimCache = {}

local function canDrawIcon(col,row,ref)
	local i = cellIndex(col, row)
	local gridCell = main.t_selGrid[i]
	if gridCell then
		for j = 1, #gridCell.chars do
			local charData = start.f_selGrid(i)
			if j == 1 and charData.char_ref == ref then
				return true
			end
		end
	end
	return false
end

local function drawOverlayIcon(key, refs)
	local cfg = motif.draft
	local a = cfg.overlay[key].AnimData

	local layerno = cfg.overlay.layerno or 0
	local localcoord = motif.info.localcoord
	local scale = cfg.overlay.scale or {1, 1}

	local offsetX = (cfg.overlay.offset and cfg.overlay.offset[1]) or 0
	local offsetY = (cfg.overlay.offset and cfg.overlay.offset[2]) or 0
	for ref in pairs(refs) do
		local p = refToCellPixel[ref]
		local canDraw = canDrawIcon(p.col,p.row,ref)
		local params = motif.select_info.cell.bg
		local scale_ = getCellTransform(p.col, p.row, "scale", params.scale)
		if p and canDraw then
			animSetLocalcoord(a, localcoord[1], localcoord[2])
			animSetLayerno(a, layerno)
			animSetPos(a, p.x + offsetX, p.y + offsetY)
			animSetScale(a, scale[1] * scale_[1], scale[2] * scale_[2])
			animSetFacing(a, getCellFacing(params.facing, p.col, p.row))
			animSetXShear(a, getCellTransform(p.col, p.row, "xshear", params.xshear))
			animSetAngle(a, getCellTransform(p.col, p.row, "angle", params.angle))
			animSetXAngle(a, getCellTransform(p.col, p.row, "xangle", params.xangle))
			animSetYAngle(a, getCellTransform(p.col, p.row, "yangle", params.yangle))
			animSetProjection(a, getCellTransform(p.col, p.row, "projection", params.projection))
			animSetFocalLength(a, getCellTransform(p.col, p.row, "focallength", params.focallength))
			animDraw(a)
			animUpdate(a)
		end
	end
end

local function drawOverlays()
	drawOverlayIcon('banned', bannedRefs)
	if motif.draft.mirrormatch ~= 1 then
		drawOverlayIcon('picked', pickedRefs)
	end
end

local function nextActiveSide(remaining, startSide)
	if remaining[1] <= 0 and remaining[2] <= 0 then
		return nil
	end
	if remaining[startSide] > 0 then
		return startSide
	end
	return otherSide(startSide)
end

local function finishDraft()
	draftActive = false
	phase = nil
	activeSide = nil
	motif.select_info['p' .. 1].select.snd = original_p1selectsnd
	motif.select_info['p' .. 2].select.snd = original_p2selectsnd
	if savedPaletteSelect ~= nil then
		motif.select_info.paletteselect = savedPaletteSelect
		savedPaletteSelect = nil
	end
end

local function advance(side)
	local remaining = (phase == 'ban') and banRemaining or pickRemaining
	remaining[side] = remaining[side] - 1
	if phase == 'ban' then
		lastBanner = side
	end

	if isPhaseTurnBased() then
		local nxt = nextActiveSide(remaining, otherSide(side))
		if nxt ~= nil then
			activeSide = nxt
			return
		end
	else
		if remaining[1] > 0 or remaining[2] > 0 then
			return
		end
	end

	if phase == 'ban' then
		if savedPaletteSelect ~= nil then
			motif.select_info.paletteselect = savedPaletteSelect
			savedPaletteSelect = nil
			motif.select_info['p' .. 1].select.snd = original_p1selectsnd
			motif.select_info['p' .. 2].select.snd = original_p2selectsnd
		end
		phase = 'pick'
		if isPhaseTurnBased() then
			activeSide = nextActiveSide(pickRemaining, otherSide(lastBanner))
			if activeSide == nil then
				finishDraft()
			end
		elseif pickRemaining[1] <= 0 and pickRemaining[2] <= 0 then
			finishDraft()
		end
	else
		finishDraft()
	end
end

local function calcBanCount(bans, bancount)
	if bans <= -1 then
		return bancount
	else
		return bans
	end
end

local function beginDraft()
	local size1, size2 = start.p[1].numChars, start.p[2].numChars

	local _picks = (size1 + size2) * (1 - math.max(0, math.min(1, motif.draft.mirrormatch)))
	local _bans = calcBanCount(motif.draft.bancount[1], size2) + calcBanCount(motif.draft.bancount[2], size1)

	if (poolSize(buildPool()) - (_bans + _picks)) < 0 then
		winner.persistentBannedRefs = {}
		loser.persistentBannedRefs = {}
		start.escFlag = true
		return false
	end

	banRemaining  = {calcBanCount(motif.draft.bancount[1], size2),calcBanCount(motif.draft.bancount[2], size1)}
	pickRemaining = {size1, size2}
	lastBanner = nil
	phase = 'ban'
	if banRemaining[1] == 0 and banRemaining[2] == 0 then phase = 'pick' end
	activeSide = firstByCount(pickRemaining)
	if (banRemaining[1] > 0 and banRemaining[2] == 0) or (banRemaining[2] > 0 and banRemaining[1] == 0) then
		activeSide = firstByCount({banRemaining[2],banRemaining[1]})
	end

	if phase == 'ban' then
		savedPaletteSelect = motif.select_info.paletteselect
		motif.select_info.paletteselect = 0
		motif.select_info['p' .. 1].select.snd = motif.draft['p' .. 1].ban.snd
		motif.select_info['p' .. 2].select.snd = motif.draft['p' .. 2].ban.snd
	end

	draftActive = true
	return true
end

local function randomBan(count)
	for i = 1, count do
		local pool = {}
		for _, v in ipairs(main.t_randomChars) do
			if not isReservedForSide(pn, v) and not bannedRefs[v] and not isPickedBlocking(v) then
				table.insert(pool, v)
			end
		end
		if #pool == 0 then
			return nil
		end

		local _ban = pool[math.random(1, #pool)]

		bannedRefs[_ban] = true
		t_reservedChars[1][_ban] = true
		t_reservedChars[2][_ban] = true
	end
end

local function autoBan(ab)
	if type(ab) == "table" then
		for i = 1, #ab do
			if ab[i] >= 0 and ab[i] <= #refToCellPixel and not refToCellPixel[ab[i]].randomselect then
				bannedRefs[ab[i]] = true
				t_reservedChars[1][ab[i]] = true
				t_reservedChars[2][ab[i]] = true
			end
		end
	else
		if ab >= 0 and ab <= #refToCellPixel and not refToCellPixel[ab].randomselect then
			bannedRefs[ab] = true
			t_reservedChars[1][ab] = true
			t_reservedChars[2][ab] = true
		end
	end
end

hook.add("start.f_selectReset", "draftmode.reset", function()
	if not draft.gameModes[gameMode()] then
		winner.persistentBannedRefs = {}
		loser.persistentBannedRefs = {}
		motif.select_info.timer.count = original_timer.count
		motif.select_info.timer.framespercount = original_timer.framespercount
		motif.select_info.timer.displaytime = original_timer.displaytime
		motif.select_info['p' .. 1].select.snd = original_p1selectsnd
		motif.select_info['p' .. 2].select.snd = original_p2selectsnd
	else
		buildRefToCellPixel()
		motif.select_info.timer.count = motif.draft.timer.count
		motif.select_info.timer.framespercount = motif.draft.timer.framespercount
		motif.select_info.timer.displaytime = motif.draft.timer.displaytime
		bannedRefs = {}
		pickedRefs = {}

		if (type(motif.draft.autoban) ~= "table" and motif.draft.autoban >= 0 and motif.draft.autoban <= #refToCellPixel and not refToCellPixel[motif.draft.autoban].randomselect) or type(motif.draft.autoban) == "table" then
			autoBan(motif.draft.autoban)
		end

		if motif.draft.winnerbanselection > 0 then
			for ref in pairs(winner.persistentBannedRefs) do
				bannedRefs[ref] = true
				t_reservedChars[1][ref] = true
				t_reservedChars[2][ref] = true
			end
		end

		if motif.draft.loserbanselection > 0 then
			for ref in pairs(loser.persistentBannedRefs) do
				bannedRefs[ref] = true
				t_reservedChars[1][ref] = true
				t_reservedChars[2][ref] = true
			end
		end

		if motif.draft.randombans >= 1 then
			randomBan(motif.draft.randombans)
		end
	end
	pending = shouldDraft()
	draftActive = false
	overlayDrawn = false
	phase = nil
	phase_ = 0
	activeSide = nil
	if savedPaletteSelect ~= nil then
		motif.select_info.paletteselect = savedPaletteSelect
		savedPaletteSelect = nil
	end
end)

local function drawPhaseText()
	local cfg = motif.draft
	local txt = cfg.TextImg
	if draft.gameModes[gameMode()] then
		textImgSetLocalcoord(txt, motif.info.localcoord[1], motif.info.localcoord[2])
		textImgSetPos(txt,cfg.phase.text.offset[1],cfg.phase.text.offset[2])
		if phase and activeSide then
			textImgSetText(txt,cfg.phase.text[phase])
			textImgSetColor(txt, cfg.phase.text['color' .. activeSide][1],cfg.phase.text['color' .. activeSide][2],cfg.phase.text['color' .. activeSide][3])
		else
			textImgSetText(txt,cfg.phase.text.regular)
			textImgSetColor(txt, cfg.phase.text.regularcolor[1],cfg.phase.text.regularcolor[2],cfg.phase.text.regularcolor[3])
		end
		textImgSetFont(txt, motif.Fnt[cfg.phase.text.font[1]])
		textImgSetBank(txt, cfg.phase.text.font[2])
		textImgSetAlign(txt, cfg.phase.text.font[3])
		textImgSetLayerno(txt, cfg.phase.text.layerno)
		textImgSetScale(txt, cfg.phase.text.scale[1],cfg.phase.text.scale[2])
		textImgDraw(txt)
		textImgUpdate(txt)
	end
end

local function playPhaseSound(key)
	local cfg = motif.draft
	if cfg.announcer == 1 and cfg.announce and cfg.announce[key] then
		sndPlay(cfg.Snd, cfg.announce[key][1], cfg.announce[key][2])
	end
end

local original_playBgm = playBgm
function playBgm(t)
	if draft.gameModes[gameMode()] and t and t.source and t.source == 'motif.select' and motif.draft.bgm.filename ~= -1 then
		return original_playBgm({bgm = motif.draft.bgm.filename, loop = motif.draft.bgm.loop, volume = motif.draft.bgm.volume, loopstart = motif.draft.bgm.loopstart, loopend = motif.draft.bgm.loopend, interrupt = true})
	end
	return original_playBgm(t)
end

hook.add("start.f_selectScreen", "draftmode.tick", function()

	if phase_ ~= phase and draft.gameModes[gameMode()] then
		phase_ = phase
		key = phase_
		if key == nil then key = "regular" end
		playPhaseSound(key)
	end

	if pending and not draftActive and start.p[1].teamEnd and start.p[2].teamEnd then
		pending = false
		beginDraft()
	end

	if ((not start.p[1].teamEnd and not start.p[2].teamEnd) or overlayDrawn == false) and draft.gameModes[gameMode()] then
		if not overlayDrawn then
			overlayDrawn = true
			drawOverlays()
		end
	end

	overlayDrawn = false
	
	drawPhaseText()

	if not draftActive then return end

	updateActiveCursor()

end)

hook.add("start.f_selectMenu.selected", "draftmode.selected", function(side, member, entry, p, player)
	if not draftActive then
		return
	end
	if isPhaseTurnBased() and side ~= activeSide then
		return
	end

	local ref = entry.ref

	if phase == 'ban' then
		table.remove(p.t_selected, member)
		t_reservedChars[1][entry.ref] = true
		t_reservedChars[2][entry.ref] = true
		bannedRefs[ref] = true
		playDraftSound('ban')
	else
		pickedRefs[ref] = true
		if motif.draft.mirrormatch ~= 1 then
			t_reservedChars[1][entry.ref] = true
			t_reservedChars[2][entry.ref] = true
		end
		playDraftSound('pick')
	end

	advance(side)
end)

local original_f_selectMenu = start.f_selectMenu
start.f_selectMenu = function(side, cmd, player, member, selectState)
	if pending and not draftActive then
		return selectState, false
	end
	if draftActive and isPhaseTurnBased() and side ~= activeSide then
		return selectState, false
	end
	return original_f_selectMenu(side, cmd, player, member, selectState)
end

local function isPnOnSide(pn, side)
	for _, v in ipairs(start.p[side].t_selCmd) do
		if v.player == pn then return true end
	end
	return false
end

local original_f_drawCursor = start.f_drawCursor
start.f_drawCursor = function(pn, x, y, param, done_)
	if draft.gameModes[gameMode()] then
		if not overlayDrawn then
			overlayDrawn = true
			drawOverlays()
		end

		local i = cellIndex(x, y)
		local gridCell = main.t_selGrid[i]
		local ref = -1
		if gridCell then
			for j = 1, #gridCell.chars do
				local charData = start.f_selGrid(i, j)
				if j == 1 then
					ref = charData.char_ref
				end
			end
		end

		local suppressInactive = not done_ and draftActive and isPhaseTurnBased() and activeSide ~= nil and isPnOnSide(pn, otherSide(activeSide))
		if suppressInactive or (not draftActive and not done_) or (done_ and not canDrawIcon(x,y,ref)) then
			return
		end
	end
	return original_f_drawCursor(pn, x, y, param, done_)
end

function start.f_randomChar(pn)
	local pool = {}
	for _, v in ipairs(main.t_randomChars) do
		if not isReservedForSide(pn, v) and not bannedRefs[v] and not isPickedBlocking(v) then
			table.insert(pool, v)
		end
	end
	if #pool == 0 then
		return nil
	end
	start.shuffleChars = start.shuffleChars or {}
	if not start.shuffleChars[pn] or #start.shuffleChars[pn] == 0 then
		local last = start.lastRandomChar and start.lastRandomChar[pn]
		start.f_shuffleTable(pool, last)
		start.shuffleChars[pn] = pool
	end
	local result = table.remove(start.shuffleChars[pn])
	start.lastRandomChar = start.lastRandomChar or {}
	start.lastRandomChar[pn] = result
	return result
end

local original_f_getName = start.f_getName
function start.f_getName(ref, side)
	if ref == nil or start.f_getCharData(ref).hidden == 2 or (draft.gameModes[gameMode()] and phase and side ~= activeSide and (phase == 'ban' or (phase == 'pick' and pickRemaining[side] == start.p[side].numChars))) then
		return ''
	end
	if start.f_getCharData(ref).char == 'randomselect' or start.f_getCharData(ref).hidden == 3 then
		return motif.select_info['p' .. (side or 1)].name.random.text
	end
	return start.f_getCharData(ref).name
end

local original_f_drawPortraits = start.f_drawPortraits
function start.f_drawPortraits(t_portraits, side, t, subname, last, iconDone)
	if draft.gameModes[gameMode()] and phase and side ~= activeSide and (phase == 'ban' or (phase == 'pick' and pickRemaining[side] == start.p[side].numChars)) then
		return
	end
	return original_f_drawPortraits(t_portraits, side, t, subname, last, iconDone)
end

local function isSettingEnabled(value)
	if value >= 1 then
		return true
	end
	return false
end

local function roundTimeSet(value)
	if value <= -1 then
		return gameOption('Options.Time')
	end
	return value
end

main.t_itemname.draftversus = function(t, item)
	main.cpuSide[2] = false
	--main.fightscreen.p1wincount = true
	--main.fightscreen.p2wincount = true
	main.motif.vsscreen = true
	main.motif.victoryscreen = true
	main.orderSelect[1] = true
	main.orderSelect[2] = true
	main.selectMenu[2] = true
	main.stageMenu = isSettingEnabled(motif.draft.stageselect)
	main.roundTime = roundTimeSet(motif.draft.roundtime)
	main.teamMenu[1].simul = isSettingEnabled(motif.draft.teammode.simul[1])
	main.teamMenu[1].single = isSettingEnabled(motif.draft.teammode.single[1])
	main.teamMenu[1].tag = isSettingEnabled(motif.draft.teammode.tag[1])
	main.teamMenu[1].turns = isSettingEnabled(motif.draft.teammode.turns[1])
	main.teamMenu[2].simul = isSettingEnabled(motif.draft.teammode.simul[2])
	main.teamMenu[2].single = isSettingEnabled(motif.draft.teammode.single[2])
	main.teamMenu[2].tag = isSettingEnabled(motif.draft.teammode.tag[2])
	main.teamMenu[2].turns = isSettingEnabled(motif.draft.teammode.turns[1])
	textImgSetText(motif.select_info.title.TextSpriteData, motif.draft.title.draftversus)
	setGameMode('draftversus')
	setHomeTeam(1)
	hook.run("main.t_itemname", t, item)
	return start.f_selectMode
end

main.t_itemname.netplaydraftversus = function(t, item)
	main.cpuSide[2] = false
	--main.fightscreen.p1wincount = true
	--main.fightscreen.p2wincount = true
	main.motif.vsscreen = true
	main.motif.victoryscreen = true
	main.orderSelect[1] = true
	main.orderSelect[2] = true
	main.pauseMenu = false
	main.selectMenu[2] = true
	main.stageMenu = isSettingEnabled(motif.draft.stageselect)
	main.roundTime = roundTimeSet(motif.draft.roundtime)
	main.teamMenu[1].simul = isSettingEnabled(motif.draft.teammode.simul[1])
	main.teamMenu[1].single = isSettingEnabled(motif.draft.teammode.single[1])
	main.teamMenu[1].tag = isSettingEnabled(motif.draft.teammode.tag[1])
	main.teamMenu[1].turns = isSettingEnabled(motif.draft.teammode.turns[1])
	main.teamMenu[2].simul = isSettingEnabled(motif.draft.teammode.simul[2])
	main.teamMenu[2].single = isSettingEnabled(motif.draft.teammode.single[2])
	main.teamMenu[2].tag = isSettingEnabled(motif.draft.teammode.tag[2])
	main.teamMenu[2].turns = isSettingEnabled(motif.draft.teammode.turns[1])
	textImgSetText(motif.select_info.title.TextSpriteData, motif.draft.title.netplaydraftversus)
	setGameMode('netplaydraftversus')
	setHomeTeam(1)
	hook.run("main.t_itemname", t, item)
	return start.f_selectMode
end

hook.add("game.victory_init", "draftmode.result", function()
	local cfg = motif.draft
	local wmode = cfg.winnerbanselection
	local lmode = cfg.loserbanselection
	if draft.gameModes[gameMode()] and (wmode > 0 or lmode > 0) then
		if getWinnerTeam() > 0 then
			if wmode > 0 then
				if wmode == 1 then
					winner.persistentBannedRefs = {}
				end
				for _, v in ipairs(start.p[getWinnerTeam()].t_selected) do
					winner.persistentBannedRefs[v.ref] = true
				end
			elseif lmode > 0 then
				if lmode == 1 then
					loser.persistentBannedRefs = {}
				end
				for _, v in ipairs(start.p[otherSide(getWinnerTeam())].t_selected) do
					loser.persistentBannedRefs[v.ref] = true
				end
			end
		end
	end
end)