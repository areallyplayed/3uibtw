--[[
	library.lua  |  Kiciahook UI library (LinoriaLib-style API)

	Returns the Library table. ThemeManager and SaveManager are built in:
		Library.ThemeManager, Library.SaveManager

	Controls (all real, all with callbacks):
		Groupbox:AddLabel / AddButton / AddDivider / AddBlank
		Groupbox:AddToggle   (Toggle:AddColorPicker, Toggle:AddKeyPicker)
		Groupbox:AddSlider   Groupbox:AddDropdown   Groupbox:AddInput
		Label:AddColorPicker / Label:AddKeyPicker

	Containers:
		Library:CreateWindow -> Window:AddTab -> Tab:AddLeftGroupbox / AddRightGroupbox
		                                         Tab:AddLeftTabbox  / AddRightTabbox
		                                         Tab:AddSubTab (nested tab strip, same groupbox API)

	Values live in Library.Toggles[idx] / Library.Options[idx]
	(also mirrored to getgenv().Toggles / getgenv().Options when available).

	Works in an executor (loadstring(readfile("library.lua"))()) or as a
	ModuleScript in Roblox Studio (require). Disk persistence needs the executor
	file functions; without them SaveManager falls back to in-memory storage.
]]

local cloneref = cloneref or function(Obj) return Obj end

local Players = cloneref(game:GetService('Players'))
local InputService = cloneref(game:GetService('UserInputService'))
local TextService = cloneref(game:GetService('TextService'))
local TweenService = cloneref(game:GetService('TweenService'))
local RunService = cloneref(game:GetService('RunService'))
local HttpService = cloneref(game:GetService('HttpService'))
local CoreGui = cloneref(game:GetService('CoreGui'))
local LocalPlayer = Players.LocalPlayer

--// Global environment (executor getgenv or _G)
local ENV = _G
do
	local Ok, Env = pcall(function() return getgenv() end)
	if Ok and type(Env) == 'table' then ENV = Env end
end

-- Re-running the script unloads the previous copy first
if type(ENV.KiciahookLibrary) == 'table' and type(ENV.KiciahookLibrary.Unload) == 'function' then
	pcall(ENV.KiciahookLibrary.Unload, ENV.KiciahookLibrary)
end

--// Small utilities --------------------------------------------------------
local function Clamp(Num, Lo, Hi)
	if Num < Lo then return Lo elseif Num > Hi then return Hi end
	return Num
end

local function Round(Num, Places)
	Places = Places or 0
	if Places <= 0 then return math.floor(Num + 0.5) end
	local Mult = 10 ^ Places
	return math.floor(Num * Mult + 0.5) / Mult
end

local function IndexOf(List, Value)
	for Index, Item in ipairs(List) do
		if Item == Value then return Index end
	end
	return nil
end

local function CopyValue(Value)
	if type(Value) ~= 'table' then return Value end
	local Out = {}
	for Key, Item in pairs(Value) do Out[Key] = CopyValue(Item) end
	return Out
end

local function ColorToHex(Color)
	return string.format('%02x%02x%02x',
		math.floor(Color.R * 255 + 0.5), math.floor(Color.G * 255 + 0.5), math.floor(Color.B * 255 + 0.5))
end

local function HexToColor(Hex)
	Hex = string.gsub(tostring(Hex), '[#%s]', '')
	if #Hex == 3 then
		Hex = Hex:sub(1, 1):rep(2) .. Hex:sub(2, 2):rep(2) .. Hex:sub(3, 3):rep(2)
	end
	if #Hex ~= 6 or Hex:find('%X') then return nil end
	local Num = tonumber(Hex, 16)
	if not Num then return nil end
	return Color3.fromRGB(math.floor(Num / 65536) % 256, math.floor(Num / 256) % 256, Num % 256)
end

local function IsPointer(Input)
	return Input.UserInputType == Enum.UserInputType.MouseButton1
		or Input.UserInputType == Enum.UserInputType.Touch
end

