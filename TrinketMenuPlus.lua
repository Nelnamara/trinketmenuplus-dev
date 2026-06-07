--[[--------------------------------------------------------------------------
  TrinketMenuPlus.lua  v0.3  --  Configurable spell/macro boxes for TrinketMenu
  ---------------------------------------------------------------------------
  ARCHITECTURE NOTES (v0.3 rewrite)
    * Box buttons use ONLY SecureActionButtonTemplate.  ActionButtonTemplate
      has its own OnClick → ActionButton_OnClick which overrides type="macro";
      removing it fixes "clicks do nothing."
    * SecureButton Show/Hide → SetAlpha(0/1) + off-screen SetPoint.
    * Cooldown SetCooldown wrapped in anonymous-function pcall so secret
      startTime/duration fields are never touched outside the closure.
    * isActive (bool, not secret) used for cooldown readiness.
    * Spellbook popup enumerates known, castable, non-passive player spells
      via C_SpellBook — mirrors TrinketMenu's trinket-bag menu concept.
    * Config panel: size, scale, color, backdrop, aim-assist feet offset.

  SLASH:  /tmp
    /tmp a|b spell  "SpellName"    set box A or B to a spell (@cursor mode)
    /tmp a|b item   "ItemName"     set box to an item
    /tmp a|b macro  "/cast ..."    set box to raw macrotext
    /tmp a|b mode   cursor|player|target|macro
    /tmp a|b clear                 clear box
    /tmp dock       left|right|top|bottom
    /tmp config                    open config panel
    /tmp lock | unlock
    /tmp status
----------------------------------------------------------------------------]]

TrinketMenuPlus = {}
local TMP    = TrinketMenuPlus
local ADDON  = "TrinketMenuPlus"

-- forward declares
local boxFrames, aimFrames, mainFrame = {}, {}, nil
local cfgPanel, sbPopup = nil, nil   -- config + spellbook popup frames
local throttle, btnVisible = 0, {false, false}

----------------------------------------------------------------------
-- Default / load DB
----------------------------------------------------------------------
local function defaultBox()
  return { spellName="", spellID=0, macroText="", mode="cursor", label="" }
end

local DB = {  -- merged with TrinketMenuPlusDB at login
  boxes   = { defaultBox(), defaultBox() },
  dock    = "right",
  locked  = false,
  boxSize = 36,
  scale   = 1.0,
  glowR=0.1, glowG=0.8, glowB=0.2,
  feetOffset = 140,
  -- LibDBIcon uses this table to persist minimap position/visibility.
  -- Stored as a sub-table of TrinketMenuPlusDB so it survives reloads.
  minimapIcon = { hide = false, minimapPos = 45 },
}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function clr(r,g,b) return {r=r or 0, g=g or 0, b=b or 0} end

local function spellIcon(cfg)
  if cfg.spellID > 0 and C_Spell and C_Spell.GetSpellTexture then
    local t = C_Spell.GetSpellTexture(cfg.spellID)
    if t then return t end
  end
  return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function macroText(cfg)
  if cfg.mode == "macro" and cfg.macroText ~= "" then return cfg.macroText end
  if cfg.spellName == "" then return "" end
  local u = cfg.mode=="player" and "@player" or cfg.mode=="target" and "@target" or "@cursor"
  return string.format("/cast [%s] %s", u, cfg.spellName)
end

local function isReady(cfg)
  if not (cfg.spellID and cfg.spellID > 0) then return true end
  local i = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(cfg.spellID)
  if i then return i.isEnabled ~= false and not i.isActive end
  return true
end

local function isChan() return UnitChannelInfo and UnitChannelInfo("player") ~= nil end
local function hasEnemy()
  return UnitExists("target") and UnitCanAttack("player","target") and not UnitIsDead("target")
end

----------------------------------------------------------------------
-- Apply left/right secure attributes to an aim frame (call only outside combat).
-- mt  = @cursor cast (left-click)
-- mt2 = @player cast (right-click) — aim frames only; box buttons set their own
--       attributes directly in refreshBox so right-click = @target quick-cast.
----------------------------------------------------------------------
local function applySecureAttr(btn, mt, mt2)
  if InCombatLockdown() then return end
  btn:SetAttribute("type", "macro")
  btn:SetAttribute("macrotext",  mt  ~= "" and mt  or "/script print('[TMP] No spell configured')")
  if mt2 and mt2 ~= "" then
    btn:SetAttribute("type2",      "macro")
    btn:SetAttribute("macrotext2", mt2)
  else
    -- Clear any stale right-click binding so right-click has no action.
    btn:SetAttribute("type2",      nil)
    btn:SetAttribute("macrotext2", nil)
  end
end

----------------------------------------------------------------------
-- Update box icon + label + attributes from DB
----------------------------------------------------------------------
local function refreshBox(idx)
  local btn = boxFrames[idx]
  local cfg = DB.boxes[idx]
  if not btn or not cfg then return end

  btn.icon:SetTexture(spellIcon(cfg))
  local lbl = cfg.label ~= "" and cfg.label or
              (cfg.spellName ~= "" and cfg.spellName:sub(1,6) or (cfg.mode=="macro" and "MACRO" or "?"))
  btn.lbl:SetText(lbl)

  if not InCombatLockdown() then
    -- Left-click: cast per configured mode (@cursor/@player/@target/macro)
    local mt = macroText(cfg)
    btn:SetAttribute("type",     "macro")
    btn:SetAttribute("macrotext", mt ~= "" and mt or "/script print('[TMP] No spell configured')")

    -- Right-click: @target quick-cast (instant, no aim required).
    -- MUST always be set to a non-nil value so right-click never falls back to
    -- "type" and fires the left-click spell.  Empty string = harmless no-op macro
    -- when no spell is configured or box is in raw-macro mode.
    local mt2 = (cfg.spellName ~= "" and cfg.mode ~= "macro")
                and ("/cast [@target] "..cfg.spellName) or ""
    btn:SetAttribute("type2",      "macro")
    btn:SetAttribute("macrotext2", mt2)

    -- Ctrl+Right-click: empty no-op in the secure layer so PostClick can open
    -- the spellbook picker without also firing a spell cast.
    btn:SetAttribute("ctrl-type2",      "macro")
    btn:SetAttribute("ctrl-macrotext2", "")
  end

  -- Refresh aim button attributes (aim uses @cursor left / @player right)
  local aim = aimFrames[idx]
  if aim and cfg.spellName ~= "" then
    applySecureAttr(aim,
      "/cast [@cursor] "..cfg.spellName,
      "/cast [@player] "..cfg.spellName)
  end
end

----------------------------------------------------------------------
-- Aim-assist frame: tracks target's feet on screen
-- SecureButton never hidden/shown — uses alpha + off-screen instead
----------------------------------------------------------------------
local OFFX, OFFY = -10000, -10000

