class_name EditorTheme
extends RefCounted
## EditorTheme —— 全编辑器统一深色主题（代码生成，唯一定义源）。
##
## 之前的教训：grid_tools.tscn 手写 36 个 StyleBoxFlat 与 grid_defs.gd 靠注释对色，
## 字号 11–36 各自为政、选中态三种实现。现在色板/字号/样式全部集中在这里，
## main.gd 在 _ready 里 `theme = EditorTheme.build()`，子场景自动继承。
##
## 色板（卡片风，与资源导入页同族）：
##   窗底 BG → 卡片 CARD → 分节 SECTION → 控件 WIDGET → 内槽 FIELD，
##   文字 TEXT/TEXT_DIM，强调金 ACCENT（沿用物件分节的老金色），成功/失败绿红。

const BG := Color("1a1b20")            # 窗口底（配合 project.godot default_clear_color）
const CARD := Color("242529")          # 卡片/面板
const SECTION := Color("2b2d33")       # 分节标题栏
const SECTION_HOVER := Color("34373e")
const WIDGET := Color("33363e")        # 按钮常态
const WIDGET_HOVER := Color("3d414b")
const WIDGET_PRESSED := Color("26282e")   # 按下/选中：靠金色描边+金字识别
const FIELD := Color("1e1f24")         # 输入框/滑轨内槽
const BORDER := Color("454956")
const BORDER_SOFT := Color(0.30, 0.31, 0.36, 0.55)
const TEXT := Color("e4e4e9")
const TEXT_DIM := Color("9c9ca6")
const ACCENT := Color("f2dc9b")        # 强调金（选中文字/滑杆填充/焦点边）
const ACCENT_LINE := Color("b09b5e")
const OK := Color("8fca8a")
const ERR := Color("e07b64")

const FONT_BODY := 13
const FONT_STATUS := 12


static func build() -> Theme:
	var theme := Theme.new()
	_style_button(theme)
	_style_fold(theme)
	_style_panel(theme)
	_style_label(theme)
	_style_slider(theme)
	_style_field(theme)
	_style_popup(theme)
	_style_window(theme)
	_style_misc(theme)
	return theme


# ---------- 基础按钮：按下/选中态统一为"金描边 + 金字" ----------

static func _style_button(theme: Theme) -> void:
	theme.set_color("font_color", "Button", TEXT)
	theme.set_color("font_hover_color", "Button", Color(1, 1, 1, 0.96))
	theme.set_color("font_pressed_color", "Button", ACCENT)
	theme.set_color("font_focus_color", "Button", TEXT)
	theme.set_color("font_disabled_color", "Button", TEXT_DIM)
	theme.set_color("font_outline_color", "Button", Color(0, 0, 0, 0.55))
	theme.set_constant("outline_size", "Button", 1)
	theme.set_font_size("font_size", "Button", FONT_BODY)

	var normal := _flat(WIDGET, BORDER_SOFT, 4)
	normal.content_margin_left = 10.0
	normal.content_margin_right = 10.0
	normal.content_margin_top = 5.0
	normal.content_margin_bottom = 5.0
	var hover := _flat(WIDGET_HOVER, BORDER_SOFT, 4)
	_copy_margins(hover, normal)
	var pressed := _flat(WIDGET_PRESSED, ACCENT_LINE, 4)
	_copy_margins(pressed, normal)
	var disabled := _flat(Color(WIDGET, 0.4), Color(BORDER, 0.4), 4)
	_copy_margins(disabled, normal)

	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("hover", "Button", hover)
	theme.set_stylebox("pressed", "Button", pressed)
	theme.set_stylebox("hover_pressed", "Button", pressed)
	theme.set_stylebox("disabled", "Button", disabled)
	theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())


# ---------- FoldSection：分节卡 + 可折叠标题栏（fold_section.tscn 使用） ----------