--// Library table ------------------------------------------------------------
local Library = {
	Registry = {},
	RegistryMap = {},
	Signals = {},
	UnloadCallbacks = {},
	Popups = {},
	Windows = {},
	Toggles = {},
	Options = {},

	-- Theme (kept in sync with ThemeManager's "Kiciahook" theme)
	FontColor = Color3.fromRGB(255, 255, 255),
	MainColor = Color3.fromRGB(28, 28, 28),
	BackgroundColor = Color3.fromRGB(20, 20, 20),
	AccentColor = Color3.fromRGB(100, 96, 210),
	OutlineColor = Color3.fromRGB(50, 50, 50),
	RiskColor = Color3.fromRGB(255, 50, 50),
	Black = Color3.new(0, 0, 0),

	Font = Enum.Font.Code,
	TextSize = 14,

	Toggled = false,
	Unloaded = false,
	IsPicking = false,
	ToggleKeybind = nil,
}

ENV.Toggles = Library.Toggles
ENV.Options = Library.Options
ENV.KiciahookLibrary = Library

function Library:GetDarkerColor(Color)
	local H, S, V = Color3.toHSV(Color)
	return Color3.fromHSV(H, S, V / 1.5)
end

function Library:RefreshDerivedColors()
	Library.AccentColorDark = Library:GetDarkerColor(Library.AccentColor)
	local F = Library.FontColor
	Library.DimFontColor = Color3.new(F.R * 0.65, F.G * 0.65, F.B * 0.65)
end
Library:RefreshDerivedColors()

--// Instances + theme registry --------------------------------------------------
function Library:Create(Class, Properties)
	local Obj = Instance.new(Class)
	local Parent = nil
	for Property, Value in pairs(Properties or {}) do
		if Property == 'Parent' then Parent = Value else Obj[Property] = Value end
	end
	if Parent then Obj.Parent = Parent end
	return Obj
end

local function ResolveColor(Value)
	if type(Value) == 'string' then return Library[Value] end
	if type(Value) == 'function' then return Value() end
	return Value
end

function Library:AddToRegistry(Obj, Properties)
	local Data = { Instance = Obj, Properties = Properties }
	table.insert(Library.Registry, Data)
	Library.RegistryMap[Obj] = Data
	for Property, Value in pairs(Properties) do
		Obj[Property] = ResolveColor(Value)
	end
	return Data
end

function Library:RemoveFromRegistry(Obj)
	local Data = Library.RegistryMap[Obj]
	if not Data then return end
	for Index = #Library.Registry, 1, -1 do
		if Library.Registry[Index] == Data then table.remove(Library.Registry, Index) break end
	end
	Library.RegistryMap[Obj] = nil
end

-- Remove an instance and all descendants from the registry, then destroy it
function Library:DestroyTree(Obj)
	for _, Descendant in ipairs(Obj:GetDescendants()) do Library:RemoveFromRegistry(Descendant) end
	Library:RemoveFromRegistry(Obj)
	Obj:Destroy()
end

function Library:SetThemeProp(Obj, Property, Value)
	local Data = Library.RegistryMap[Obj]
	if not Data then Data = Library:AddToRegistry(Obj, {}) end
	Data.Properties[Property] = Value
	Obj[Property] = ResolveColor(Value)
end

function Library:UpdateColorsUsingRegistry()
	Library:RefreshDerivedColors()
	for _, Data in ipairs(Library.Registry) do
		for Property, Value in pairs(Data.Properties) do
			Data.Instance[Property] = ResolveColor(Value)
		end
	end
end

local function New(Class, Props, Theme)
	local Obj = Library:Create(Class, Props)
	if Theme then Library:AddToRegistry(Obj, Theme) end
	return Obj
end

-- Frame with an inset 1px border
local function NewBox(Props, Theme)
	Props.BorderMode = Props.BorderMode or Enum.BorderMode.Inset
	Props.BorderSizePixel = Props.BorderSizePixel or 1
	return New('Frame', Props, Theme)
end

local function NewLabel(Props, Theme)
	Props.BackgroundTransparency = 1
	Props.BorderSizePixel = 0
	Props.Font = Props.Font or Library.Font
	Props.TextSize = Props.TextSize or Library.TextSize
	Props.TextStrokeTransparency = 0
	Props.TextXAlignment = Props.TextXAlignment or Enum.TextXAlignment.Left
	Props.TextYAlignment = Props.TextYAlignment or Enum.TextYAlignment.Center
	Theme = Theme or {}
	if Props.TextColor3 == nil and Theme.TextColor3 == nil then Theme.TextColor3 = 'FontColor' end
	return New('TextLabel', Props, Theme)
end

local function NewButton(Props, Theme)
	Props.BorderSizePixel = 0
	Props.AutoButtonColor = false
	Props.Font = Props.Font or Library.Font
	Props.TextSize = Props.TextSize or Library.TextSize
	Props.TextStrokeTransparency = 0
	Theme = Theme or {}
	if Props.TextColor3 == nil and Theme.TextColor3 == nil then Theme.TextColor3 = 'FontColor' end
	return New('TextButton', Props, Theme)
end

--// Misc helpers -------------------------------------------------------------------
function Library:GetTextBounds(Text, Font, Size, Resolution)
	local Bounds = TextService:GetTextSize(Text, Size, Font, Resolution or Vector2.new(1920, 1080))
	return Bounds.X, Bounds.Y
end

function Library:GiveSignal(Signal)
	table.insert(Library.Signals, Signal)
	return Signal
end

function Library:OnUnload(Callback)
	table.insert(Library.UnloadCallbacks, Callback)
end

function Library:SafeCallback(Func, ...)
	if type(Func) ~= 'function' then return end
	local Ok, Err = pcall(Func, ...)
	if not Ok then warn('[Library] callback error: ' .. tostring(Err)) end
end

function Library:IsMouseOverFrame(Frame)
	local Mouse = InputService:GetMouseLocation()
	local Pos, Size = Frame.AbsolutePosition, Frame.AbsoluteSize
	return Mouse.X >= Pos.X and Mouse.X <= Pos.X + Size.X and Mouse.Y >= Pos.Y and Mouse.Y <= Pos.Y + Size.Y
end

-- Drag helper: calls Update(MouseLocation) while the pointer is held on Obj
local function TrackDrag(Obj, Update)
	Obj.InputBegan:Connect(function(Input)
		if not IsPointer(Input) then return end
		Update(InputService:GetMouseLocation())
		local Stepped, Ended
		Stepped = RunService.RenderStepped:Connect(function()
			if Library.Unloaded then Stepped:Disconnect() Ended:Disconnect() return end
			Update(InputService:GetMouseLocation())
		end)
		Ended = InputService.InputEnded:Connect(function(EndInput)
			if IsPointer(EndInput) then
				Stepped:Disconnect()
				Ended:Disconnect()
			end
		end)
	end)
end

--// Popups (dropdown lists, color pickers, keybind mode menus) -------------------
function Library:RegisterPopup(Frame, Anchor, Hide)
	table.insert(Library.Popups, { Frame = Frame, Anchor = Anchor, Hide = Hide })
end

function Library:CloseAllPopups(Except)
	for _, Popup in ipairs(Library.Popups) do
		if Popup.Frame ~= Except and Popup.Frame.Visible then Popup.Hide() end
	end
end

function Library:IsAnyPopupOpen()
	for _, Popup in ipairs(Library.Popups) do
		if Popup.Frame.Visible then return true end
	end
	return false
end

-- Place a popup below (or above, if it would overflow) its anchor, clamped to the screen
function Library:PlacePopup(Popup, Anchor)
	local Screen = Library.ScreenGui.AbsoluteSize
	local APos, ASize = Anchor.AbsolutePosition, Anchor.AbsoluteSize
	local W, H = Popup.Size.X.Offset, Popup.Size.Y.Offset
	local X = Clamp(APos.X, 4, math.max(4, Screen.X - W - 4))
	local Y = APos.Y + ASize.Y + 2
	if Y + H > Screen.Y - 4 then Y = math.max(4, APos.Y - H - 2) end
	Popup.Position = UDim2.fromOffset(X, Y)
end

--// Root ScreenGui -----------------------------------------------------------------
local function MountGui(Gui)
	if syn and syn.protect_gui then pcall(syn.protect_gui, Gui) end
	local Targets = {}
	local OkHui, Hui = pcall(function() return gethui and gethui() end)
	if OkHui and Hui then table.insert(Targets, Hui) end
	table.insert(Targets, CoreGui)
	for _, Target in ipairs(Targets) do
		local Ok = pcall(function() Gui.Parent = Target end)
		if Ok and Gui.Parent == Target then return end
	end
	Gui.Parent = LocalPlayer:WaitForChild('PlayerGui')
end

local ScreenGui = Instance.new('ScreenGui')
ScreenGui.Name = 'KiciahookLibrary'
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.DisplayOrder = 999
MountGui(ScreenGui)
Library.ScreenGui = ScreenGui

-- Modal button: frees the mouse in first-person games while the menu is open
local ModalElement = Library:Create('TextButton', {
	BackgroundTransparency = 1, Size = UDim2.new(0, 0, 0, 0), Text = '', Modal = false, Parent = ScreenGui,
})

Library.NotificationArea = Library:Create('Frame', {
	BackgroundTransparency = 1, Position = UDim2.new(0, 8, 0, 40), Size = UDim2.new(0, 300, 0, 400),
	ZIndex = 200, Parent = ScreenGui,
})
Library:Create('UIListLayout', {
	Padding = UDim.new(0, 4), FillDirection = Enum.FillDirection.Vertical,
	SortOrder = Enum.SortOrder.LayoutOrder, Parent = Library.NotificationArea,
})

--// Visibility / unload -------------------------------------------------------------
function Library:SetVisible(Bool)
	Library.Toggled = Bool and true or false
	for _, Window in ipairs(Library.Windows) do Window.Outer.Visible = Library.Toggled end
	ModalElement.Modal = Library.Toggled
	if not Library.Toggled then Library:CloseAllPopups() end
end

function Library:Toggle()
	Library:SetVisible(not Library.Toggled)
end

function Library:Unload()
	if Library.Unloaded then return end
	Library.Unloaded = true
	for Index = #Library.Signals, 1, -1 do
		local Signal = table.remove(Library.Signals, Index)
		pcall(function() Signal:Disconnect() end)
	end
	for _, Callback in ipairs(Library.UnloadCallbacks) do pcall(Callback) end
	pcall(function() ModalElement.Modal = false end)
	pcall(function() ScreenGui:Destroy() end)
	if ENV.KiciahookLibrary == Library then ENV.KiciahookLibrary = nil end
end

-- Reset every control to the value it was created with (Ignore = list or set of idx)
function Library:ResetAll(Ignore)
	local Skip = {}
	for Key, Value in pairs(Ignore or {}) do
		if type(Key) == 'number' then Skip[Value] = true else Skip[Key] = Value and true or nil end
	end
	for Idx, Obj in pairs(Library.Toggles) do
		if not Skip[Idx] and Obj.Reset then Obj:Reset() end
	end
	for Idx, Obj in pairs(Library.Options) do
		if not Skip[Idx] and Obj.Reset then Obj:Reset() end
	end
end

local function Register(Idx, Obj)
	assert(type(Idx) == 'string' and Idx ~= '', 'Control identifier must be a non-empty string.')
	assert(Library.Toggles[Idx] == nil and Library.Options[Idx] == nil, 'Duplicate control identifier: ' .. Idx)
	if Obj.Type == 'Toggle' then Library.Toggles[Idx] = Obj else Library.Options[Idx] = Obj end
	Obj.Idx = Idx
end

--// Global input: click-away for popups + menu keybind -----------------------------
Library:GiveSignal(InputService.InputBegan:Connect(function(Input, Processed)
	if IsPointer(Input) then
		for _, Popup in ipairs(Library.Popups) do
			if Popup.Frame.Visible
				and not Library:IsMouseOverFrame(Popup.Frame)
				and not (Popup.Anchor and Library:IsMouseOverFrame(Popup.Anchor)) then
				Popup.Hide()
			end
		end
	end

	if Library.IsPicking or InputService:GetFocusedTextBox() then return end
	if Input.UserInputType ~= Enum.UserInputType.Keyboard then return end

	local Bind = Library.ToggleKeybind
	if type(Bind) == 'table' and Bind.Type == 'KeyPicker' then
		if Input.KeyCode.Name == Bind.Value then task.spawn(Library.Toggle, Library) end
	elseif Input.KeyCode == Enum.KeyCode.RightShift and not Processed then
		task.spawn(Library.Toggle, Library)
	end
	-- Emergency toggle so the menu can never be locked away
	if Input.KeyCode == Enum.KeyCode.RightControl then task.spawn(Library.Toggle, Library) end
end))

--// Window dragging ------------------------------------------------------------------
function Library:MakeDraggable(Handle, Target)
	Handle.InputBegan:Connect(function(Input)
		if not IsPointer(Input) then return end
		Library:CloseAllPopups()
		local Start = InputService:GetMouseLocation()
		local StartPos = Target.Position
		local Stepped, Ended
		Stepped = RunService.RenderStepped:Connect(function()
			if Library.Unloaded then Stepped:Disconnect() Ended:Disconnect() return end
			local Now = InputService:GetMouseLocation()
			Target.Position = UDim2.new(StartPos.X.Scale, StartPos.X.Offset + (Now.X - Start.X),
				StartPos.Y.Scale, StartPos.Y.Offset + (Now.Y - Start.Y))
		end)
		Ended = InputService.InputEnded:Connect(function(EndInput)
			if IsPointer(EndInput) then
				Stepped:Disconnect()
				Ended:Disconnect()
			end
		end)
	end)
end

--// Tooltip --------------------------------------------------------------------------
function Library:AddToolTip(InfoStr, HoverInstance)
	local X, Y = Library:GetTextBounds(InfoStr, Library.Font, Library.TextSize)
	local Tooltip = NewBox({
		BackgroundColor3 = Library.MainColor, BorderColor3 = Library.OutlineColor,
		Size = UDim2.fromOffset(X + 10, Y + 6), ZIndex = 300, Visible = false, Parent = Library.ScreenGui,
	}, { BackgroundColor3 = 'MainColor', BorderColor3 = 'OutlineColor' })
	NewLabel({ Position = UDim2.fromOffset(5, 3), Size = UDim2.new(1, -10, 1, -6), Text = InfoStr, Parent = Tooltip })

	local Hovering = false
	HoverInstance.MouseEnter:Connect(function()
		if Library:IsAnyPopupOpen() then return end
		Hovering = true
		Tooltip.Visible = true
		task.spawn(function()
			while Hovering and not Library.Unloaded do
				local Mouse = InputService:GetMouseLocation()
				Tooltip.Position = UDim2.fromOffset(Mouse.X + 14, Mouse.Y + 12)
				RunService.RenderStepped:Wait()
			end
		end)
	end)
	HoverInstance.MouseLeave:Connect(function()
		Hovering = false
		Tooltip.Visible = false
	end)
end

--// Notifications -----------------------------------------------------------------------
function Library:Notify(Text, Time)
	if Library.Unloaded then return end
	Time = Time or 5
	local XSize, YSize = Library:GetTextBounds(Text, Library.Font, Library.TextSize)
	YSize = YSize + 8

	local Outer = New('Frame', {
		BackgroundColor3 = Library.Black, BorderSizePixel = 0, ClipsDescendants = true,
		Size = UDim2.new(0, 0, 0, YSize), Parent = Library.NotificationArea,
	})
	local Inner = NewBox({
		BackgroundColor3 = Library.MainColor, BorderColor3 = Library.OutlineColor,
		Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 1, -2), Parent = Outer,
	}, { BackgroundColor3 = 'MainColor', BorderColor3 = 'OutlineColor' })
	New('Frame', {
		BackgroundColor3 = Library.AccentColor, BorderSizePixel = 0, Size = UDim2.new(0, 3, 1, 0), Parent = Inner,
	}, { BackgroundColor3 = 'AccentColor' })
	NewLabel({ Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -12, 1, 0), Text = Text, Parent = Inner })
	local Bar = New('Frame', {
		BackgroundColor3 = Library.AccentColor, BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 1, -2), Size = UDim2.new(1, 0, 0, 2), Parent = Inner,
	}, { BackgroundColor3 = 'AccentColor' })

	local InInfo = TweenInfo.new(0.35, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)
	TweenService:Create(Outer, InInfo, { Size = UDim2.new(0, XSize + 18, 0, YSize) }):Play()
	TweenService:Create(Bar, TweenInfo.new(Time, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 0, 2) }):Play()

	task.spawn(function()
		task.wait(Time)
		if Library.Unloaded then return end
		TweenService:Create(Outer, InInfo, { Size = UDim2.new(0, 0, 0, YSize) }):Play()
		task.wait(0.4)
		if Outer.Parent then Library:DestroyTree(Outer) end
	end)
end

--// Watermark ---------------------------------------------------------------------------
local function EnsureWatermark()
	if Library.Watermark then return Library.Watermark end
	local Outer = New('Frame', {
		BackgroundColor3 = Library.Black, BorderSizePixel = 0, Position = UDim2.fromOffset(10, 10),
		Size = UDim2.fromOffset(200, 22), Visible = false, Parent = Library.ScreenGui,
	})
	local Inner = NewBox({
		BackgroundColor3 = Library.MainColor, BorderColor3 = Library.OutlineColor,
		Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 1, -2), Parent = Outer,
	}, { BackgroundColor3 = 'MainColor', BorderColor3 = 'OutlineColor' })
	New('Frame', {
		BackgroundColor3 = Library.AccentColor, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 2), Parent = Inner,
	}, { BackgroundColor3 = 'AccentColor' })
	local Label = NewLabel({ Position = UDim2.fromOffset(6, 2), Size = UDim2.new(1, -12, 1, -2), Text = '', Parent = Inner })
	Library.Watermark = { Outer = Outer, Label = Label }
	return Library.Watermark
end

function Library:SetWatermark(Text)
	local Watermark = EnsureWatermark()
	local X = Library:GetTextBounds(Text, Library.Font, Library.TextSize)
	Watermark.Outer.Size = UDim2.fromOffset(X + 18, 22)
	Watermark.Label.Text = Text
end

function Library:SetWatermarkVisibility(Bool)
	EnsureWatermark().Outer.Visible = Bool and true or false
end

--// Add-on / groupbox method tables -------------------------------------------------------
local BaseAddons = {}
BaseAddons.__index = BaseAddons

local BaseGroupbox = {}
BaseGroupbox.__index = BaseGroupbox

local function NewRow(Groupbox, Height)
	Groupbox.RowCount = (Groupbox.RowCount or 0) + 1
	return New('Frame', {
		BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, Height),
		LayoutOrder = Groupbox.RowCount, Parent = Groupbox.Container,
	})
end

-- Right-aligned strip inside a toggle/label row (color pickers, keybinds)
local function GetRight(Obj)
	if Obj.RightContainer then return Obj.RightContainer end
	local Right = New('Frame', { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0), Parent = Obj.Row })
	local Layout = New('UIListLayout', {
		FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 4), Parent = Right,
	})
	Obj.RightContainer = Right
	Obj.RightCount = 0
	if Obj.Region then
		-- keep the toggle click area clear of the swatches
		Layout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			Obj.Region.Size = UDim2.new(1, -(Layout.AbsoluteContentSize.X + 6), 1, 0)
		end)
	end
	return Right
end

--// Label ------------------------------------------------------------------------------------
function BaseGroupbox:AddLabel(Text, DoesWrap)
	local Label = setmetatable({ Type = 'Label', Addons = {} }, BaseAddons)
	local Row = NewRow(self, 15)
	local TextLabel = NewLabel({
		Size = UDim2.new(1, 0, 1, 0), Text = Text, TextWrapped = DoesWrap and true or false, Parent = Row,
	})
	Label.Row, Label.TextLabel = Row, TextLabel

	local function Fit()
		if not DoesWrap then return end
		local Width = math.max(TextLabel.AbsoluteSize.X, 60)
		local _, Y = Library:GetTextBounds(TextLabel.Text, Library.Font, Library.TextSize, Vector2.new(Width, math.huge))
		Row.Size = UDim2.new(1, 0, 0, Y + 2)
	end
	if DoesWrap then
		TextLabel:GetPropertyChangedSignal('AbsoluteSize'):Connect(Fit)
		Fit()
	end

	function Label:SetText(NewText)
		TextLabel.Text = NewText
		Fit()
	end
	function Label:SetVisible(Bool) Row.Visible = Bool end
	return Label
end