local function buildAimFrame(idx)
  if aimFrames[idx] then return aimFrames[idx] end
  local cfg = DB.boxes[idx]

  -- Mover: plain non-secure frame used for the visual ring position proxy.
  -- In Midnight (12.0.5), any frame referenced in a SecureActionButtonTemplate's
  -- anchor chain becomes implicitly protected — ClearAllPoints on it triggers
  -- ADDON_ACTION_BLOCKED even though the frame itself is not secure.
  -- Fix: never anchor f TO mover.  Instead, f is anchored to UIParent with
  -- absolute pixel coords derived from mover:GetCenter() each OnUpdate tick,
  -- but only when not in combat.  During combat f stays at its last pre-combat
  -- position; the visual ring on mover still tracks the target freely.
  local mover = CreateFrame("Frame", ADDON.."AimMover"..idx, UIParent)
  mover:SetSize(90, 90)
  mover:SetPoint("CENTER", UIParent, "CENTER", OFFX, OFFY)

  local f = CreateFrame("Button", ADDON.."Aim"..idx, UIParent, "SecureActionButtonTemplate")
  f:SetSize(90, 90)
  f:SetFrameStrata("HIGH")
  f:RegisterForClicks("LeftButtonUp","RightButtonUp")
  f:SetAlpha(0)
  f:SetPoint("CENTER", UIParent, "CENTER", OFFX, OFFY)  -- independent; synced via GetCenter() in OnUpdate
  -- DO NOT anchor f to mover — doing so makes mover implicitly protected in Midnight
  f.mover = mover

  if cfg.spellName ~= "" then
    applySecureAttr(f,
      "/cast [@cursor] "..cfg.spellName,
      "/cast [@player] "..cfg.spellName)
  end

  local icon = f:CreateTexture(nil,"ARTWORK"); icon:SetAllPoints()
  icon:SetTexCoord(0.07,0.93,0.07,0.93); icon:SetAlpha(0.85); f.icon = icon

  -- Glow ring (non-secure — can Show/Hide freely)
  local ring = CreateFrame("Frame",nil,UIParent)
  ring:SetSize(118,118); ring:SetFrameStrata("MEDIUM")
  ring:SetPoint("CENTER",mover,"CENTER")   -- anchor to mover, not secure button
  local bg = ring:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints()
  bg:SetColorTexture(DB.glowR, DB.glowG, DB.glowB, 0.5); f.glowBg = bg
  local bi = ring:CreateTexture(nil,"BORDER")
  bi:SetPoint("CENTER"); bi:SetSize(98,98)
  bi:SetColorTexture(DB.glowR+0.3, DB.glowG+0.1, DB.glowB+0.2, 0.3); f.glowIn = bi

  local ag = ring:CreateAnimationGroup(); ag:SetLooping("BOUNCE")
  local fd = ag:CreateAnimation("Alpha"); fd:SetFromAlpha(0.15); fd:SetToAlpha(0.75); fd:SetDuration(0.55)
  ag:Play(); f.ring = ring; f.ringAnim = ag; ring:Hide()

  f:SetScript("OnEnter",function()
    GameTooltip:SetOwner(f,"ANCHOR_RIGHT")
    GameTooltip:AddLine("Aim Assist — Box "..(idx==1 and "A" or "B"))
    GameTooltip:AddLine("Left: @cursor (near target feet)",0.4,1,0.4)
    GameTooltip:AddLine("Right: @player (instant)",0.8,0.8,0.8)
    GameTooltip:Show()
  end)
  f:SetScript("OnLeave",function() GameTooltip:Hide() end)

  aimFrames[idx] = f
  return f
end

----------------------------------------------------------------------
-- Update aim frame visibility + position each tick
----------------------------------------------------------------------
local function updateAim(idx)
  local aim = aimFrames[idx]
  local cfg = DB.boxes[idx]
  if not aim or not cfg then return end

  local show = cfg.mode=="cursor" and cfg.spellName~="" and
               hasEnemy() and isReady(cfg) and not isChan()
  btnVisible[idx] = show

  if show then
    aim.icon:SetTexture(spellIcon(cfg))
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and
                  C_NamePlate.GetNamePlateForUnit("target")
    -- Reposition the mover freely (plain frame, not in secure anchor chain).
    aim.mover:ClearAllPoints()
    if plate and plate:IsVisible() then
      aim.mover:SetPoint("TOP", plate, "BOTTOM", 0, -DB.feetOffset)
    else
      aim.mover:SetPoint("CENTER", UIParent, "CENTER")
    end
    aim.ring:ClearAllPoints(); aim.ring:SetPoint("CENTER",aim.mover,"CENTER")
    -- Sync secure button to mover using absolute UIParent coords — never anchored to mover.
    -- Skipped during combat: f stays at its last pre-combat position.
    if not InCombatLockdown() then
      local cx, cy = aim.mover:GetCenter()
      aim:ClearAllPoints()
      if cx and cy then
        aim:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, cy)
      else
        aim:SetPoint("CENTER", UIParent, "CENTER")
      end
    end
    aim:SetAlpha(1); aim.ring:Show()
    if aim.ringAnim and not aim.ringAnim:IsPlaying() then aim.ringAnim:Play() end
  else
    aim:SetAlpha(0)
    -- Park mover off-screen
    aim.mover:ClearAllPoints()
    aim.mover:SetPoint("CENTER", UIParent, "CENTER", OFFX, OFFY)
    aim.ring:Hide()
    if aim.ringAnim and aim.ringAnim:IsPlaying() then aim.ringAnim:Stop() end
    -- Park secure button off-screen when not in combat
    if not InCombatLockdown() then
      aim:ClearAllPoints()
      aim:SetPoint("CENTER", UIParent, "CENTER", OFFX, OFFY)
    end
  end
end

----------------------------------------------------------------------
-- Spellbook / Macro popup
-- Layout (top → bottom):
--   Header bar   36px  — spell icon preview + box title
--   Divider       2px
--   Tab row      28px  — [Spells] [Macro] tabs
--   Content      262px — spells panel OR macro panel (same height, swapped)
--   Action row    28px — @Cursor/@Player/@Target buttons  OR  Apply button
--   Bottom bar    30px — Clear Box (left)  Close (right)
----------------------------------------------------------------------
local spellCache = nil   -- refreshed on open

local SB_ROWS      = 9
local SB_ROW_H     = 26
local SB_ICON_SIZE = 22
-- Computed frame dimensions
local FW           = 300
local HDR_H        = 36
local TAB_H        = 28
local CONTENT_H    = 262   -- search(26)+divider(2)+list(9×26=234) = 262 for spells
                           -- or full macro editbox area for macro panel
local ACTION_H     = 28
local BOT_H        = 30
local FH           = HDR_H + 2 + TAB_H + CONTENT_H + ACTION_H + BOT_H + 8

local function getKnownSpells()
  local out, seen = {}, {}
  if not C_SpellBook then return out end
  local numLines = C_SpellBook.GetNumSpellBookSkillLines and
                   C_SpellBook.GetNumSpellBookSkillLines() or 0
  for li = 1, numLines do
    local ok, line = pcall(C_SpellBook.GetSpellBookSkillLineInfo, li)
    if ok and line and line.numSpellBookItems and line.itemIndexOffset then
      local bank = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or "spell"
      for slot = line.itemIndexOffset+1, line.itemIndexOffset+line.numSpellBookItems do
        local ok2, info = pcall(C_SpellBook.GetSpellBookItemInfo, slot, bank)
        if ok2 and info and not info.isPassive then
          local sid = info.spellID or info.actionID
          if sid and sid > 0 and not seen[sid] then
            seen[sid] = true
            local si = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
            if si and si.name and si.name ~= "" then
              local icon = C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid)
              table.insert(out, { id=sid, name=si.name, icon=icon })
            end
          end
        end
      end
    end
  end
  table.sort(out, function(a,b) return a.name < b.name end)
  return out