static func _style_fold(theme: Theme) -> void:
	theme.set_type_variation("SectionCard", "PanelContainer")
	var card := _flat(CARD, BORDER_SOFT, 6)
	card.content_margin_left = 0.0
	card.content_margin_right = 0.0
	card.content_margin_top = 0.0
	card.content_margin_bottom = 0.0
	theme.set_stylebox("panel", "SectionCard", card)

	theme.set_type_variation("FoldHeader", "Button")
	theme.set_color("font_color", "FoldHeader", Color("cfcfd6"))
	theme.set_color("font_hover_color", "FoldHeader", TEXT)
	theme.set_color("font_pressed_color", "FoldHeader", TEXT)
	theme.set_color("font_focus_color", "FoldHeader", TEXT)
	theme.set_font_size("font_size", "FoldHeader", FONT_BODY)

	var header := _flat(SECTION, Color(BORDER, 0.0), 6)   # 与卡片同圆角，视觉上融为一体
	header.content_margin_left = 10.0
	header.content_margin_right = 8.0
	header.content_margin_top = 7.0
	header.content_margin_bottom = 7.0
	var header_hover := _flat(SECTION_HOVER, Color(BORDER, 0.0), 6)
	_copy_margins(header_hover, header)
	theme.set_stylebox("normal", "FoldHeader", header)
	theme.set_stylebox("hover", "FoldHeader", header_hover)
	theme.set_stylebox("pressed", "FoldHeader", header_hover)
	theme.set_stylebox("hover_pressed", "FoldHeader", header_hover)
	theme.set_stylebox("focus", "FoldHeader", StyleBoxEmpty.new())


# ---------- 面板 / 文字 ----------

static func _style_panel(theme: Theme) -> void:
	var panel := _flat(CARD, BORDER_SOFT, 6)
	panel.content_margin_left = 8.0
	panel.content_margin_right = 8.0
	panel.content_margin_top = 6.0
	panel.content_margin_bottom = 8.0
	theme.set_stylebox("panel", "PanelContainer", panel)
	# 布局面板（Main.tscn 的小面板/工具区/大画布区）：同款卡片底，无内边距
	theme.set_stylebox("panel", "Panel", _flat(CARD, BORDER_SOFT, 6))


static func _style_label(theme: Theme) -> void:
	theme.set_color("font_color", "Label", TEXT)
	theme.set_font_size("font_size", "Label", FONT_BODY)

	theme.set_type_variation("Dim", "Label")
	theme.set_color("font_color", "Dim", TEXT_DIM)
	theme.set_font_size("font_size", "Dim", FONT_STATUS)

	theme.set_type_variation("Accent", "Label")
	theme.set_color("font_color", "Accent", ACCENT)
	theme.set_font_size("font_size", "Accent", FONT_BODY)


# ---------- 滑杆：轨道内槽 + 金色已填充段 ----------

static func _style_slider(theme: Theme) -> void:
	var track := _flat(FIELD, BORDER_SOFT, 3)
	track.content_margin_left = 2.0
	track.content_margin_right = 2.0
	track.content_margin_top = 2.0
	track.content_margin_bottom = 2.0
	theme.set_stylebox("slider", "HSlider", track)

	var fill := _flat(Color(ACCENT, 0.42), Color(ACCENT, 0.0), 3)
	theme.set_stylebox("grabber_area", "HSlider", fill)
	var fill_hl := _flat(Color(ACCENT, 0.62), Color(ACCENT, 0.0), 3)
	theme.set_stylebox("grabber_area_highlight", "HSlider", fill_hl)
	theme.set_constant("grabber_offset", "HSlider", 0)


# ---------- 输入框 ----------

static func _style_field(theme: Theme) -> void:
	for type: String in ["LineEdit", "TextEdit"]:
		theme.set_color("font_color", type, TEXT)
		theme.set_color("font_placeholder_color", type, TEXT_DIM)
		theme.set_color("caret_color", type, ACCENT)
		theme.set_font_size("font_size", type, FONT_BODY)
		var field := _flat(FIELD, BORDER_SOFT, 4)
		field.content_margin_left = 8.0
		field.content_margin_right = 8.0
		field.content_margin_top = 4.0
		field.content_margin_bottom = 4.0
		theme.set_stylebox("normal", type, field)
		var field_focus := _flat(FIELD, ACCENT_LINE, 4)
		_copy_margins(field_focus, field)
		theme.set_stylebox("focus", type, field_focus)

	theme.set_color("font_color", "SpinBox", TEXT)
	theme.set_font_size("font_size", "SpinBox", FONT_BODY)


# ---------- 弹出菜单 / 列表 ----------