--// Divider / blank -----------------------------------------------------------------------------
function BaseGroupbox:AddDivider()
	local Row = NewRow(self, 7)
	New('Frame', {
		BackgroundColor3 = Library.OutlineColor, BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(1, 0, 0, 1), Parent = Row,
	}, { BackgroundColor3 = 'OutlineColor' })
end

function BaseGroupbox:AddBlank(Height)
	NewRow(self, Height or 6)
end

--// Button ------------------------------------------------------------------------------------------
function BaseGroupbox:AddButton(...)
	local Row = NewRow(self, 20)
	local Buttons = {}

	local function Relayout()
		local N = #Buttons
		for Index, Button in ipairs(Buttons) do
			Button.Outer.Size = UDim2.new(1 / N, -(4 * (N - 1)) / N, 1, 0)
			Button.Outer.Position = UDim2.new((Index - 1) / N, 4 * (Index - 1) / N, 0, 0)
		end
	end

	local function Make(...)
		local Button = { Type = 'Button' }
		local First = select(1, ...)
		if type(First) == 'table' then
			Button.Text, Button.Func = First.Text, First.Func
			Button.DoubleClick, Button.Tooltip = First.DoubleClick, First.Tooltip
		else
			Button.Text, Button.Func = First, select(2, ...)
		end
		assert(type(Button.Func) == 'function', 'AddButton: `Func` callback is missing.')

		local Outer = New('Frame', { BackgroundColor3 = Library.Black, BorderSizePixel = 0, Parent = Row })
		local Inner = NewBox({
			BackgroundColor3 = Library.MainColor, BorderColor3 = Library.OutlineColor,
			Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 1, -2), Parent = Outer,
		}, { BackgroundColor3 = 'MainColor', BorderColor3 = 'OutlineColor' })
		local Label = NewLabel({
			Size = UDim2.new(1, 0, 1, 0), Text = Button.Text, TextXAlignment = Enum.TextXAlignment.Center, Parent = Inner,
		})
		Button.Outer, Button.Inner, Button.Label = Outer, Inner, Label

		Inner.MouseEnter:Connect(function() Library:SetThemeProp(Inner, 'BorderColor3', 'AccentColor') end)
		Inner.MouseLeave:Connect(function() Library:SetThemeProp(Inner, 'BorderColor3', 'OutlineColor') end)
		Inner.InputBegan:Connect(function(Input)
			if not IsPointer(Input) then return end
			if Button.DoubleClick then
				if Button.Armed then
					Button.Armed = false
					Label.Text = Button.Text
					Library:SafeCallback(Button.Func)
				else
					Button.Armed = true
					Button.ArmToken = (Button.ArmToken or 0) + 1
					local Token = Button.ArmToken
					Label.Text = 'Are you sure?'
					task.delay(1.5, function()
						if Button.Armed and Button.ArmToken == Token then
							Button.Armed = false
							Label.Text = Button.Text
						end
					end)
				end
			else
				Library:SafeCallback(Button.Func)
			end
		end)
		if type(Button.Tooltip) == 'string' then Library:AddToolTip(Button.Tooltip, Inner) end

		function Button:SetText(NewText)
			Button.Text = NewText
			Label.Text = NewText
		end
		function Button:AddButton(...) return Make(...) end

		table.insert(Buttons, Button)
		Relayout()
		return Button
	end

	return Make(...)
end

--// Toggle ---------------------------------------------------------------------------------------------
function BaseGroupbox:AddToggle(Idx, Info)
	assert(type(Info) == 'table', 'AddToggle: Info table missing.')
	local Toggle = setmetatable({
		Value = Info.Default and true or false,
		Default = Info.Default and true or false,
		Type = 'Toggle', Callback = Info.Callback, ChangedCallbacks = {}, Addons = {},
	}, BaseAddons)

	local Row = NewRow(self, 14)
	local Outer = New('Frame', {
		BackgroundColor3 = Library.Black, BorderSizePixel = 0, Size = UDim2.fromOffset(13, 13), Parent = Row,
	})
	local Inner = NewBox({
		BackgroundColor3 = Library.MainColor, BorderColor3 = Library.OutlineColor,
		Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 1, -2), Parent = Outer,
	}, { BackgroundColor3 = 'MainColor', BorderColor3 = 'OutlineColor' })
	local TextLabel = NewLabel({
		Position = UDim2.fromOffset(19, 0), Size = UDim2.new(1, -19, 1, 0), Text = Info.Text or '', Parent = Row,
	})
	local Region = New('Frame', { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0), Parent = Row })
	Toggle.Row, Toggle.TextLabel, Toggle.Region = Row, TextLabel, Region

	function Toggle:Display()
		Library:SetThemeProp(Inner, 'BackgroundColor3', Toggle.Value and 'AccentColor' or 'MainColor')
		Library:SetThemeProp(Inner, 'BorderColor3', Toggle.Value and 'AccentColorDark' or 'OutlineColor')
	end

	function Toggle:SetValue(Bool)
		Bool = Bool and true or false
		Toggle.Value = Bool
		Toggle:Display()
		for _, Addon in ipairs(Toggle.Addons) do
			if Addon.Type == 'KeyPicker' and Addon.SyncToggleState then
				Addon.Toggled = Bool
				Addon:Update()
			end
		end
		Library:SafeCallback(Toggle.Callback, Toggle.Value)
		for _, Func in ipairs(Toggle.ChangedCallbacks) do Library:SafeCallback(Func, Toggle.Value) end
	end

	function Toggle:OnChanged(Func)
		table.insert(Toggle.ChangedCallbacks, Func)
		Library:SafeCallback(Func, Toggle.Value)
	end
	function Toggle:Reset() Toggle:SetValue(Toggle.Default) end
	function Toggle:SetText(Text) TextLabel.Text = Text end
	function Toggle:SetVisible(Bool) Row.Visible = Bool end

	Region.InputBegan:Connect(function(Input)
		if IsPointer(Input) then Toggle:SetValue(not Toggle.Value) end
	end)
	Region.MouseEnter:Connect(function() Library:SetThemeProp(Inner, 'BorderColor3', 'AccentColor') end)
	Region.MouseLeave:Connect(function() Toggle:Display() end)
	if type(Info.Tooltip) == 'string' then Library:AddToolTip(Info.Tooltip, Region) end

	Toggle:Display()
	Register(Idx, Toggle)
	return Toggle
end

--// Color picker (Toggle / Label add-on) -----------------------------------------------------------------
function BaseAddons:AddColorPicker(Idx, Info)
	local ParentObj = self
	assert(type(Info) == 'table' and Info.Default ~= nil, 'AddColorPicker: Missing default value.')

	local Picker = {
		Value = Info.Default, Default = Info.Default,
		Transparency = Info.Transparency or 0, DefaultTransparency = Info.Transparency or 0,
		HasTransparency = Info.Transparency ~= nil, Type = 'ColorPicker',
		Title = type(Info.Title) == 'string' and Info.Title or 'Color picker',
		Callback = Info.Callback, ChangedCallbacks = {},
	}
	Picker.Hue, Picker.Sat, Picker.Vib = Color3.toHSV(Picker.Value)

	local Right = GetRight(ParentObj)
	ParentObj.RightCount = ParentObj.RightCount + 1
	local Display = NewBox({
		BackgroundColor3 = Picker.Value, BorderColor3 = Library.OutlineColor,
		LayoutOrder = ParentObj.RightCount, Size = UDim2.fromOffset(34, 12), Parent = Right,
	}, { BorderColor3 = 'OutlineColor' })

	--// popup
	local Popup = New('Frame', {
		BackgroundColor3 = Library.Black, BorderSizePixel = 0, Active = true, Visible = false, ZIndex = 100,
		Size = UDim2.fromOffset(230, Picker.HasTransparency and 271 or 253), Parent = Library.ScreenGui,
	})
	local Inner = NewBox({
		BackgroundColor3 = Library.MainColor, BorderColor3 = Library.OutlineColor,
		Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 1, -2), Parent = Popup,
	}, { BackgroundColor3 = 'MainColor', BorderColor3 = 'OutlineColor' })
	New('Frame', {
		BackgroundColor3 = Library.AccentColor, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 2), Parent = Inner,
	}, { BackgroundColor3 = 'AccentColor' })
	NewLabel({ Position = UDim2.fromOffset(5, 4), Size = UDim2.new(1, -10, 0, 14), Text = Picker.Title, Parent = Inner })

	-- saturation / value square (hue color + white + black gradient overlays)
	local SVOuter = New('Frame', {
		BackgroundColor3 = Library.Black, BorderSizePixel = 0,
		Position = UDim2.fromOffset(3, 21), Size = UDim2.fromOffset(202, 202), Parent = Inner,
	})
	local SVInner = New('Frame', {
		BackgroundColor3 = Color3.fromHSV(Picker.Hue, 1, 1), BorderSizePixel = 0,
		Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 1, -2), Parent = SVOuter,
	})
	local SatOverlay = New('Frame', {
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Size = UDim2.new(1, 0, 1, 0), Parent = SVInner,
	})
	New('UIGradient', {
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }),
		Parent = SatOverlay,
	})
	local ValOverlay = New('Frame', {
		BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, Size = UDim2.new(1, 0, 1, 0), Parent = SVInner,
	})
	New('UIGradient', {
		Rotation = 90,
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) }),
		Parent = ValOverlay,
	})
	local SVCursor = New('Frame', {
		AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.new(1, 1, 1),
		BorderColor3 = Library.Black, Size = UDim2.fromOffset(6, 6), Parent = SVInner,
	})

	-- hue bar
	local HueOuter = New('Frame', {
		BackgroundColor3 = Library.Black, BorderSizePixel = 0,
		Position = UDim2.fromOffset(209, 21), Size = UDim2.fromOffset(16, 202), Parent = Inner,
	})
	local HueInner = New('Frame', {
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
		Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 1, -2), Parent = HueOuter,
	})
	New('UIGradient', {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 0)),
			ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
			ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
			ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0, 255, 255)),
			ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
			ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
			ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 0)),
		}),
		Parent = HueInner,
	})
	local HueCursor = New('Frame', {
		AnchorPoint = Vector2.new(0, 0.5), BackgroundColor3 = Color3.new(1, 1, 1),
		BorderColor3 = Library.Black, Size = UDim2.new(1, 0, 0, 2), Parent = HueInner,
	})

	-- hex / rgb inputs
	local function MakeInput(X, Width)
		local Box = NewBox({
			BackgroundColor3 = Library.BackgroundColor, BorderColor3 = Library.OutlineColor,
			Position = UDim2.fromOffset(X, 227), Size = UDim2.fromOffset(Width, 20), Parent = Inner,
		}, { BackgroundColor3 = 'BackgroundColor', BorderColor3 = 'OutlineColor' })
		return New('TextBox', {
			BackgroundTransparency = 1, BorderSizePixel = 0, ClearTextOnFocus = false,
			Position = UDim2.fromOffset(4, 0), Size = UDim2.new(1, -8, 1, 0), Font = Library.Font,
			TextSize = Library.TextSize, TextXAlignment = Enum.TextXAlignment.Left, Text = '', Parent = Box,
		}, { TextColor3 = 'FontColor' })
	end
	local HexBox = MakeInput(3, 108)
	local RgbBox = MakeInput(115, 108)

	-- optional transparency bar
	local TransInner, TransCursor
	if Picker.HasTransparency then
		local TransOuter = New('Frame', {
			BackgroundColor3 = Library.Black, BorderSizePixel = 0,
			Position = UDim2.fromOffset(3, 251), Size = UDim2.fromOffset(222, 15), Parent = Inner,
		})
		TransInner = New('Frame', {
			BackgroundColor3 = Picker.Value, BorderSizePixel = 0,
			Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 1, -2), Parent = TransOuter,
		})
		New('UIGradient', {
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }),
			Parent = TransInner,
		})
		TransCursor = New('Frame', {
			AnchorPoint = Vector2.new(0.5, 0), BackgroundColor3 = Color3.new(1, 1, 1),
			BorderColor3 = Library.Black, Size = UDim2.new(0, 2, 1, 0), Parent = TransInner,
		})
		TrackDrag(TransOuter, function(Mouse)
			local Alpha = Clamp((Mouse.X - TransInner.AbsolutePosition.X) / math.max(TransInner.AbsoluteSize.X, 1), 0, 1)
			Picker.Transparency = Round(Alpha, 2)
			Picker:Display()
		end)
	end

	function Picker:Display(Silent)
		Picker.Value = Color3.fromHSV(Picker.Hue, Picker.Sat, Picker.Vib)
		Display.BackgroundColor3 = Picker.Value
		SVInner.BackgroundColor3 = Color3.fromHSV(Picker.Hue, 1, 1)
		SVCursor.Position = UDim2.new(Picker.Sat, 0, 1 - Picker.Vib, 0)
		HueCursor.Position = UDim2.new(0, 0, Picker.Hue, 0)
		HexBox.Text = '#' .. string.upper(ColorToHex(Picker.Value))
		RgbBox.Text = string.format('%d, %d, %d', math.floor(Picker.Value.R * 255 + 0.5),
			math.floor(Picker.Value.G * 255 + 0.5), math.floor(Picker.Value.B * 255 + 0.5))
		if TransInner then
			TransInner.BackgroundColor3 = Picker.Value
			TransCursor.Position = UDim2.new(Picker.Transparency, 0, 0, 0)
		end
		if not Silent then
			Library:SafeCallback(Picker.Callback, Picker.Value, Picker.Transparency)
			for _, Func in ipairs(Picker.ChangedCallbacks) do Library:SafeCallback(Func, Picker.Value, Picker.Transparency) end
		end
	end

	function Picker:SetValue(HSV, Transparency)
		Picker.Hue, Picker.Sat, Picker.Vib = HSV[1], HSV[2], HSV[3]
		Picker.Transparency = Transparency or 0
		Picker:Display()
	end
	function Picker:SetValueRGB(Color, Transparency)
		Picker.Hue, Picker.Sat, Picker.Vib = Color3.toHSV(Color)
		Picker.Transparency = Transparency or 0
		Picker:Display()
	end
	function Picker:OnChanged(Func)
		table.insert(Picker.ChangedCallbacks, Func)
		Library:SafeCallback(Func, Picker.Value, Picker.Transparency)
	end
	function Picker:Reset() Picker:SetValueRGB(Picker.Default, Picker.DefaultTransparency) end

	function Picker:Show()
		Library:CloseAllPopups(Popup)
		Library:PlacePopup(Popup, Display)
		Popup.Visible = true
	end
	function Picker:Hide() Popup.Visible = false end
	Library:RegisterPopup(Popup, Display, function() Picker:Hide() end)

	Display.InputBegan:Connect(function(Input)
		if IsPointer(Input) then
			if Popup.Visible then Picker:Hide() else Picker:Show() end
		end
	end)
	if type(Info.Tooltip) == 'string' then Library:AddToolTip(Info.Tooltip, Display) end

	TrackDrag(SVOuter, function(Mouse)
		local X = Clamp((Mouse.X - SVInner.AbsolutePosition.X) / math.max(SVInner.AbsoluteSize.X, 1), 0, 1)
		local Y = Clamp((Mouse.Y - SVInner.AbsolutePosition.Y) / math.max(SVInner.AbsoluteSize.Y, 1), 0, 1)
		Picker.Sat, Picker.Vib = X, 1 - Y
		Picker:Display()
	end)
	TrackDrag(HueOuter, function(Mouse)
		Picker.Hue = Clamp((Mouse.Y - HueInner.AbsolutePosition.Y) / math.max(HueInner.AbsoluteSize.Y, 1), 0, 1)
		Picker:Display()
	end)

	HexBox.FocusLost:Connect(function()
		local Color = HexToColor(HexBox.Text)
		if Color then Picker:SetValueRGB(Color, Picker.Transparency) else Picker:Display(true) end
	end)
	RgbBox.FocusLost:Connect(function()
		local R, G, B = string.match(RgbBox.Text, '(%d+)%D+(%d+)%D+(%d+)')
		if R and G and B then
			Picker:SetValueRGB(Color3.fromRGB(Clamp(tonumber(R), 0, 255), Clamp(tonumber(G), 0, 255),
				Clamp(tonumber(B), 0, 255)), Picker.Transparency)
		else
			Picker:Display(true)
		end
	end)

	Picker:Display(true)
	Register(Idx, Picker)
	table.insert(ParentObj.Addons, Picker)
	return self