end

local function buildSpellbookPopup()
  if sbPopup then return sbPopup end

  -- ── Outer frame ──────────────────────────────────────────────────────
  local f = CreateFrame("Frame", ADDON.."SpellbookPopup", UIParent, "BackdropTemplate")
  f:SetSize(FW, FH)
  f:SetFrameStrata("DIALOG"); f:SetFrameLevel(200)
  f:SetMovable(true); f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop",  f.StopMovingOrSizing)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile=true, tileSize=16, edgeSize=16,
      insets   = {left=4, right=4, top=4, bottom=4},
    })
    f:SetBackdropColor(0.06, 0.07, 0.12, 0.97)
    f:SetBackdropBorderColor(0.35, 0.45, 0.70, 0.90)
  end
  f:Hide()

  -- ── Header bar ───────────────────────────────────────────────────────
  -- Dark gradient strip behind header content
  local hdrBg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  hdrBg:SetPoint("TOPLEFT",  f, "TOPLEFT",   4, -4)
  hdrBg:SetPoint("TOPRIGHT", f, "TOPRIGHT",  -4, -4)
  hdrBg:SetHeight(HDR_H)
  hdrBg:SetColorTexture(0.10, 0.13, 0.22, 1)

  -- Box-letter badge (coloured square: A=gold, B=teal)
  local badge = f:CreateTexture(nil, "ARTWORK")
  badge:SetSize(24, 24)
  badge:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -(HDR_H/2 - 12))
  badge:SetColorTexture(0.9, 0.75, 0.1, 1)   -- default gold; updated on open
  f.badge = badge

  local badgeLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  badgeLbl:SetPoint("CENTER", badge, "CENTER", 0, 0)
  badgeLbl:SetTextColor(0, 0, 0)
  badgeLbl:SetText("A")
  f.badgeLbl = badgeLbl

  -- Current-spell icon preview
  local hdrIcon = f:CreateTexture(nil, "ARTWORK")
  hdrIcon:SetSize(26, 26)
  hdrIcon:SetPoint("LEFT", badge, "RIGHT", 6, 0)
  hdrIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  hdrIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
  f.hdrIcon = hdrIcon

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", hdrIcon, "TOPRIGHT", 6, 0)
  title:SetTextColor(0.95, 0.90, 0.55)
  f.title = title

  local subTitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  subTitle:SetPoint("BOTTOMLEFT", hdrIcon, "BOTTOMRIGHT", 6, 2)
  subTitle:SetTextColor(0.55, 0.68, 0.88)
  f.subTitle = subTitle

  -- Thin accent line under header
  local hdrDiv = f:CreateTexture(nil, "BACKGROUND", nil, 2)
  hdrDiv:SetHeight(2)
  hdrDiv:SetPoint("TOPLEFT",  f, "TOPLEFT",   4, -(HDR_H + 4))
  hdrDiv:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -(HDR_H + 4))
  hdrDiv:SetColorTexture(0.30, 0.42, 0.72, 0.80)

  -- ── Tab row ──────────────────────────────────────────────────────────
  local tabsY = -(HDR_H + 6)   -- top of tab row relative to frame top

  local function makeTab(label, xOff)
    local btn = CreateFrame("Button", nil, f)
    btn:SetSize(100, TAB_H - 4)
    btn:SetPoint("TOPLEFT", f, "TOPLEFT", xOff, tabsY)
    local tbg = btn:CreateTexture(nil, "BACKGROUND")
    tbg:SetAllPoints(); btn.tbg = tbg
    local tbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tbl:SetAllPoints(); tbl:SetText(label); btn.tbl = tbl
    -- bottom border for active tab
    local tline = btn:CreateTexture(nil, "ARTWORK")
    tline:SetHeight(2)
    tline:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT")
    tline:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT")
    tline:SetColorTexture(0.40, 0.70, 1.0, 0); btn.tline = tline
    return btn
  end

  local tabSpells = makeTab("  Spells", 8)
  local tabMacro  = makeTab("  Macro",  112)
  f.tabSpells = tabSpells
  f.tabMacro  = tabMacro

  -- ── Shared content-top reference ─────────────────────────────────────
  -- Both panels start at the same Y (just below the tab row)
  local contentY = tabsY - TAB_H   -- offset from top of f

  -- ── Spells panel ─────────────────────────────────────────────────────
  local spellsPanel = CreateFrame("Frame", nil, f)
  spellsPanel:SetPoint("TOPLEFT",     f, "TOPLEFT",   4, contentY)
  spellsPanel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, BOT_H + ACTION_H + 4)
  f.spellsPanel = spellsPanel

  -- Search row background
  local srchBg = spellsPanel:CreateTexture(nil, "BACKGROUND")
  srchBg:SetHeight(26); srchBg:SetColorTexture(0.04, 0.05, 0.09, 0.85)
  srchBg:SetPoint("TOPLEFT",  spellsPanel, "TOPLEFT")
  srchBg:SetPoint("TOPRIGHT", spellsPanel, "TOPRIGHT")

  -- Magnifier label
  local srchLbl = spellsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  srchLbl:SetPoint("LEFT", spellsPanel, "TOPLEFT", 6, -13)
  srchLbl:SetText("|TInterface\\Common\\UI-Searchbox-Icon:14:14|t")
  srchLbl:SetTextColor(0.6, 0.65, 0.75)

  local search = CreateFrame("EditBox", ADDON.."Search", spellsPanel, "InputBoxTemplate")
  search:SetPoint("LEFT",  spellsPanel, "TOPLEFT",  24, -13)
  search:SetPoint("RIGHT", spellsPanel, "TOPRIGHT", -6, -13)
  search:SetHeight(18)
  search:SetAutoFocus(false); search:SetMaxLetters(50)
  f.search = search

  -- Divider between search and list
  local srchDiv = spellsPanel:CreateTexture(nil, "BACKGROUND")
  srchDiv:SetHeight(1)
  srchDiv:SetPoint("TOPLEFT",  spellsPanel, "TOPLEFT",  0, -26)
  srchDiv:SetPoint("TOPRIGHT", spellsPanel, "TOPRIGHT", 0, -26)
  srchDiv:SetColorTexture(0.20, 0.28, 0.48, 0.50)

  -- Scroll frame sits below the search row
  local scroll = CreateFrame("ScrollFrame", ADDON.."Scroll", spellsPanel,
                              "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT",     spellsPanel, "TOPLEFT",   0, -28)
  scroll:SetPoint("BOTTOMRIGHT", spellsPanel, "BOTTOMRIGHT", -22, 0)
  f.scroll = scroll

  local content = CreateFrame("Frame", nil, scroll)
  -- FW(300) - spellsPanel margins(8) - UIPanelScrollFrame scrollbar(22) = 270
  content:SetWidth(FW - 8 - 22)
  content:SetHeight(SB_ROWS * SB_ROW_H)
  scroll:SetScrollChild(content)
  f.content = content

  -- Spell rows (recycled pool)
  local rows = {}
  for r = 1, SB_ROWS do
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(SB_ROW_H)
    row:SetPoint("TOPLEFT",  content, "TOPLEFT",   0, -(r-1)*SB_ROW_H)
    row:SetPoint("TOPRIGHT", content, "TOPRIGHT",  0, -(r-1)*SB_ROW_H)

    -- Alternating row tint
    local rowBg = row:CreateTexture(nil, "BACKGROUND")
    rowBg:SetAllPoints()
    rowBg:SetColorTexture(1, 1, 1, r%2==0 and 0.035 or 0)
    row.rowBg = rowBg

    -- Hover highlight
    local hov = row:CreateTexture(nil, "ARTWORK")
    hov:SetAllPoints(); hov:SetColorTexture(0.28, 0.56, 1, 0); row.hov = hov
    row:SetScript("OnEnter", function(s) s.hov:SetColorTexture(0.28, 0.56, 1, 0.22) end)
    row:SetScript("OnLeave", function(s) s.hov:SetColorTexture(0.28, 0.56, 1, 0) end)

    -- Selection indicator (left-edge stripe)
    local sel = row:CreateTexture(nil, "OVERLAY")
    sel:SetWidth(3)
    sel:SetPoint("LEFT"); sel:SetPoint("TOP"); sel:SetPoint("BOTTOM")
    sel:SetColorTexture(0.35, 0.90, 0.40, 0); row.sel = sel

    -- Icon
    local ico = row:CreateTexture(nil, "OVERLAY")
    ico:SetSize(SB_ICON_SIZE, SB_ICON_SIZE); ico:SetPoint("LEFT", 6, 0)
    ico:SetTexCoord(0.07, 0.93, 0.07, 0.93); row.ico = ico

    -- Spell name
    local nm = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nm:SetPoint("LEFT",  ico, "RIGHT",  5, 0)
    nm:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    nm:SetJustifyH("LEFT"); nm:SetTextColor(0.90, 0.90, 0.90); row.nm = nm

    row:SetScript("OnClick", function()
      local sd = row.spellData
      if not sd or not f.boxIdx then return end
      if InCombatLockdown() then print(ADDON..": cannot configure in combat."); return end
      local cfg = DB.boxes[f.boxIdx]
      cfg.spellName = sd.name; cfg.spellID = sd.id
      cfg.mode = cfg.mode == "macro" and "cursor" or cfg.mode
      refreshBox(f.boxIdx)
      f:Hide()
    end)
    rows[r] = row
  end
  f.rows = rows

  -- ── Macro panel ───────────────────────────────────────────────────────
  -- Same geometry as spellsPanel so swapping is seamless.
  local macroPanel = CreateFrame("Frame", nil, f)
  macroPanel:SetPoint("TOPLEFT",     f, "TOPLEFT",   4, contentY)
  macroPanel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, BOT_H + ACTION_H + 4)
  f.macroPanel = macroPanel

  local macroLbl = macroPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  macroLbl:SetPoint("TOPLEFT", macroPanel, "TOPLEFT", 6, -6)
  macroLbl:SetText("Macro text  (max 255 chars, same as an in-game macro):")
  macroLbl:SetTextColor(0.65, 0.75, 0.95)

  -- ScrollFrame wrapper for the multiline editbox
  local macroScroll = CreateFrame("ScrollFrame", nil, macroPanel, "UIPanelScrollFrameTemplate")
  macroScroll:SetPoint("TOPLEFT",     macroPanel, "TOPLEFT",   4, -20)
  macroScroll:SetPoint("BOTTOMRIGHT", macroPanel, "BOTTOMRIGHT", -22, 4)

  local macroEB = CreateFrame("EditBox", ADDON.."MacroEB", macroScroll)
  macroEB:SetMultiLine(true); macroEB:SetMaxLetters(255)
  macroEB:SetAutoFocus(false); macroEB:SetFontObject("ChatFontNormal")
  -- FW(300) - macroPanel margins(8) - inner margin(8) - scrollbar(22) = 262
  macroEB:SetWidth(FW - 8 - 8 - 22)
  macroEB:SetTextColor(0.92, 0.92, 0.80)
  macroEB:SetScript("OnEscapePressed", function() f:Hide() end)
  macroEB:SetScript("OnTextChanged",   function(self)
    -- keep editbox width in sync if scroll frame resizes for any reason
    local sw = macroScroll:GetWidth()
    if sw > 10 then self:SetWidth(sw) end
  end)
  macroScroll:SetScrollChild(macroEB)
  f.macroEB = macroEB

  -- ── Action row  (just above bottom bar) ──────────────────────────────
  -- In Spells view: three mode buttons.
  -- In Macro view: Apply button (mode buttons hidden).

  -- Mode buttons — @Cursor / @Player / @Target (not Macro — that's handled by tab)
  local modes  = { "cursor", "player", "target" }
  local mLabel = { "@Cursor", "@Player", "@Target" }
  f.modeBtns = {}
  for mi, m in ipairs(modes) do
    local mb = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    mb:SetSize(86, 22); mb:SetText(mLabel[mi])
    mb:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 4 + (mi-1)*89, BOT_H + 4)
    mb.modeVal = m
    mb:SetScript("OnClick", function()
      if not f.boxIdx or InCombatLockdown() then return end
      DB.boxes[f.boxIdx].mode = m
      refreshBox(f.boxIdx)
      for _, b in ipairs(f.modeBtns) do b:SetAlpha(b.modeVal == m and 1 or 0.4) end
    end)
    f.modeBtns[mi] = mb
  end

  -- Apply button (Macro tab only)
  local applyBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  applyBtn:SetSize(100, 22); applyBtn:SetText("Apply Macro")
  applyBtn:SetPoint("LEFT", f, "BOTTOMLEFT", 4, BOT_H + 4)
  applyBtn:SetScript("OnClick", function()
    if not f.boxIdx or InCombatLockdown() then return end
    local txt = macroEB:GetText() or ""
    if txt:gsub("%s+","") == "" then
      print(ADDON..": macro text is empty — not applied."); return
    end
    local cfg = DB.boxes[f.boxIdx]
    cfg.macroText = txt; cfg.mode = "macro"
    refreshBox(f.boxIdx)
    f:Hide()
  end)
  f.applyBtn = applyBtn

  -- ── Bottom bar ────────────────────────────────────────────────────────
  local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  clearBtn:SetSize(86, 22); clearBtn:SetText("Clear Box")
  clearBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 4, 6)
  clearBtn:SetScript("OnClick", function()
    if not f.boxIdx or InCombatLockdown() then return end
    for k,v in pairs(defaultBox()) do DB.boxes[f.boxIdx][k] = v end
    refreshBox(f.boxIdx)
    f:Hide()
  end)

  local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  closeBtn:SetSize(70, 22); closeBtn:SetText("Close")
  closeBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 6)
  closeBtn:SetScript("OnClick", function() f:Hide() end)

  -- ── Tab switching ─────────────────────────────────────────────────────
  local function activateTab(which)
    local isSpells = (which == "spells")
    -- Panel visibility
    if isSpells then spellsPanel:Show() else spellsPanel:Hide() end
    if isSpells then macroPanel:Hide() else macroPanel:Show() end
    -- Action row
    for _, mb in ipairs(f.modeBtns) do mb:SetShown(isSpells) end
    applyBtn:SetShown(not isSpells)
    -- Tab button styling
    tabSpells.tbg:SetColorTexture( isSpells and 0.18 or 0.07,
                                   isSpells and 0.28 or 0.09,
                                   isSpells and 0.52 or 0.16, 0.85)
    tabSpells.tline:SetColorTexture(0.40, 0.70, 1.0, isSpells and 0.9 or 0)
    tabSpells.tbl:SetTextColor(isSpells and 1 or 0.5, isSpells and 1 or 0.55, 1)

    tabMacro.tbg:SetColorTexture( (not isSpells) and 0.18 or 0.07,
                                  (not isSpells) and 0.28 or 0.09,
                                  (not isSpells) and 0.52 or 0.16, 0.85)
    tabMacro.tline:SetColorTexture(0.40, 0.70, 1.0, (not isSpells) and 0.9 or 0)
    tabMacro.tbl:SetTextColor((not isSpells) and 1 or 0.5, (not isSpells) and 1 or 0.55, 1)

    f.activeTab = which
    if isSpells then search:SetFocus() else macroEB:SetFocus() end
  end
  f.activateTab = activateTab

  tabSpells:SetScript("OnClick", function() activateTab("spells") end)
  tabMacro:SetScript("OnClick",  function() activateTab("macro")  end)

  -- ── Spell list populate ───────────────────────────────────────────────
  local function populate()
    local filter = (search:GetText() or ""):lower()
    local spells  = spellCache or {}
    local curID   = f.boxIdx and DB.boxes[f.boxIdx].spellID or 0
    local visible, n = {}, 0
    for _, s in ipairs(spells) do
      if filter == "" or s.name:lower():find(filter, 1, true) then
        n = n+1; visible[n] = s
      end
    end
    content:SetHeight(math.max(n * SB_ROW_H, SB_ROWS * SB_ROW_H))
    for r, row in ipairs(rows) do
      local sd = visible[r]
      if sd then
        row:Show(); row.spellData = sd
        row.ico:SetTexture(sd.icon); row.nm:SetText(sd.name)
        -- Highlight currently-configured spell
        local isCur = (sd.id == curID and curID ~= 0)
        row.sel:SetColorTexture(0.35, 0.90, 0.40, isCur and 1 or 0)
        row.nm:SetTextColor(isCur and 0.45 or 0.90,
                            isCur and 1.00 or 0.90,
                            isCur and 0.50 or 0.90)
      else
        row:Hide(); row.spellData = nil
      end
    end
    scroll:SetVerticalScroll(0)
  end
  f.populate = populate
  search:SetScript("OnTextChanged",  function() populate() end)
  search:SetScript("OnEscapePressed", function() f:Hide() end)

  sbPopup = f
  return f