static func _style_popup(theme: Theme) -> void:
	theme.set_color("font_color", "PopupMenu", TEXT)
	theme.set_color("font_hover_color", "PopupMenu", TEXT)
	theme.set_color("font_disabled_color", "PopupMenu", TEXT_DIM)
	theme.set_font_size("font_size", "PopupMenu", FONT_BODY)
	var menu := _flat(CARD, BORDER, 6)
	menu.content_margin_left = 8.0
	menu.content_margin_right = 8.0
	menu.content_margin_top = 6.0
	menu.content_margin_bottom = 6.0
	theme.set_stylebox("panel", "PopupMenu", menu)
	var menu_hl := _flat(WIDGET_HOVER, ACCENT_LINE, 4)
	menu_hl.content_margin_left = 8.0
	menu_hl.content_margin_right = 8.0
	menu_hl.content_margin_top = 3.0
	menu_hl.content_margin_bottom = 3.0
	theme.set_stylebox("hover", "PopupMenu", menu_hl)
	theme.set_stylebox("separator", "PopupMenu", _hline())

	theme.set_color("font_color", "ItemList", TEXT)
	theme.set_color("font_selected_color", "ItemList", ACCENT)
	theme.set_font_size("font_size", "ItemList", FONT_BODY)
	theme.set_stylebox("panel", "ItemList", _flat(FIELD, BORDER_SOFT, 4))
	var item_hl := _flat(WIDGET_HOVER, Color(BORDER, 0.0), 4)
	theme.set_stylebox("hover", "ItemList", item_hl)
	var item_sel := _flat(WIDGET_PRESSED, ACCENT_LINE, 4)
	theme.set_stylebox("selected", "ItemList", item_sel)
	var item_focus := _flat(Color(BORDER, 0.0), Color(BORDER, 0.0), 4)
	theme.set_stylebox("selected_focus", "ItemList", item_focus)
	theme.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())


# ---------- 对话框 ----------

static func _style_window(theme: Theme) -> void:
	theme.set_color("title_color", "Window", TEXT)
	var border := _flat(CARD, BORDER, 8)
	border.content_margin_left = 10.0
	border.content_margin_right = 10.0
	border.content_margin_top = 6.0
	border.content_margin_bottom = 10.0
	border.border_width_top = 0        # 标题栏在边框内，顶部不重复描边
	theme.set_stylebox("embedded_border", "Window", border)
	var border_un := _flat(CARD, BORDER_SOFT, 8)
	_copy_margins(border_un, border)
	border_un.border_width_top = 0
	theme.set_stylebox("embedded_unfocused_border", "Window", border_un)


# ---------- 其他 ----------

static func _style_misc(theme: Theme) -> void:
	theme.set_stylebox("separator", "HSeparator", _hline())
	theme.set_constant("separation", "HSeparator", 4)

	theme.set_color("font_color", "LinkButton", ACCENT)
	theme.set_font_size("font_size", "LinkButton", FONT_BODY)

	theme.set_color("color", "TooltipPanel", CARD)
	var tip := _flat(Color(0.11, 0.11, 0.14, 0.96), BORDER, 4)
	tip.content_margin_left = 8.0
	tip.content_margin_right = 8.0
	tip.content_margin_top = 5.0
	tip.content_margin_bottom = 5.0
	theme.set_stylebox("panel", "TooltipPanel", tip)
	theme.set_color("font_color", "TooltipLabel", TEXT)
	theme.set_font_size("font_size", "TooltipLabel", FONT_STATUS)


# ---------- 工具 ----------

static func _flat(bg: Color, border: Color, radius: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.set_border_width_all(1)
	box.border_color = border
	box.set_corner_radius_all(radius)
	box.content_margin_left = 6.0
	box.content_margin_right = 6.0
	box.content_margin_top = 3.0
	box.content_margin_bottom = 3.0
	return box


static func _copy_margins(dst: StyleBoxFlat, src: StyleBoxFlat) -> void:
	dst.content_margin_left = src.content_margin_left
	dst.content_margin_right = src.content_margin_right
	dst.content_margin_top = src.content_margin_top
	dst.content_margin_bottom = src.content_margin_bottom


static func _hline() -> StyleBoxFlat:
	var line := StyleBoxFlat.new()
	line.bg_color = Color(BORDER, 0.6)
	line.content_margin_top = 2.0
	line.content_margin_bottom = 2.0
	line.corner_radius_top_left = 1
	line.corner_radius_bottom_left = 1
	return line