end

--// Key picker (Toggle / Label add-on) -----------------------------------------------------------------------
function BaseAddons:AddKeyPicker(Idx, Info)
	local ParentObj = self
	Info = Info or {}
	local KeyPicker = {
		Value = Info.Default or 'None', Mode = Info.Mode or 'Toggle',
		DefaultKey = Info.Default or 'None', DefaultMode = Info.Mode or 'Toggle',
		Toggled = false, Picking = false, Type = 'KeyPicker',
		SyncToggleState = Info.SyncToggleState and ParentObj.Type == 'Toggle',
		Callback = Info.Callback, Clicked = nil, ChangedCallbacks = {},
		ChangedCallback = Info.ChangedCallback,
	}

	local Right = GetRight(ParentObj)
	ParentObj.RightCount = ParentObj.RightCount + 1
	local Display = NewBox({
		BackgroundColor3 = Library.MainColor, BorderColor3 = Library.OutlineColor,
		LayoutOrder = ParentObj.RightCount, Size = UDim2.fromOffset(44, 14), Parent = Right,
	}, { BackgroundColor3 = 'MainColor', BorderColor3 = 'OutlineColor' })
	local Label = NewLabel({
		Size = UDim2.new(1, 0, 1, 0), Text = '[None]', TextXAlignment = Enum.TextXAlignment.Center, Parent = Display,
	})

	--// mode menu (right click)
	local Modes = { 'Always', 'Toggle', 'Hold' }
	local Menu = NewBox({
		BackgroundColor3 = Library.MainColor, BorderColor3 = Library.OutlineColor, Visible = false, ZIndex = 100,
		Size = UDim2.fromOffset(64, #Modes * 18 + 2), Parent = Library.ScreenGui,
	}, { BackgroundColor3 = 'MainColor', BorderColor3 = 'OutlineColor' })
	local ModeButtons = {}
	for Index, Mode in ipairs(Modes) do
		local Button = NewButton({
			BackgroundTransparency = 1, Position = UDim2.fromOffset(1, 1 + (Index - 1) * 18),
			Size = UDim2.new(1, -2, 0, 18), Text = Mode, Parent = Menu,
		}, { TextColor3 = 'FontColor' })
		Button.MouseButton1Click:Connect(function()
			KeyPicker.Mode = Mode
			KeyPicker.Toggled = false
			KeyPicker:Update()
			Menu.Visible = false
			Library:SafeCallback(KeyPicker.ChangedCallback, Mode)
		end)
		ModeButtons[Mode] = Button
	end
	Library:RegisterPopup(Menu, Display, function() Menu.Visible = false end)

	function KeyPicker:GetState()
		if KeyPicker.Mode == 'Always' then return true end
		return KeyPicker.Toggled
	end

	function KeyPicker:Update()
		local Text = '[' .. tostring(KeyPicker.Value) .. ']'
		local X = Library:GetTextBounds(Text, Library.Font, Library.TextSize)
		Display.Size = UDim2.fromOffset(X + 10, 14)
		if not KeyPicker.Picking then Label.Text = Text end
		Library:SetThemeProp(Label, 'TextColor3', KeyPicker:GetState() and 'AccentColor' or 'FontColor')
		for Mode, Button in pairs(ModeButtons) do
			Library:SetThemeProp(Button, 'TextColor3', Mode == KeyPicker.Mode and 'AccentColor' or 'FontColor')
		end
	end

	function KeyPicker:DoClick()
		if ParentObj.Type == 'Toggle' and KeyPicker.SyncToggleState then ParentObj:SetValue(KeyPicker.Toggled) end
		Library:SafeCallback(KeyPicker.Callback, KeyPicker.Toggled)
		Library:SafeCallback(KeyPicker.Clicked, KeyPicker.Toggled)
		KeyPicker:Update()
	end

	function KeyPicker:SetValue(Data)
		KeyPicker.Value = Data[1] or 'None'
		KeyPicker.Mode = Data[2] or KeyPicker.Mode
		KeyPicker.Toggled = false
		KeyPicker:Update()
	end
	function KeyPicker:OnClick(Func) KeyPicker.Clicked = Func end
	function KeyPicker:OnChanged(Func)
		table.insert(KeyPicker.ChangedCallbacks, Func)
	end
	function KeyPicker:Reset() KeyPicker:SetValue({ KeyPicker.DefaultKey, KeyPicker.DefaultMode }) end

	local function InputName(Input)
		if Input.UserInputType == Enum.UserInputType.Keyboard then return Input.KeyCode.Name end
		if Input.UserInputType == Enum.UserInputType.MouseButton1 then return 'MB1' end
		if Input.UserInputType == Enum.UserInputType.MouseButton2 then return 'MB2' end
		if Input.UserInputType == Enum.UserInputType.MouseButton3 then return 'MB3' end
		return nil
	end

	Display.InputBegan:Connect(function(Input)
		if InputService:GetFocusedTextBox() then return end
		if Input.UserInputType == Enum.UserInputType.MouseButton1 and not KeyPicker.Picking then
			KeyPicker.Picking = true
			Library.IsPicking = true
			Label.Text = '...'
			Library:SetThemeProp(Label, 'TextColor3', 'AccentColor')
			task.spawn(function()
				task.wait(0.1) -- ignore the click that started the bind
				local Event
				Event = InputService.InputBegan:Connect(function(Pressed)
					local Key = InputName(Pressed)
					if not Key then return end
					if Key == 'Escape' then Key = 'None' end
					KeyPicker.Value = Key
					KeyPicker.Picking = false
					KeyPicker.Toggled = false
					KeyPicker:Update()
					Event:Disconnect()
					task.delay(0.05, function() Library.IsPicking = false end)
					Library:SafeCallback(KeyPicker.ChangedCallback, Key)
					for _, Func in ipairs(KeyPicker.ChangedCallbacks) do Library:SafeCallback(Func, Key) end
				end)
			end)
		elseif Input.UserInputType == Enum.UserInputType.MouseButton2 and not KeyPicker.Picking then
			Library:CloseAllPopups(Menu)
			Library:PlacePopup(Menu, Display)
			Menu.Visible = true
		end
	end)

	Library:GiveSignal(InputService.InputBegan:Connect(function(Input, Processed)
		if KeyPicker.Picking or InputService:GetFocusedTextBox() then return end
		if KeyPicker.Value == 'None' or InputName(Input) ~= KeyPicker.Value then return end
		if Processed and Input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		if KeyPicker.Mode == 'Toggle' then
			KeyPicker.Toggled = not KeyPicker.Toggled
			KeyPicker:DoClick()
		elseif KeyPicker.Mode == 'Hold' then
			KeyPicker.Toggled = true
			KeyPicker:DoClick()
		end
	end))
	Library:GiveSignal(InputService.InputEnded:Connect(function(Input)
		if KeyPicker.Mode == 'Hold' and KeyPicker.Value ~= 'None' and InputName(Input) == KeyPicker.Value then
			KeyPicker.Toggled = false
			KeyPicker:DoClick()
		end
	end))

	if type(Info.Tooltip) == 'string' then Library:AddToolTip(Info.Tooltip, Display) end

	KeyPicker:Update()
	Register(Idx, KeyPicker)
	table.insert(ParentObj.Addons, KeyPicker)
	return self
end

--// Slider ----------------------------------------------------------------------------------------------------------
function BaseGroupbox:AddSlider(Idx, Info)
	assert(type(Info) == 'table' and Info.Min ~= nil and Info.Max ~= nil, 'AddSlider: Missing min/max.')
	local Slider = {
		Min = Info.Min, Max = Info.Max, Rounding = Info.Rounding or 0, Suffix = Info.Suffix or '',
		HideMax = Info.HideMax, Type = 'Slider', Callback = Info.Callback, ChangedCallbacks = {},
	}
	Slider.Default = Clamp(Info.Default or Info.Min, Info.Min, Info.Max)
	Slider.Value = Round(Slider.Default, Slider.Rounding)
	Slider.Step = Info.Step or (1 / (10 ^ Slider.Rounding))

	local HasTitle = (not Info.Compact) and Info.Text ~= nil
	local Top = HasTitle and 16 or 0
	local Row = NewRow(self, Top + 14 + 3 + 8)
	if HasTitle then
		NewLabel({ Size = UDim2.new(1, 0, 0, 14), Text = Info.Text, Parent = Row })
	end
	local ValueLabel = NewLabel({ Position = UDim2.fromOffset(0, Top), Size = UDim2.new(1, -36, 0, 14), Parent = Row })

	local function StepButton(Text, XOffset, Direction)
		local Button = NewButton({
			BackgroundTransparency = 1, Position = UDim2.new(1, XOffset, 0, Top), Size = UDim2.fromOffset(16, 14),
			Text = Text, Parent = Row,
		}, { TextColor3 = 'FontColor' })
		local Held = false
		Button.MouseButton1Down:Connect(function()
			Held = true
			Slider:SetValue(Slider.Value + Direction * Slider.Step)
			task.spawn(function()
				task.wait(0.35)
				local Ticks = 0
				while Held and not Library.Unloaded do
					Ticks = Ticks + 1
					local Mult = (Ticks > 90 and 50) or (Ticks > 45 and 10) or (Ticks > 15 and 3) or 1
					Slider:SetValue(Slider.Value + Direction * Slider.Step * Mult)
					task.wait(0.04)
				end
			end)
		end)
		Button.MouseButton1Up:Connect(function() Held = false end)
		Button.MouseLeave:Connect(function() Held = false end)
		Library:GiveSignal(InputService.InputEnded:Connect(function(Input)
			if IsPointer(Input) then Held = false end
		end))
		return Button
	end
	StepButton('-', -32, -1)
	StepButton('+', -16, 1)

	local Bar = NewBox({
		BackgroundColor3 = Library.BackgroundColor, BorderColor3 = Library.OutlineColor,
		Position = UDim2.fromOffset(0, Top + 17), Size = UDim2.new(1, 0, 0, 8), Parent = Row,
	}, { BackgroundColor3 = 'BackgroundColor', BorderColor3 = 'OutlineColor' })
	local Fill = New('Frame', {
		BackgroundColor3 = Library.AccentColor, BorderSizePixel = 0, Size = UDim2.new(0, 0, 1, 0), Parent = Bar,
	}, { BackgroundColor3 = 'AccentColor' })

	function Slider:Display()
		local Text = tostring(Slider.Value) .. Slider.Suffix
		if not Slider.HideMax then Text = Text .. '/' .. tostring(Slider.Max) .. Slider.Suffix end
		ValueLabel.Text = Text
		local Range = Slider.Max - Slider.Min
		local Alpha = Range > 0 and (Slider.Value - Slider.Min) / Range or 0
		Fill.Size = UDim2.new(Clamp(Alpha, 0, 1), 0, 1, 0)
	end

	function Slider:SetValue(Num)
		Num = tonumber(Num)
		if not Num then return end
		Num = Round(Clamp(Num, Slider.Min, Slider.Max), Slider.Rounding)
		if Num == Slider.Value then return end
		Slider.Value = Num
		Slider:Display()
		Library:SafeCallback(Slider.Callback, Slider.Value)
		for _, Func in ipairs(Slider.ChangedCallbacks) do Library:SafeCallback(Func, Slider.Value) end
	end

	function Slider:OnChanged(Func)
		table.insert(Slider.ChangedCallbacks, Func)
		Library:SafeCallback(Func, Slider.Value)
	end
	function Slider:Reset() Slider:SetValue(Slider.Default) end
	function Slider:SetVisible(Bool) Row.Visible = Bool end

	TrackDrag(Bar, function(Mouse)
		local Alpha = Clamp((Mouse.X - Bar.AbsolutePosition.X) / math.max(Bar.AbsoluteSize.X, 1), 0, 1)
		Slider:SetValue(Slider.Min + (Slider.Max - Slider.Min) * Alpha)
	end)
	Bar.MouseEnter:Connect(function() Library:SetThemeProp(Bar, 'BorderColor3', 'AccentColor') end)
	Bar.MouseLeave:Connect(function() Library:SetThemeProp(Bar, 'BorderColor3', 'OutlineColor') end)
	if type(Info.Tooltip) == 'string' then Library:AddToolTip(Info.Tooltip, Bar) end

	Slider:Display()
	Register(Idx, Slider)
	return Slider
end

--// Dropdown -----------------------------------------------------------------------------------------------------------
function BaseGroupbox:AddDropdown(Idx, Info)
	assert(type(Info) == 'table' and type(Info.Values) == 'table', 'AddDropdown: Missing values list.')
	local Dropdown = {
		Values = Info.Values, Multi = Info.Multi and true or false, AllowNull = Info.AllowNull,
		Placeholder = Info.Placeholder or '--', Type = 'Dropdown',
		Callback = Info.Callback, ChangedCallbacks = {}, Entries = {},
	}

	-- initial value
	local Default = Info.Default
	if Dropdown.Multi then
		Dropdown.Value = {}
		if type(Default) == 'number' and Dropdown.Values[Default] ~= nil then
			Dropdown.Value[Dropdown.Values[Default]] = true
		elseif type(Default) == 'string' and IndexOf(Dropdown.Values, Default) then
			Dropdown.Value[Default] = true
		elseif type(Default) == 'table' then
			for Key, Item in pairs(Default) do
				if type(Key) == 'number' then
					if IndexOf(Dropdown.Values, Item) then Dropdown.Value[Item] = true end
				elseif Item and IndexOf(Dropdown.Values, Key) then
					Dropdown.Value[Key] = true
				end
			end
		end
	else
		if type(Default) == 'number' then
			Dropdown.Value = Dropdown.Values[Default]
		elseif type(Default) == 'string' and IndexOf(Dropdown.Values, Default) then
			Dropdown.Value = Default
		end
	end
	Dropdown.DefaultValue = CopyValue(Dropdown.Value)

	local HasTitle = (not Info.Compact) and Info.Text ~= nil
	local Row = NewRow(self, HasTitle and 36 or 20)
	if HasTitle then
		NewLabel({ Size = UDim2.new(1, 0, 0, 14), Text = Info.Text, Parent = Row })
	end
	local Box = NewBox({
		BackgroundColor3 = Library.MainColor, BorderColor3 = Library.OutlineColor,
		Position = UDim2.new(0, 0, 1, -20), Size = UDim2.new(1, 0, 0, 20), Parent = Row,
	}, { BackgroundColor3 = 'MainColor', BorderColor3 = 'OutlineColor' })
	local ValueLabel = NewLabel({
		Position = UDim2.fromOffset(5, 0), Size = UDim2.new(1, -24, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd, Parent = Box,
	})
	local Arrow = NewLabel({
		Position = UDim2.new(1, -18, 0, 0), Size = UDim2.fromOffset(14, 20), Text = '+',
		TextXAlignment = Enum.TextXAlignment.Center, Parent = Box,
	})

	local List = NewBox({
		BackgroundColor3 = Library.MainColor, BorderColor3 = Library.AccentColor, Visible = false, ZIndex = 100,
		Size = UDim2.fromOffset(150, 100), Parent = Library.ScreenGui,
	}, { BackgroundColor3 = 'MainColor', BorderColor3 = 'AccentColor' })
	local Scroller = New('ScrollingFrame', {
		BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 1, -2),
		CanvasSize = UDim2.new(0, 0, 0, 0), ScrollBarThickness = 3, TopImage = '', BottomImage = '',
		ScrollBarImageColor3 = Library.AccentColor, Parent = List,
	}, { ScrollBarImageColor3 = 'AccentColor' })
	New('UIListLayout', { SortOrder = Enum.SortOrder.LayoutOrder, Parent = Scroller })

	local function IsSelected(Value)
		if Dropdown.Multi then return Dropdown.Value[Value] and true or false end
		return Dropdown.Value == Value
	end

	function Dropdown:RefreshSelection()
		for _, Entry in ipairs(Dropdown.Entries) do
			Library:SetThemeProp(Entry.Button, 'TextColor3', IsSelected(Entry.Value) and 'AccentColor' or 'FontColor')
		end
	end

	function Dropdown:Display()
		local Text = ''
		if Dropdown.Multi then
			for _, Value in ipairs(Dropdown.Values) do
				if Dropdown.Value[Value] then Text = Text .. tostring(Value) .. ', ' end
			end
			Text = Text:sub(1, #Text - 2)
		else
			Text = Dropdown.Value ~= nil and tostring(Dropdown.Value) or ''
		end
		ValueLabel.Text = Text == '' and Dropdown.Placeholder or Text
		Dropdown:RefreshSelection()
	end

	local function Select(Value)
		if Dropdown.Multi then
			local Table = CopyValue(Dropdown.Value)
			if Table[Value] then Table[Value] = nil else Table[Value] = true end
			Dropdown:SetValue(Table)
		else
			if Dropdown.Value == Value then
				if Dropdown.AllowNull then Dropdown:SetValue(nil) end
			else
				Dropdown:SetValue(Value)
			end
			Dropdown:Close()
		end
	end

	function Dropdown:BuildList()
		for _, Entry in ipairs(Dropdown.Entries) do Library:DestroyTree(Entry.Button) end
		Dropdown.Entries = {}
		for Order, Value in ipairs(Dropdown.Values) do
			local Button = NewButton({
				BackgroundColor3 = Library.MainColor, LayoutOrder = Order, Size = UDim2.new(1, 0, 0, 20),
				Text = tostring(Value), TextXAlignment = Enum.TextXAlignment.Left, Parent = Scroller,
			}, { BackgroundColor3 = 'MainColor' })
			New('UIPadding', { PaddingLeft = UDim.new(0, 5), Parent = Button })
			Button.MouseEnter:Connect(function() Library:SetThemeProp(Button, 'BackgroundColor3', 'OutlineColor') end)
			Button.MouseLeave:Connect(function() Library:SetThemeProp(Button, 'BackgroundColor3', 'MainColor') end)
			Button.MouseButton1Click:Connect(function() Select(Value) end)
			table.insert(Dropdown.Entries, { Button = Button, Value = Value })
		end
		Scroller.CanvasSize = UDim2.fromOffset(0, #Dropdown.Values * 20)
		Dropdown:RefreshSelection()
	end

	function Dropdown:Open()
		Library:CloseAllPopups(List)
		List.Size = UDim2.fromOffset(Box.AbsoluteSize.X, math.min(#Dropdown.Values, 8) * 20 + 4)
		Library:PlacePopup(List, Box)
		List.Visible = true
		Arrow.Text = '-'
	end
	function Dropdown:Close()
		List.Visible = false
		Arrow.Text = '+'
	end
	Library:RegisterPopup(List, Box, function() Dropdown:Close() end)

	local function FireChanged()
		Library:SafeCallback(Dropdown.Callback, Dropdown.Value)
		for _, Func in ipairs(Dropdown.ChangedCallbacks) do Library:SafeCallback(Func, Dropdown.Value) end
	end

	function Dropdown:SetValue(Val)
		if Dropdown.Multi then
			local Table = {}
			for Key, Flag in pairs(Val or {}) do
				if Flag and IndexOf(Dropdown.Values, Key) then Table[Key] = true end
			end
			Dropdown.Value = Table
		else
			if Val == nil then
				Dropdown.Value = nil
			elseif IndexOf(Dropdown.Values, Val) then
				Dropdown.Value = Val
			end
		end
		Dropdown:Display()
		FireChanged()
	end

	function Dropdown:SetValues(NewValues)
		Dropdown.Values = NewValues
		if Dropdown.Multi then
			for Key in pairs(Dropdown.Value) do
				if not IndexOf(NewValues, Key) then Dropdown.Value[Key] = nil end
			end
		elseif Dropdown.Value ~= nil and not IndexOf(NewValues, Dropdown.Value) then
			Dropdown.Value = nil
		end
		Dropdown:BuildList()
		Dropdown:Display()
	end

	function Dropdown:OnChanged(Func)
		table.insert(Dropdown.ChangedCallbacks, Func)
		Library:SafeCallback(Func, Dropdown.Value)
	end
	function Dropdown:Reset() Dropdown:SetValue(CopyValue(Dropdown.DefaultValue)) end
	function Dropdown:SetVisible(Bool) Row.Visible = Bool end

	Box.InputBegan:Connect(function(Input)
		if IsPointer(Input) then
			if List.Visible then Dropdown:Close() else Dropdown:Open() end
		end
	end)
	Box.MouseEnter:Connect(function() Library:SetThemeProp(Box, 'BorderColor3', 'AccentColor') end)
	Box.MouseLeave:Connect(function() Library:SetThemeProp(Box, 'BorderColor3', 'OutlineColor') end)
	if type(Info.Tooltip) == 'string' then Library:AddToolTip(Info.Tooltip, Box) end

	Dropdown:BuildList()
	Dropdown:Display()
	Register(Idx, Dropdown)
	return Dropdown
end

--// Input (textbox) ---------------------------------------------------------------------------------------------------------------
function BaseGroupbox:AddInput(Idx, Info)
	assert(type(Info) == 'table', 'AddInput: Info table missing.')
	local Textbox = {
		Value = Info.Default or '', Default = Info.Default or '', Numeric = Info.Numeric,
		Finished = Info.Finished, Type = 'Input', Callback = Info.Callback, ChangedCallbacks = {},
	}
	local HasTitle = Info.Text ~= nil
	local Row = NewRow(self, HasTitle and 36 or 20)
	if HasTitle then
		NewLabel({ Size = UDim2.new(1, 0, 0, 14), Text = Info.Text, Parent = Row })
	end
	local Box = NewBox({
		BackgroundColor3 = Library.MainColor, BorderColor3 = Library.OutlineColor,
		Position = UDim2.new(0, 0, 1, -20), Size = UDim2.new(1, 0, 0, 20), Parent = Row,
	}, { BackgroundColor3 = 'MainColor', BorderColor3 = 'OutlineColor' })
	local Input = New('TextBox', {
		BackgroundTransparency = 1, BorderSizePixel = 0, ClearTextOnFocus = false, ClipsDescendants = true,
		Position = UDim2.fromOffset(5, 0), Size = UDim2.new(1, -10, 1, 0), Font = Library.Font,
		TextSize = Library.TextSize, TextXAlignment = Enum.TextXAlignment.Left, Text = Textbox.Value,
		PlaceholderText = Info.Placeholder or '', PlaceholderColor3 = Color3.fromRGB(120, 120, 120),
		TextStrokeTransparency = 0, Parent = Box,
	}, { TextColor3 = 'FontColor' })

	function Textbox:SetValue(Text)
		Text = tostring(Text or '')
		if Info.MaxLength and #Text > Info.MaxLength then Text = Text:sub(1, Info.MaxLength) end
		if Textbox.Numeric and Text ~= '' and not tonumber(Text) then Text = Textbox.Value end
		Textbox.Value = Text
		Input.Text = Text
		Library:SafeCallback(Textbox.Callback, Textbox.Value)
		for _, Func in ipairs(Textbox.ChangedCallbacks) do Library:SafeCallback(Func, Textbox.Value) end
	end
	function Textbox:OnChanged(Func)
		table.insert(Textbox.ChangedCallbacks, Func)
		Library:SafeCallback(Func, Textbox.Value)
	end
	function Textbox:Reset() Textbox:SetValue(Textbox.Default) end
	function Textbox:SetVisible(Bool) Row.Visible = Bool end

	if Textbox.Finished then
		Input.FocusLost:Connect(function(EnterPressed)
			if EnterPressed then Textbox:SetValue(Input.Text) end
		end)
	else
		Input:GetPropertyChangedSignal('Text'):Connect(function()
			if Input.Text ~= Textbox.Value then Textbox:SetValue(Input.Text) end
		end)
	end
	Input.Focused:Connect(function() Library:SetThemeProp(Box, 'BorderColor3', 'AccentColor') end)
	Input.FocusLost:Connect(function() Library:SetThemeProp(Box, 'BorderColor3', 'OutlineColor') end)
	if type(Info.Tooltip) == 'string' then Library:AddToolTip(Info.Tooltip, Box) end

	Register(Idx, Textbox)
	return Textbox
end

--// Containers: tab strip, groupbox, tabbox, page, window -----------------------------------------------------
local function CreateTabStrip(Parent, Position, Size)
	local Strip = { Entries = {} }
	local Frame = New('Frame', { BackgroundTransparency = 1, Position = Position, Size = Size, Parent = Parent })
	New('UIListLayout', {
		FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 2), Parent = Frame,
	})

	function Strip:Relayout()
		local N = #Strip.Entries
		for _, Entry in ipairs(Strip.Entries) do
			Entry.Button.Size = UDim2.new(1 / N, -(2 * (N - 1)) / N, 1, 0)
		end
	end

	function Strip:Add(Name, OnClick)
		local Entry = { Name = Name }
		local Button = NewBox({
			BackgroundColor3 = Library.BackgroundColor, BorderColor3 = Library.OutlineColor,
			LayoutOrder = #Strip.Entries + 1, Size = UDim2.new(1, 0, 1, 0), Parent = Frame,
		}, { BackgroundColor3 = 'BackgroundColor', BorderColor3 = 'OutlineColor' })
		local Label = NewLabel({
			Size = UDim2.new(1, 0, 1, 0), Text = Name, TextXAlignment = Enum.TextXAlignment.Center, Parent = Button,
		}, { TextColor3 = 'DimFontColor' })
		local Accent = New('Frame', {
			BackgroundColor3 = Library.AccentColor, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 2),
			Visible = false, Parent = Button,
		}, { BackgroundColor3 = 'AccentColor' })
		Button.InputBegan:Connect(function(Input)
			if IsPointer(Input) then OnClick() end
		end)
		function Entry:SetActive(Active)
			Library:SetThemeProp(Button, 'BackgroundColor3', Active and 'MainColor' or 'BackgroundColor')
			Library:SetThemeProp(Label, 'TextColor3', Active and 'FontColor' or 'DimFontColor')
			Accent.Visible = Active
		end
		Entry.Button = Button
		table.insert(Strip.Entries, Entry)
		Strip:Relayout()
		return Entry
	end

	return Strip
end

-- Shared frame for groupboxes and tabbox tabs: accent line on top, list-layout container
local function CreateBoxFrame(Side)
	local Outer = NewBox({
		BackgroundColor3 = Library.BackgroundColor, BorderColor3 = Library.OutlineColor,
		Size = UDim2.new(1, -4, 0, 40), Parent = Side,
	}, { BackgroundColor3 = 'BackgroundColor', BorderColor3 = 'OutlineColor' })
	local Inner = NewBox({
		BackgroundColor3 = Library.BackgroundColor, BorderColor3 = Library.Black,
		Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 1, -2), Parent = Outer,
	}, { BackgroundColor3 = 'BackgroundColor' })
	New('Frame', {
		BackgroundColor3 = Library.AccentColor, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 2), Parent = Inner,
	}, { BackgroundColor3 = 'AccentColor' })
	return Outer, Inner
end

local function CreateContainer(Parent, Position, Size)
	local Container = New('Frame', { BackgroundTransparency = 1, Position = Position, Size = Size, Parent = Parent })
	local Layout = New('UIListLayout', {
		FillDirection = Enum.FillDirection.Vertical, SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 4), Parent = Container,
	})
	return Container, Layout