end

local function openSpellbook(idx)
  local pop = buildSpellbookPopup()
  local cfg = DB.boxes[idx]
  pop.boxIdx = idx

  -- Header: badge colour (A=gold, B=teal), icon, title text
  local isA = (idx == 1)
  pop.badge:SetColorTexture(isA and 0.90 or 0.20, isA and 0.75 or 0.80, isA and 0.10 or 0.85, 1)
  pop.badgeLbl:SetText(isA and "A" or "B")
  pop.hdrIcon:SetTexture(cfg.spellID and cfg.spellID > 0
    and (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(cfg.spellID))
    or  "Interface\\Icons\\INV_Misc_QuestionMark")
  pop.title:SetText("Box "..(isA and "A" or "B").." — Configure")
  pop.subTitle:SetText(cfg.spellName ~= "" and cfg.spellName
    or (cfg.mode == "macro" and "(macro)" or "(empty)"))

  -- Refresh spell cache and repopulate list
  spellCache = getKnownSpells()
  pop.search:SetText("")
  pop.populate()

  -- Mode button highlight  (only cursor/player/target shown; macro handled by tab)
  for _, mb in ipairs(pop.modeBtns) do
    mb:SetAlpha(mb.modeVal == cfg.mode and 1 or 0.4)
  end

  -- Open to the right tab: macro mode → Macro tab, otherwise Spells tab
  if cfg.mode == "macro" then
    pop.macroEB:SetText(cfg.macroText or "")
    pop.activateTab("macro")
  else
    pop.activateTab("spells")
  end

  -- Anchor: appear above the box button that was right-clicked.
  -- Only reposition when first opening (preserve user-dragged position).
  if not pop:IsShown() then
    local anchor = boxFrames[idx] or mainFrame
    pop:ClearAllPoints()
    if anchor then
      -- Prefer above the button; if the button is near the top edge WoW will
      -- still render the frame (it can go off-screen but drag corrects it).
      pop:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 8)
    else
      pop:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    end
  end

  pop:Show()
end

----------------------------------------------------------------------
-- Config panel
----------------------------------------------------------------------
local function buildConfigPanel()
  if cfgPanel then return cfgPanel end

  local f = CreateFrame("Frame", ADDON.."Config", UIParent, "BackdropTemplate")
  f:SetSize(300, 360); f:SetFrameStrata("DIALOG"); f:SetFrameLevel(150)
  f:SetMovable(true); f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart",f.StartMoving); f:SetScript("OnDragStop",f.StopMovingOrSizing)
  if f.SetBackdrop then
    f:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
      tile=true,tileSize=16,edgeSize=16,insets={left=4,right=4,top=4,bottom=4}})
    f:SetBackdropColor(0,0,0,0.95)
  end
  f:Hide()

  local title = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
  title:SetPoint("TOP",f,"TOP",0,-10); title:SetText("TrinketMenu Plus — Options")

  -- Manual slider builder — no OptionsSliderTemplate, no _G child lookups.
  -- Works across all WoW versions including Midnight 12.x where the template
  -- child names (SliderNameLow/High/Text) were refactored.
  local yOff = -32
  local function addSlider(lbl, key, minV, maxV, step, fmt)
    local curVal = DB[key] or minV

    local valLbl = f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    valLbl:SetPoint("TOPLEFT",f,"TOPLEFT",16,yOff)
    valLbl:SetText(lbl..":  "..string.format(fmt or "%.0f", curVal))
    yOff = yOff - 16

    local s = CreateFrame("Slider", nil, f)          -- NO global name = no _G risk
    s:SetSize(240,16)
    s:SetPoint("TOPLEFT",f,"TOPLEFT",16,yOff)
    s:SetOrientation("HORIZONTAL")
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    s:SetValue(curVal)

    local thumb = s:CreateTexture(nil,"OVERLAY")
    thumb:SetTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    thumb:SetSize(16,16); s:SetThumbTexture(thumb)
    local track = s:CreateTexture(nil,"BACKGROUND")
    track:SetTexture("Interface\\Buttons\\UI-SliderBar-Background")
    track:SetHeight(8); track:SetPoint("TOPLEFT",4,0); track:SetPoint("BOTTOMRIGHT",-4,0)
    local minT = f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    minT:SetPoint("TOPLEFT",s,"BOTTOMLEFT",0,-2); minT:SetText(tostring(minV))
    local maxT = f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    maxT:SetPoint("TOPRIGHT",s,"BOTTOMRIGHT",0,-2); maxT:SetText(tostring(maxV))

    s:SetScript("OnValueChanged",function(self, v)
      v = math.floor(v/step + 0.5)*step
      DB[key] = v
      valLbl:SetText(lbl..":  "..string.format(fmt or "%.0f", v))
      if key=="boxSize" then
        for ii=1,2 do if boxFrames[ii] then boxFrames[ii]:SetSize(v,v) end end
        if mainFrame then mainFrame:SetSize(5+v+5+v+5, 5+v+5) end
      elseif key=="scale" then
        if mainFrame then mainFrame:SetScale(v) end
      end
    end)
    yOff = yOff - 30
  end

  addSlider("Button Size",  "boxSize",    24, 64,  2)
  addSlider("Frame Scale",  "scale",    0.5,  2.0, 0.05, "%.2f")
  addSlider("Feet Offset",  "feetOffset", 40, 320, 5)

  -- Glow colour (R/G/B)
  yOff = yOff - 6
  local glowHdr = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
  glowHdr:SetPoint("TOPLEFT",f,"TOPLEFT",16,yOff); glowHdr:SetText("Aim Glow Colour")
  yOff = yOff - 20

  for _,ch in ipairs({"glowR","glowG","glowB"}) do
    local chanName = ch:sub(5):upper()
    local curV = DB[ch] or 0
    local cLbl = f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    cLbl:SetPoint("TOPLEFT",f,"TOPLEFT",16,yOff)
    cLbl:SetText(chanName..string.format(":  %.2f", curV))
    yOff = yOff - 16

    local cs = CreateFrame("Slider", nil, f)
    cs:SetSize(240,16); cs:SetPoint("TOPLEFT",f,"TOPLEFT",16,yOff)
    cs:SetOrientation("HORIZONTAL"); cs:SetMinMaxValues(0,1)
    cs:SetValueStep(0.05); cs:SetObeyStepOnDrag(true); cs:SetValue(curV)
    local ct = cs:CreateTexture(nil,"OVERLAY")
    ct:SetTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    ct:SetSize(16,16); cs:SetThumbTexture(ct)
    local cbg = cs:CreateTexture(nil,"BACKGROUND")
    cbg:SetTexture("Interface\\Buttons\\UI-SliderBar-Background")
    cbg:SetHeight(8); cbg:SetPoint("TOPLEFT",4,0); cbg:SetPoint("BOTTOMRIGHT",-4,0)

    cs:SetScript("OnValueChanged",function(self,v)
      DB[ch] = v
      cLbl:SetText(chanName..string.format(":  %.2f",v))
      for _,aim in ipairs(aimFrames) do
        if aim and aim.glowBg then aim.glowBg:SetColorTexture(DB.glowR,DB.glowG,DB.glowB,0.5) end
        if aim and aim.glowIn then aim.glowIn:SetColorTexture(DB.glowR+0.3,DB.glowG+0.1,DB.glowB+0.2,0.3) end
      end
    end)
    yOff = yOff - 26
  end

  -- Dock buttons
  yOff = yOff - 6
  local dockHdr = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
  dockHdr:SetPoint("TOPLEFT",f,"TOPLEFT",16,yOff); dockHdr:SetText("Dock Side")
  yOff = yOff - 22

  local DKMAP = {right={a="LEFT",r="RIGHT",x=2,y=0},left={a="RIGHT",r="LEFT",x=-2,y=0},
                 top={a="BOTTOM",r="TOP",x=0,y=2},bottom={a="TOP",r="BOTTOM",x=0,y=-2}}
  for di,d in ipairs({"right","left","top","bottom"}) do
    local db2 = CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
    db2:SetSize(64,22); db2:SetText(d:sub(1,1):upper()..d:sub(2))
    db2:SetPoint("TOPLEFT",f,"TOPLEFT",4+(di-1)*68,yOff)
    db2:SetScript("OnClick",function()
      DB.dock = d
      if mainFrame and TrinketMenu_MainFrame then
        local dk=DKMAP[d]; mainFrame:ClearAllPoints()
        mainFrame:SetPoint(dk.a, TrinketMenu_MainFrame, dk.r, dk.x, dk.y)
      end
    end)
  end

  -- Bottom bar
  local resetBtn = CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
  resetBtn:SetSize(90,22); resetBtn:SetText("Reset Position")
  resetBtn:SetPoint("BOTTOMLEFT",f,"BOTTOMLEFT",8,8)
  resetBtn:SetScript("OnClick",function()
    if mainFrame and TrinketMenu_MainFrame then
      local dk=DKMAP[DB.dock] or DKMAP.right
      mainFrame:ClearAllPoints()
      mainFrame:SetPoint(dk.a, TrinketMenu_MainFrame, dk.r, dk.x, dk.y)
    end
  end)

  local closeBtn = CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
  closeBtn:SetSize(60,22); closeBtn:SetText("Close")
  closeBtn:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-8,8)
  closeBtn:SetScript("OnClick",function() f:Hide() end)

  cfgPanel = f
  return f