end

local function CreateGroupbox(Side, Name)
	local Groupbox = setmetatable({ Name = Name }, BaseGroupbox)
	local Outer, Inner = CreateBoxFrame(Side)
	NewLabel({ Position = UDim2.fromOffset(4, 2), Size = UDim2.new(1, -8, 0, 18), Text = Name, Parent = Inner })
	local Container, Layout = CreateContainer(Inner, UDim2.fromOffset(4, 22), UDim2.new(1, -8, 1, -22))
	Groupbox.Container, Groupbox.Outer = Container, Outer

	function Groupbox:Resize()
		Outer.Size = UDim2.new(1, -4, 0, 22 + Layout.AbsoluteContentSize.Y + 8)
	end
	Layout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function() Groupbox:Resize() end)
	Groupbox:Resize()
	return Groupbox
end

local function CreateTabbox(Side)
	local Tabbox = { Tabs = {} }
	local Outer, Inner = CreateBoxFrame(Side)
	local Strip = CreateTabStrip(Inner, UDim2.fromOffset(2, 3), UDim2.new(1, -4, 0, 18))

	function Tabbox:AddTab(Name)
		local Tab = setmetatable({ Name = Name }, BaseGroupbox)
		local Entry = Strip:Add(Name, function() Tab:Show() end)
		local Container, Layout = CreateContainer(Inner, UDim2.fromOffset(4, 26), UDim2.new(1, -8, 1, -26))
		Container.Visible = false
		Tab.Container = Container

		function Tab:Resize()
			if Tabbox.ActiveTab == Tab then
				Outer.Size = UDim2.new(1, -4, 0, 26 + Layout.AbsoluteContentSize.Y + 8)
			end
		end
		function Tab:Show()
			for _, Other in ipairs(Tabbox.Tabs) do Other:Hide() end
			Container.Visible = true
			Entry:SetActive(true)
			Tabbox.ActiveTab = Tab
			Tab:Resize()
			Library:CloseAllPopups()
		end
		function Tab:Hide()
			Container.Visible = false
			Entry:SetActive(false)
		end
		Layout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function() Tab:Resize() end)

		table.insert(Tabbox.Tabs, Tab)
		if #Tabbox.Tabs == 1 then Tab:Show() else Entry:SetActive(false) end
		return Tab
	end

	return Tabbox