end

----------------------------------------------------------------------
-- Build the main plus frame + box buttons
----------------------------------------------------------------------
local DOCKS = {
  right  = {a="LEFT",  r="RIGHT",  x= 2, y=0},
  left   = {a="RIGHT", r="LEFT",   x=-2, y=0},
  top    = {a="BOTTOM",r="TOP",    x= 0, y=2},
  bottom = {a="TOP",   r="BOTTOM", x= 0, y=-2},
}

local function buildFrames()
  local sz  = DB.boxSize or 36
  local pad = 5
  local fw  = pad + sz + pad + sz + pad   -- total frame width
  local fh  = pad + sz + pad              -- total frame height

  -- Outer container
  local mf = CreateFrame("Frame", ADDON.."_Frame", UIParent, "BackdropTemplate")
  mf:SetSize(fw, fh); mf:SetScale(DB.scale or 1)
  mf:SetFrameStrata("BACKGROUND")
  mf:SetMovable(true); mf:EnableMouse(true)
  if mf.SetBackdrop and TRINKETMENU_BACKDROP_16_16_4444 then
    mf:SetBackdrop(TRINKETMENU_BACKDROP_16_16_4444)
    mf:SetBackdropColor(0,0,0,1)
    mf:SetBackdropBorderColor(0.5,0.5,0.5,1)
  end

  -- Dock to TrinketMenu
  local ref = TrinketMenu_MainFrame
  local dk  = DOCKS[DB.dock] or DOCKS.right
  if ref then
    mf:SetPoint(dk.a, ref, dk.r, dk.x, dk.y)
  else
    mf:SetPoint("LEFT",UIParent,"CENTER",100,0)
  end
  mf:SetScript("OnMouseDown",function(s,b) if b=="LeftButton" and not DB.locked then s:StartMoving() end end)
  mf:SetScript("OnMouseUp",  function(s) s:StopMovingOrSizing() end)
  mainFrame = mf

  -- Two spell boxes — side by side, symmetric padding
  local positions = { {pad, -pad}, {pad+sz+pad, -pad} }
  for i = 1,2 do
    local cfg = DB.boxes[i]
    -- ONLY SecureActionButtonTemplate — ActionButtonTemplate's OnClick
    -- overrides type="macro" causing clicks to do nothing.
    local btn = CreateFrame("Button", ADDON.."_Box"..i, mf, "SecureActionButtonTemplate")
    btn:SetSize(sz, sz)
    btn:SetPoint("TOPLEFT", positions[i][1], positions[i][2])
    btn:RegisterForClicks("LeftButtonUp","RightButtonUp")

    -- Background texture (like an action button)
    local bg = btn:CreateTexture(nil,"BACKGROUND")
    bg:SetAllPoints(); bg:SetColorTexture(0,0,0,0.6)

    -- Icon
    local icon = btn:CreateTexture(nil,"ARTWORK")
    icon:SetAllPoints(); icon:SetTexCoord(0.07,0.93,0.07,0.93); btn.icon = icon

    -- Pushed state overlay
    local pushed = btn:CreateTexture(nil,"OVERLAY")
    pushed:SetAllPoints(); pushed:SetColorTexture(1,1,1,0)
    btn:SetScript("OnMouseDown",function() pushed:SetColorTexture(1,1,1,0.15) end)
    btn:SetScript("OnMouseUp",  function() pushed:SetColorTexture(1,1,1,0) end)

    -- Normal border
    local border = btn:CreateTexture(nil,"BORDER")
    border:SetPoint("TOPLEFT",-1,1); border:SetPoint("BOTTOMRIGHT",1,-1)
    border:SetColorTexture(0.4,0.4,0.4,0.8)

    -- Label
    local lbl = btn:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    lbl:SetPoint("BOTTOM",btn,"BOTTOM",0,1); btn.lbl = lbl

    -- Cooldown frame
    local cd = CreateFrame("Cooldown",ADDON.."CD"..i,btn,"CooldownFrameTemplate")
    cd:SetAllPoints(); cd:SetDrawEdge(false); cd:SetHideCountdownNumbers(false)
    btn.cooldown = cd

    -- Tooltip
    btn:SetScript("OnEnter",function(self)
      GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
      local c = DB.boxes[i]
      GameTooltip:AddLine("Box "..(i==1 and "A" or "B")..": "..(c.spellName~="" and c.spellName or "Empty"))
      GameTooltip:AddLine("Mode: "..c.mode, 0.8,0.8,0.8)
      GameTooltip:AddLine("Left: cast  |  Right: @target  |  Ctrl+Right: configure",0.6,0.6,0.6)
      GameTooltip:Show()
    end)
    btn:SetScript("OnLeave",function() GameTooltip:Hide() end)

    -- Ctrl+Right-click: open spellbook picker.
    -- Plain Right-click fires @target quick-cast (handled by the secure attribute set in
    -- refreshBox) and must NOT open the picker — that would be confusing during combat.
    -- PostClick fires after the secure action, so we only act when Ctrl is held.
    btn:SetScript("PostClick",function(self,button)
      if button=="RightButton" and IsControlKeyDown() and not InCombatLockdown() then
        openSpellbook(i)
      end
    end)

    boxFrames[i] = btn
    buildAimFrame(i)
    refreshBox(i)
  end