end

-- A page = two scrolling columns of groupboxes
local function CreatePage(Parent)
	local Page = {}
	local Frame = New('Frame', { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0), Visible = false, Parent = Parent })
	Page.Frame = Frame

	local function CreateSide(Position, Size)
		local Side = New('ScrollingFrame', {
			BackgroundTransparency = 1, BorderSizePixel = 0, Position = Position, Size = Size,
			CanvasSize = UDim2.new(0, 0, 0, 0), ScrollBarThickness = 3, TopImage = '', BottomImage = '',
			ScrollBarImageColor3 = Library.AccentColor, Parent = Frame,
		}, { ScrollBarImageColor3 = 'AccentColor' })
		local Layout = New('UIListLayout', {
			Padding = UDim.new(0, 8), FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Parent = Side,
		})
		Layout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			Side.CanvasSize = UDim2.fromOffset(0, Layout.AbsoluteContentSize.Y + 4)
		end)
		Side:GetPropertyChangedSignal('CanvasPosition'):Connect(function() Library:CloseAllPopups() end)
		return Side
	end

	Page.LeftSide = CreateSide(UDim2.fromOffset(6, 6), UDim2.new(0.5, -9, 1, -12))
	Page.RightSide = CreateSide(UDim2.new(0.5, 3, 0, 6), UDim2.new(0.5, -9, 1, -12))

	function Page:AddLeftGroupbox(Name) return CreateGroupbox(Page.LeftSide, Name) end
	function Page:AddRightGroupbox(Name) return CreateGroupbox(Page.RightSide, Name) end
	function Page:AddLeftTabbox() return CreateTabbox(Page.LeftSide) end
	function Page:AddRightTabbox() return CreateTabbox(Page.RightSide) end
	return Page
end