end

----------------------------------------------------------------------
-- OnUpdate
----------------------------------------------------------------------
local function onUpdate(s,dt)
  throttle = throttle+dt; if throttle<0.05 then return end; throttle=0
  for i=1,2 do
    updateAim(i)
    local bx  = boxFrames[i]
    local bcf = DB.boxes[i]
    if bx and bx.cooldown and bcf and bcf.spellID and bcf.spellID>0 then
      if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(bcf.spellID)
        if info then
          pcall(function()     -- anonymous closure: secret fields only touched inside
            if info.isActive then
              bx.cooldown:SetCooldown(info.startTime, info.duration)
            else
              bx.cooldown:SetCooldown(0,0)
            end
          end)
        end
      end
    end
  end
end

----------------------------------------------------------------------
-- Minimap button — draggable around the minimap border
----------------------------------------------------------------------
local minimapBtn = nil

local function buildMinimapBtn()
  if minimapBtn then return minimapBtn end

  ----------------------------------------------------------------------
  -- PRIMARY PATH: LibDBIcon-1.0 (makes MBB / Bazooka / etc. see us)
  -- LibDBIcon ships with Minimap Button Button, so if the user has MBB
  -- installed it will already be in LibStub — no need to bundle the lib.
  ----------------------------------------------------------------------
  local LDB    = LibStub and LibStub("LibDataBroker-1.1", true)
  local DBIcon = LibStub and LibStub("LibDBIcon-1.0",     true)

  if LDB and DBIcon then
    local function toggleConfig()
      local cp = buildConfigPanel()
      if cp:IsShown() then cp:Hide()
      else
        cp:Show()
        if not cp.placed then
          cp:ClearAllPoints(); cp:SetPoint("TOPLEFT",UIParent,"CENTER",20,20)
          cp.placed = true
        end
      end
    end

    local broker = LDB:NewDataObject(ADDON, {
      type  = "launcher",
      text  = "TrinketMenu Plus",
      icon  = "Interface\\Icons\\Ability_Druid_ForceOfNature",
      OnClick = function(_, button)
        if button == "LeftButton" then toggleConfig() end
      end,
      OnTooltipShow = function(tt)
        tt:AddLine("TrinketMenu Plus")
        tt:AddLine("Click: Toggle Options",  0.8, 0.8, 0.8)
        tt:AddLine("Drag: Move button",      0.6, 0.6, 0.6)
      end,
    })

    -- DB.minimapIcon is the settings table LibDBIcon reads/writes for
    -- position and hide state — it's a sub-key of our SavedVariables so
    -- everything persists automatically.
    DBIcon:Register(ADDON, broker, DB.minimapIcon)
    minimapBtn = DBIcon:GetMinimapButton(ADDON)
    return minimapBtn
  end

  ----------------------------------------------------------------------
  -- FALLBACK: hand-rolled button (used only when LibDBIcon is absent)
  -- Button is 31x31 — the size MiniMap-TrackingBorder (54x54) is tuned
  -- for.  The old 26x26 size caused the icon to appear offset inside
  -- the ring because the transparent centre of the border texture
  -- assumed a larger fill area.
  ----------------------------------------------------------------------
  local btn = CreateFrame("Button", ADDON.."MinimapBtn", Minimap)
  btn:SetSize(31, 31)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)

  -- Icon
  local icon = btn:CreateTexture(nil,"ARTWORK")
  icon:SetAllPoints()
  icon:SetTexture("Interface\\Icons\\Ability_Druid_ForceOfNature")
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  -- Circular mask so icon clips to a circle
  if btn.CreateMaskTexture then
    local mask = btn:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)
  end

  -- Border ring — 54x54 frames a 31x31 icon correctly
  local ring = btn:CreateTexture(nil,"OVERLAY")
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetSize(54, 54)
  ring:SetPoint("CENTER", btn, "CENTER", 0, 0)

  btn:SetScript("OnEnter",function()
    GameTooltip:SetOwner(btn,"ANCHOR_LEFT")
    GameTooltip:AddLine("TrinketMenu Plus")
    GameTooltip:AddLine("Click: Toggle Options",0.8,0.8,0.8)
    GameTooltip:AddLine("Drag: Move button",0.6,0.6,0.6)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave",function() GameTooltip:Hide() end)

  btn:SetScript("OnClick",function(self, button)
    if button=="LeftButton" then
      local cp = buildConfigPanel()
      if cp:IsShown() then cp:Hide() else
        cp:Show()
        if not cp.placed then
          cp:ClearAllPoints(); cp:SetPoint("TOPLEFT",UIParent,"CENTER",20,20)
          cp.placed = true
        end
      end
    end
  end)

  -- Drag: recalculate angle around the Minimap on each frame
  local dragging = false
  btn:RegisterForDrag("LeftButton")
  btn:SetScript("OnDragStart", function() dragging=true  end)
  btn:SetScript("OnDragStop",  function() dragging=false end)

  local function applyAngle(a)
    DB.minimapAngle = a
    local r = (Minimap:GetWidth() / 2) + 5
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", r*math.cos(a), r*math.sin(a))
  end

  applyAngle(DB.minimapAngle or (math.pi * 0.25))  -- default: upper-right

  local updater = CreateFrame("Frame")
  updater:SetScript("OnUpdate",function()
    if not dragging then return end
    local cx, cy = Minimap:GetCenter()
    if not cx then return end
    local scale = UIParent:GetEffectiveScale()
    local mx, my = GetCursorPosition()
    mx, my = mx/scale, my/scale
    applyAngle(math.atan2(my-cy, mx-cx))
  end)

  minimapBtn = btn
  return btn
end

----------------------------------------------------------------------
-- Bootstrap
----------------------------------------------------------------------
local driver = CreateFrame("Frame")
driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_TARGET_CHANGED")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:SetScript("OnEvent",function(self,event)
  if event=="PLAYER_LOGIN" then
    TrinketMenuPlusDB = TrinketMenuPlusDB or {}
    local saved = TrinketMenuPlusDB
    -- merge saved over defaults
    for k,v in pairs(saved) do
      if k=="boxes" then
        for i=1,2 do
          if saved.boxes[i] then
            for bk,bv in pairs(saved.boxes[i]) do DB.boxes[i][bk]=bv end
          end
        end
      else DB[k]=v end
    end
    TrinketMenuPlusDB = DB   -- point saved to live DB

    buildFrames()
    buildMinimapBtn()
    self:SetScript("OnUpdate",onUpdate)
  elseif event=="PLAYER_TARGET_CHANGED" then
    for i=1,2 do updateAim(i) end
  elseif event=="PLAYER_REGEN_ENABLED" then
    -- Combat ended: re-sync aim button positions now that secure frames can be moved again
    for i=1,2 do updateAim(i) end
  end
end)

----------------------------------------------------------------------
-- Slash
----------------------------------------------------------------------
SLASH_TRINKETMENUPLUS1 = "/tmp"
SlashCmdList.TRINKETMENUPLUS = function(msg)
  local parts={}; for p in (msg or ""):gmatch("%S+") do parts[#parts+1]=p end
  local sub=(parts[1] or ""):lower()
  local idx = sub=="a" and 1 or sub=="b" and 2 or nil

  if idx then
    if InCombatLockdown() then print(ADDON..": cannot configure in combat."); return end
    local cmd=(parts[2] or ""):lower()
    local val=table.concat(parts," ",3):gsub('^"?(.-)"?$','%1')
    local cfg=DB.boxes[idx]
    if cmd=="spell" or cmd=="item" then
      cfg.spellName=val; cfg.mode=(cfg.mode=="macro" and "cursor" or cfg.mode)
      if C_Spell and C_Spell.GetSpellInfo then
        local si=C_Spell.GetSpellInfo(val); cfg.spellID=si and si.spellID or 0
      end
      refreshBox(idx); print(ADDON..": Box "..(idx==1 and "A" or "B").." = "..val)
    elseif cmd=="macro" then
      cfg.macroText=val; cfg.mode="macro"; refreshBox(idx)
      print(ADDON..": macro set for Box "..(idx==1 and "A" or "B"))
    elseif cmd=="mode" then
      local m=(parts[3] or ""):lower()
      if m=="cursor" or m=="player" or m=="target" or m=="macro" then
        cfg.mode=m; refreshBox(idx); print(ADDON..": mode="..m)
      else print(ADDON..": mode must be cursor|player|target|macro") end
    elseif cmd=="clear" then
      for k,v in pairs(defaultBox()) do cfg[k]=v end
      refreshBox(idx); print(ADDON..": Box "..(idx==1 and "A" or "B").." cleared.")
    elseif cmd=="config" or cmd=="pick" then openSpellbook(idx)
    else print("Box "..sub..": spell|item|macro|mode|clear|config") end

  elseif sub=="dock" then
    local d=(parts[2] or ""):lower()
    if DOCKS[d] then DB.dock=d
      if mainFrame and TrinketMenu_MainFrame then
        local dk=DOCKS[d]; mainFrame:ClearAllPoints()
        mainFrame:SetPoint(dk.a,TrinketMenu_MainFrame,dk.r,dk.x,dk.y)
      end; print(ADDON..": dock="..d)
    else print(ADDON..": dock must be left|right|top|bottom") end

  elseif sub=="config" then
    buildConfigPanel():Show()
  elseif sub=="lock" then   DB.locked=true;  print(ADDON..": locked.")
  elseif sub=="unlock" then DB.locked=false; print(ADDON..": unlocked.")
  elseif sub=="status" then
    print(string.format("%s: dock=%s locked=%s boxSize=%d scale=%.2f",
      ADDON,DB.dock,tostring(DB.locked),DB.boxSize,DB.scale))
    for i=1,2 do
      local c=DB.boxes[i]
      local rdy = isReady(c)
      print(string.format("  Box %s: mode=%s spell=%s (id=%d) ready=%s",
        i==1 and "A" or "B", c.mode,
        c.spellName~="" and c.spellName or "(none)",
        c.spellID or 0, tostring(rdy)))
      -- FONaim conditions
      local aim = aimFrames[i]
      if aim then
        local cond_mode    = c.mode=="cursor"
        local cond_spell   = c.spellName~=""
        local cond_enemy   = hasEnemy()
        local cond_ready   = rdy
        local cond_nochan  = not isChan()
        print(string.format("    Aim: frame=OK  @cursor=%s spell=%s enemy=%s ready=%s nochan=%s  → show=%s",
          tostring(cond_mode), tostring(cond_spell), tostring(cond_enemy),
          tostring(cond_ready), tostring(cond_nochan),
          tostring(cond_mode and cond_spell and cond_enemy and cond_ready and cond_nochan)))
      else
        print("    Aim: frame NOT built yet")
      end
    end
  else
    print(ADDON.." — /tmp a|b spell|item|macro|mode|clear|config  |  dock|config|lock|unlock|status")
  end
end