--// Window ----------------------------------------------------------------------------------------------------------
function Library:CreateWindow(Config)
	if type(Config) == 'string' then Config = { Title = Config } end
	Config = Config or {}
	Config.Title = Config.Title or 'Window'
	Config.Size = Config.Size or UDim2.fromOffset(600, 620)

	local Window = { Tabs = {} }
	local Outer = New('Frame', {
		Name = 'Window', BackgroundColor3 = Library.Black, BorderSizePixel = 0, Active = true,
		Size = Config.Size, Visible = false, Parent = Library.ScreenGui,
	})
	if Config.Center then
		Outer.AnchorPoint = Vector2.new(0.5, 0.5)
		Outer.Position = UDim2.new(0.5, 0, 0.5, 0)
	else
		Outer.Position = Config.Position or UDim2.fromOffset(175, 50)
	end

	local Inner = NewBox({
		BackgroundColor3 = Library.MainColor, BorderColor3 = Library.AccentColor,
		Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 1, -2), Parent = Outer,
	}, { BackgroundColor3 = 'MainColor', BorderColor3 = 'AccentColor' })

	local TitleLabel = NewLabel({
		Position = UDim2.fromOffset(7, 0), Size = UDim2.new(1, -14, 0, 25), Text = Config.Title, Parent = Inner,
	})
	local Handle = New('Frame', { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 25), Parent = Inner })
	Library:MakeDraggable(Handle, Outer)

	local Section = NewBox({
		BackgroundColor3 = Library.BackgroundColor, BorderColor3 = Library.OutlineColor,
		Position = UDim2.fromOffset(8, 25), Size = UDim2.new(1, -16, 1, -33), Parent = Inner,
	}, { BackgroundColor3 = 'BackgroundColor', BorderColor3 = 'OutlineColor' })

	local Strip = CreateTabStrip(Section, UDim2.fromOffset(8, 8), UDim2.new(1, -16, 0, 22))
	local TabContainer = NewBox({
		BackgroundColor3 = Library.MainColor, BorderColor3 = Library.OutlineColor,
		Position = UDim2.fromOffset(8, 34), Size = UDim2.new(1, -16, 1, -42), Parent = Section,
	}, { BackgroundColor3 = 'MainColor', BorderColor3 = 'OutlineColor' })

	Window.Outer = Outer

	function Window:SetWindowTitle(Title) TitleLabel.Text = Title end

	function Window:AddTab(Name)
		local Tab = { Name = Name, SubTabs = {} }
		local Entry = Strip:Add(Name, function() Tab:Show() end)
		local Container = New('Frame', {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0), Visible = false, Parent = TabContainer,
		})
		Tab.Container = Container

		function Tab:Show()
			for _, Other in ipairs(Window.Tabs) do Other:Hide() end
			Container.Visible = true
			Entry:SetActive(true)
			Window.ActiveTab = Tab
			Library:CloseAllPopups()
		end
		function Tab:Hide()
			Container.Visible = false
			Entry:SetActive(false)
		end

		local function GetPage()
			assert(not Tab.SubStrip, 'This tab uses sub tabs - add groupboxes to a sub tab instead.')
			if not Tab.Page then
				Tab.Page = CreatePage(Container)
				Tab.Page.Frame.Visible = true
			end
			return Tab.Page
		end
		function Tab:AddLeftGroupbox(GroupName) return GetPage():AddLeftGroupbox(GroupName) end
		function Tab:AddRightGroupbox(GroupName) return GetPage():AddRightGroupbox(GroupName) end
		function Tab:AddLeftTabbox() return GetPage():AddLeftTabbox() end
		function Tab:AddRightTabbox() return GetPage():AddRightTabbox() end

		-- Nested tab strip (Visuals -> ESP / Overrides / World / Player)
		function Tab:AddSubTab(SubName)
			assert(not Tab.Page, 'This tab already has groupboxes - sub tabs must be added first.')
			if not Tab.SubStrip then
				Tab.SubStrip = CreateTabStrip(Container, UDim2.fromOffset(6, 6), UDim2.new(1, -12, 0, 22))
				Tab.PageArea = New('Frame', {
					BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 32), Size = UDim2.new(1, 0, 1, -32), Parent = Container,
				})
			end
			local SubTab = CreatePage(Tab.PageArea)
			SubTab.Name = SubName
			local SubEntry = Tab.SubStrip:Add(SubName, function() SubTab:Show() end)
			function SubTab:Show()
				for _, Other in ipairs(Tab.SubTabs) do Other:Hide() end
				SubTab.Frame.Visible = true
				SubEntry:SetActive(true)
				Library:CloseAllPopups()
			end
			function SubTab:Hide()
				SubTab.Frame.Visible = false
				SubEntry:SetActive(false)
			end
			table.insert(Tab.SubTabs, SubTab)
			if #Tab.SubTabs == 1 then SubTab:Show() else SubEntry:SetActive(false) end
			return SubTab
		end

		table.insert(Window.Tabs, Tab)
		if #Window.Tabs == 1 then Tab:Show() else Entry:SetActive(false) end
		return Tab
	end

	table.insert(Library.Windows, Window)
	if Config.AutoShow then Library:SetVisible(true) end
	return Window
end

--// ThemeManager -----------------------------------------------------------------------------------------------------
local ThemeManager = {}
do
	ThemeManager.Folder = 'KiciahookSettings'
	ThemeManager.Library = Library
	ThemeManager.Memory = {} -- fallback store when disk functions are unavailable
	ThemeManager.BuiltInThemes = {
		['Kiciahook'] = { 1, { FontColor = 'ffffff', MainColor = '1c1c1c', AccentColor = '6460d2', BackgroundColor = '141414', OutlineColor = '323232' } },
		['Default'] = { 2, { FontColor = 'ffffff', MainColor = '1c1c1c', AccentColor = '0055ff', BackgroundColor = '141414', OutlineColor = '323232' } },
		['BBot'] = { 3, { FontColor = 'ffffff', MainColor = '1e1e1e', AccentColor = '7e48a3', BackgroundColor = '232323', OutlineColor = '141414' } },
		['Fatality'] = { 4, { FontColor = 'ffffff', MainColor = '1e1842', AccentColor = 'c50754', BackgroundColor = '191335', OutlineColor = '3c355d' } },
		['Jester'] = { 5, { FontColor = 'ffffff', MainColor = '242424', AccentColor = 'db4467', BackgroundColor = '1c1c1c', OutlineColor = '373737' } },
		['Mint'] = { 6, { FontColor = 'ffffff', MainColor = '242424', AccentColor = '3db488', BackgroundColor = '1c1c1c', OutlineColor = '373737' } },
		['Tokyo Night'] = { 7, { FontColor = 'ffffff', MainColor = '191925', AccentColor = '6759b3', BackgroundColor = '16161f', OutlineColor = '323232' } },
		['Ubuntu'] = { 8, { FontColor = 'ffffff', MainColor = '3e3e3e', AccentColor = 'e2581e', BackgroundColor = '323232', OutlineColor = '191919' } },
		['Quartz'] = { 9, { FontColor = 'ffffff', MainColor = '232330', AccentColor = '426e87', BackgroundColor = '1d1b26', OutlineColor = '27232f' } },
	}
	local Fields = { 'FontColor', 'MainColor', 'AccentColor', 'BackgroundColor', 'OutlineColor' }

	local HasFS = type(writefile) == 'function' and type(readfile) == 'function' and type(isfile) == 'function'
		and type(isfolder) == 'function' and type(makefolder) == 'function' and type(listfiles) == 'function'

	local function BuildPath(Path)
		if not HasFS then return end
		local Current = ''
		for Part in string.gmatch(Path, '[^/]+') do
			Current = Current == '' and Part or (Current .. '/' .. Part)
			if not isfolder(Current) then pcall(makefolder, Current) end
		end
	end

	function ThemeManager:SetLibrary(Lib) self.Library = Lib end
	function ThemeManager:BuildFolderTree()
		BuildPath(self.Folder)
		BuildPath(self.Folder .. '/themes')
	end
	function ThemeManager:SetFolder(Folder)
		self.Folder = Folder
		self:BuildFolderTree()
	end

	function ThemeManager:ThemeUpdate()
		local Options = Library.Options
		for _, Field in ipairs(Fields) do
			if Options[Field] then Library[Field] = Options[Field].Value end
		end
		Library:UpdateColorsUsingRegistry()
	end

	function ThemeManager:ReloadCustomThemes()
		local Out = {}
		if HasFS then
			local Ok, List = pcall(listfiles, self.Folder .. '/themes')
			if Ok then
				for _, File in ipairs(List) do
					local Name = string.match(File, '([^/\\]+)%.json$')
					if Name then table.insert(Out, Name) end
				end
			end
		else
			for Name in pairs(self.Memory) do
				if string.sub(Name, 1, 1) ~= '_' then table.insert(Out, Name) end
			end
		end
		table.sort(Out)
		return Out
	end

	function ThemeManager:GetCustomTheme(Name)
		local Raw
		if HasFS then
			local Path = self.Folder .. '/themes/' .. Name .. '.json'
			if not isfile(Path) then return nil end
			local Ok, Data = pcall(readfile, Path)
			if not Ok then return nil end
			Raw = Data
		else
			Raw = self.Memory[Name]
		end
		if not Raw then return nil end
		local Ok, Decoded = pcall(HttpService.JSONDecode, HttpService, Raw)
		if Ok and type(Decoded) == 'table' then return Decoded end
		return nil
	end

	function ThemeManager:ApplyTheme(Theme)
		local Scheme
		local Built = self.BuiltInThemes[Theme]
		if Built then Scheme = Built[2] else Scheme = self:GetCustomTheme(Theme) end
		if not Scheme then return end
		for Field, Hex in pairs(Scheme) do
			local Color = HexToColor(Hex)
			if Color then
				Library[Field] = Color
				if Library.Options[Field] then Library.Options[Field]:SetValueRGB(Color) end
			end
		end
		self:ThemeUpdate()
	end

	function ThemeManager:SaveCustomTheme(Name)
		if string.gsub(Name or '', ' ', '') == '' then return false, 'Invalid theme name (empty)' end
		local Scheme = {}
		for _, Field in ipairs(Fields) do Scheme[Field] = ColorToHex(Library.Options[Field].Value) end
		local Ok, Encoded = pcall(HttpService.JSONEncode, HttpService, Scheme)
		if not Ok then return false, 'Failed to encode theme' end
		if HasFS then
			local WriteOk, Err = pcall(writefile, self.Folder .. '/themes/' .. Name .. '.json', Encoded)
			if not WriteOk then return false, tostring(Err) end
		else
			self.Memory[Name] = Encoded
		end
		return true
	end

	function ThemeManager:SaveDefault(Theme)
		if HasFS then
			pcall(writefile, self.Folder .. '/themes/default.txt', Theme)
		else
			self.Memory._default = Theme
		end
	end

	function ThemeManager:GetDefault()
		if HasFS then
			local Path = self.Folder .. '/themes/default.txt'
			if isfile(Path) then
				local Ok, Data = pcall(readfile, Path)
				if Ok and Data ~= '' then return Data end
			end
			return nil
		end
		return self.Memory._default
	end

	function ThemeManager:LoadDefault()
		local Theme = self:GetDefault() or 'Kiciahook'
		if not (self.BuiltInThemes[Theme] or self:GetCustomTheme(Theme)) then Theme = 'Kiciahook' end
		if self.BuiltInThemes[Theme] and Library.Options.ThemeManager_ThemeList then
			Library.Options.ThemeManager_ThemeList:SetValue(Theme)
		else
			self:ApplyTheme(Theme)
		end
	end

	function ThemeManager:ApplyToGroupbox(Groupbox)
		assert(Library, 'ThemeManager: Library not set.')
		local Options = Library.Options

		Groupbox:AddLabel('Background color'):AddColorPicker('BackgroundColor', { Default = Library.BackgroundColor, Title = 'Background color' })
		Groupbox:AddLabel('Main color'):AddColorPicker('MainColor', { Default = Library.MainColor, Title = 'Main color' })
		Groupbox:AddLabel('Accent color'):AddColorPicker('AccentColor', { Default = Library.AccentColor, Title = 'Accent color' })
		Groupbox:AddLabel('Outline color'):AddColorPicker('OutlineColor', { Default = Library.OutlineColor, Title = 'Outline color' })
		Groupbox:AddLabel('Font color'):AddColorPicker('FontColor', { Default = Library.FontColor, Title = 'Font color' })

		local Names = {}
		for Name in pairs(self.BuiltInThemes) do table.insert(Names, Name) end
		table.sort(Names, function(A, B) return self.BuiltInThemes[A][1] < self.BuiltInThemes[B][1] end)

		Groupbox:AddDivider()
		Groupbox:AddDropdown('ThemeManager_ThemeList', { Text = 'Theme list', Values = Names, Default = 1 })
		Groupbox:AddButton('Set as default', function()
			self:SaveDefault(Options.ThemeManager_ThemeList.Value)
			Library:Notify(string.format('Set default theme to %q', tostring(Options.ThemeManager_ThemeList.Value)))
		end)
		Options.ThemeManager_ThemeList:OnChanged(function()
			if Options.ThemeManager_ThemeList.Value then self:ApplyTheme(Options.ThemeManager_ThemeList.Value) end
		end)

		Groupbox:AddDivider()
		Groupbox:AddInput('ThemeManager_CustomThemeName', { Text = 'Custom theme name' })
		Groupbox:AddDropdown('ThemeManager_CustomThemeList', { Text = 'Custom themes', Values = self:ReloadCustomThemes(), AllowNull = true })
		Groupbox:AddDivider()
		Groupbox:AddButton('Save theme', function()
			local Ok, Err = self:SaveCustomTheme(Options.ThemeManager_CustomThemeName.Value)
			if not Ok then return Library:Notify('Failed to save theme: ' .. tostring(Err)) end
			Library:Notify(string.format('Saved theme %q', Options.ThemeManager_CustomThemeName.Value))
			Options.ThemeManager_CustomThemeList:SetValues(self:ReloadCustomThemes())
			Options.ThemeManager_CustomThemeList:SetValue(nil)
		end):AddButton('Load theme', function()
			local Name = Options.ThemeManager_CustomThemeList.Value
			if not Name then return Library:Notify('Pick a custom theme first') end
			self:ApplyTheme(Name)
			Library:Notify(string.format('Loaded theme %q', Name))
		end)
		Groupbox:AddButton('Refresh list', function()
			Options.ThemeManager_CustomThemeList:SetValues(self:ReloadCustomThemes())
			Options.ThemeManager_CustomThemeList:SetValue(nil)
		end)
		Groupbox:AddButton('Set as default (custom)', function()
			local Name = Options.ThemeManager_CustomThemeList.Value
			if not Name then return Library:Notify('Pick a custom theme first') end
			self:SaveDefault(Name)
			Library:Notify(string.format('Set default theme to %q', Name))
		end)

		for _, Field in ipairs(Fields) do
			Options[Field]:OnChanged(function() self:ThemeUpdate() end)
		end
		self:LoadDefault()
	end

	function ThemeManager:ApplyToTab(Tab)
		assert(Tab, 'ThemeManager:ApplyToTab: Tab missing.')
		self:ApplyToGroupbox(Tab:AddLeftGroupbox('Theme'))
	end
end

--// SaveManager --------------------------------------------------------------------------------------------------------
local SaveManager = {}
do
	SaveManager.Folder = 'KiciahookSettings'
	SaveManager.Ignore = {}
	SaveManager.Library = Library
	SaveManager.Memory = {} -- fallback store when disk functions are unavailable

	local HasFS = type(writefile) == 'function' and type(readfile) == 'function' and type(isfile) == 'function'
		and type(isfolder) == 'function' and type(makefolder) == 'function' and type(listfiles) == 'function'
	SaveManager.HasDisk = HasFS

	SaveManager.Parser = {
		Toggle = {
			Save = function(Idx, Obj) return { type = 'Toggle', idx = Idx, value = Obj.Value } end,
			Load = function(Idx, Data)
				if Library.Toggles[Idx] then Library.Toggles[Idx]:SetValue(Data.value) end
			end,
		},
		Slider = {
			Save = function(Idx, Obj) return { type = 'Slider', idx = Idx, value = tostring(Obj.Value) } end,
			Load = function(Idx, Data)
				if Library.Options[Idx] then Library.Options[Idx]:SetValue(Data.value) end
			end,
		},
		Dropdown = {
			Save = function(Idx, Obj) return { type = 'Dropdown', idx = Idx, value = Obj.Value, multi = Obj.Multi } end,
			Load = function(Idx, Data)
				if Library.Options[Idx] then Library.Options[Idx]:SetValue(Data.value) end
			end,
		},
		ColorPicker = {
			Save = function(Idx, Obj)
				return { type = 'ColorPicker', idx = Idx, value = ColorToHex(Obj.Value), transparency = Obj.Transparency }
			end,
			Load = function(Idx, Data)
				local Color = HexToColor(Data.value)
				if Library.Options[Idx] and Color then Library.Options[Idx]:SetValueRGB(Color, Data.transparency) end
			end,
		},
		KeyPicker = {
			Save = function(Idx, Obj) return { type = 'KeyPicker', idx = Idx, mode = Obj.Mode, key = Obj.Value } end,
			Load = function(Idx, Data)
				if Library.Options[Idx] then Library.Options[Idx]:SetValue({ Data.key, Data.mode }) end
			end,
		},
		Input = {
			Save = function(Idx, Obj) return { type = 'Input', idx = Idx, text = Obj.Value } end,
			Load = function(Idx, Data)
				if Library.Options[Idx] and type(Data.text) == 'string' then Library.Options[Idx]:SetValue(Data.text) end
			end,
		},
	}

	local function BuildPath(Path)
		if not HasFS then return end
		local Current = ''
		for Part in string.gmatch(Path, '[^/]+') do
			Current = Current == '' and Part or (Current .. '/' .. Part)
			if not isfolder(Current) then pcall(makefolder, Current) end
		end
	end

	function SaveManager:SetLibrary(Lib) self.Library = Lib end
	function SaveManager:BuildFolderTree()
		BuildPath(self.Folder)
		BuildPath(self.Folder .. '/settings')
	end
	function SaveManager:SetFolder(Folder)
		self.Folder = Folder
		self:BuildFolderTree()
	end
	function SaveManager:SetIgnoreIndexes(List)
		for _, Key in ipairs(List) do self.Ignore[Key] = true end
	end
	function SaveManager:IgnoreThemeSettings()
		self:SetIgnoreIndexes({
			'BackgroundColor', 'MainColor', 'AccentColor', 'OutlineColor', 'FontColor',
			'ThemeManager_ThemeList', 'ThemeManager_CustomThemeList', 'ThemeManager_CustomThemeName',
		})
	end

	function SaveManager:Save(Name)
		if string.gsub(Name or '', ' ', '') == '' then return false, 'no config file is selected' end
		local Data = { objects = {} }
		local Keys = {}
		for Idx in pairs(Library.Toggles) do table.insert(Keys, Idx) end
		for Idx in pairs(Library.Options) do table.insert(Keys, Idx) end
		table.sort(Keys)
		for _, Idx in ipairs(Keys) do
			if not self.Ignore[Idx] then
				local Obj = Library.Toggles[Idx] or Library.Options[Idx]
				local Parser = self.Parser[Obj.Type]
				if Parser then table.insert(Data.objects, Parser.Save(Idx, Obj)) end
			end
		end
		local Ok, Encoded = pcall(HttpService.JSONEncode, HttpService, Data)
		if not Ok then return false, 'failed to encode data' end
		if HasFS then
			self:BuildFolderTree()
			local WriteOk, Err = pcall(writefile, self.Folder .. '/settings/' .. Name .. '.json', Encoded)
			if not WriteOk then return false, 'failed to write file: ' .. tostring(Err) end
		else
			self.Memory[Name] = Encoded
		end
		return true
	end

	function SaveManager:Load(Name)
		if string.gsub(Name or '', ' ', '') == '' then return false, 'no config file is selected' end
		local Raw
		if HasFS then
			local Path = self.Folder .. '/settings/' .. Name .. '.json'
			if not isfile(Path) then return false, 'invalid file' end
			local Ok, Data = pcall(readfile, Path)
			if not Ok then return false, 'failed to read file' end
			Raw = Data
		else
			Raw = self.Memory[Name]
			if not Raw then return false, 'invalid file' end
		end
		local Ok, Decoded = pcall(HttpService.JSONDecode, HttpService, Raw)
		if not Ok or type(Decoded) ~= 'table' or type(Decoded.objects) ~= 'table' then return false, 'decode error' end
		for _, Obj in ipairs(Decoded.objects) do
			if type(Obj) == 'table' and not self.Ignore[Obj.idx] and self.Parser[Obj.type] then
				task.spawn(self.Parser[Obj.type].Load, Obj.idx, Obj)
			end
		end
		return true
	end

	function SaveManager:Delete(Name)
		if string.gsub(Name or '', ' ', '') == '' then return false, 'no config file is selected' end
		if HasFS then
			local Path = self.Folder .. '/settings/' .. Name .. '.json'
			if not isfile(Path) then return false, 'invalid file' end
			if type(delfile) ~= 'function' then return false, 'delfile is not available' end
			local Ok, Err = pcall(delfile, Path)
			if not Ok then return false, tostring(Err) end
		else
			if not self.Memory[Name] then return false, 'invalid file' end
			self.Memory[Name] = nil
		end
		return true
	end

	function SaveManager:RefreshConfigList()
		local Out = {}
		if HasFS then
			local Ok, List = pcall(listfiles, self.Folder .. '/settings')
			if Ok then
				for _, File in ipairs(List) do
					local Name = string.match(File, '([^/\\]+)%.json$')
					if Name then table.insert(Out, Name) end
				end
			end
		else
			for Name in pairs(self.Memory) do
				if string.sub(Name, 1, 1) ~= '_' then table.insert(Out, Name) end
			end
		end
		table.sort(Out)
		return Out
	end

	function SaveManager:GetAutoloadConfig()
		if HasFS then
			local Path = self.Folder .. '/settings/autoload.txt'
			if isfile(Path) then
				local Ok, Data = pcall(readfile, Path)
				if Ok and Data ~= '' then return Data end
			end
			return nil
		end
		return self.Memory._autoload
	end

	function SaveManager:SetAutoloadConfig(Name)
		if HasFS then
			local Ok, Err = pcall(writefile, self.Folder .. '/settings/autoload.txt', Name)
			if not Ok then return false, tostring(Err) end
		else
			self.Memory._autoload = Name
		end
		return true
	end

	function SaveManager:LoadAutoloadConfig()
		local Name = self:GetAutoloadConfig()
		if not Name then return end
		local Ok, Err = self:Load(Name)
		if not Ok then return Library:Notify('Failed to load autoload config: ' .. tostring(Err)) end
		Library:Notify(string.format('Auto loaded config %q', Name))
	end

	function SaveManager:BuildConfigSection(Tab)
		assert(Library, 'SaveManager: Library not set.')
		local Options = Library.Options
		local Section = Tab:AddRightGroupbox('Configuration')

		Section:AddInput('SaveManager_ConfigName', { Text = 'Config name' })
		Section:AddDropdown('SaveManager_ConfigList', { Text = 'Config list', Values = self:RefreshConfigList(), AllowNull = true })
		Section:AddDivider()

		Section:AddButton('Create config', function()
			local Name = Options.SaveManager_ConfigName.Value
			if string.gsub(Name, ' ', '') == '' then return Library:Notify('Invalid config name (empty)', 2) end
			local Ok, Err = self:Save(Name)
			if not Ok then return Library:Notify('Failed to create config: ' .. tostring(Err), 3) end
			Library:Notify(string.format('Created config %q', Name))
			Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
			Options.SaveManager_ConfigList:SetValue(nil)
		end):AddButton('Load config', function()
			local Name = Options.SaveManager_ConfigList.Value
			local Ok, Err = self:Load(Name)
			if not Ok then return Library:Notify('Failed to load config: ' .. tostring(Err), 3) end
			Library:Notify(string.format('Loaded config %q', Name))
		end)

		Section:AddButton({ Text = 'Overwrite config', DoubleClick = true, Func = function()
			local Name = Options.SaveManager_ConfigList.Value
			local Ok, Err = self:Save(Name)
			if not Ok then return Library:Notify('Failed to overwrite config: ' .. tostring(Err), 3) end
			Library:Notify(string.format('Overwrote config %q', Name))
		end }):AddButton({ Text = 'Delete config', DoubleClick = true, Func = function()
			local Name = Options.SaveManager_ConfigList.Value
			local Ok, Err = self:Delete(Name)
			if not Ok then return Library:Notify('Failed to delete config: ' .. tostring(Err), 3) end
			Library:Notify(string.format('Deleted config %q', Name))
			Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
			Options.SaveManager_ConfigList:SetValue(nil)
		end })

		Section:AddButton('Refresh list', function()
			Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
			Options.SaveManager_ConfigList:SetValue(nil)
		end)

		local AutoloadLabel
		Section:AddButton('Set as autoload', function()
			local Name = Options.SaveManager_ConfigList.Value
			if not Name then return Library:Notify('Pick a config first', 2) end
			local Ok, Err = self:SetAutoloadConfig(Name)
			if not Ok then return Library:Notify('Failed to set autoload: ' .. tostring(Err), 3) end
			AutoloadLabel:SetText('Current autoload config: ' .. Name)
			Library:Notify(string.format('Set %q to auto load', Name))
		end)
		AutoloadLabel = Section:AddLabel('Current autoload config: ' .. (self:GetAutoloadConfig() or 'none'), true)
		if not HasFS then
			Section:AddLabel('No file access here: configs are kept in memory for this session only.', true)
		end

		self:SetIgnoreIndexes({ 'SaveManager_ConfigList', 'SaveManager_ConfigName' })
	end
end

Library.ThemeManager = ThemeManager
Library.SaveManager = SaveManager

return Library
