class_name FoldSection
extends PanelContainer
## FoldSection —— 可折叠分节：标题栏点击展开/收起内容。
## 视觉层级的原子组件：常用节展开、军用节收起，样式全部由全局主题
## （editor/theme/editor_theme.tres）通过 SectionCard / FoldHeader 类型变体控制。
##
## 用法（tscn 实例后把内容挂在 Content/Body 下，或在代码里 add_child 到 body()）：
##   var sec: FoldSection = FoldSectionScene.instantiate()
##   sec.setup("陆地", false)      # 标题 + 默认收起
##   sec.body().add_child(...)

signal folded_changed(folded: bool)

const ARROW_FOLDED := "▶  "
const ARROW_UNFOLDED := "▼  "

@export var section_title: String = "分节"
@export var start_folded: bool = false

@onready var header: Button = $"VBox/Header"
@onready var content: MarginContainer = $"VBox/Content"

## 内容容器：分节里的控件都加到这下面（公开属性，代码创建时用）
@onready var body: VBoxContainer = $"VBox/Content/Body"

var folded: bool = false
var title: String = ""


func _ready() -> void:
	title = section_title
	folded = start_folded
	header.pressed.connect(toggle)
	_apply_fold()


## 代码创建时的标题与初始折叠态（tscn 实例用 @export）
func setup(section_title: String, fold: bool = false) -> void:
	title = section_title
	folded = fold
	if is_inside_tree():
		_apply_fold()


func toggle() -> void:
	set_folded(not folded)


func set_folded(fold: bool) -> void:
	if folded == fold:
		return
	folded = fold
	if is_inside_tree():
		_apply_fold()
	folded_changed.emit(folded)


func _apply_fold() -> void:
	content.visible = not folded
	header.text = (ARROW_FOLDED if folded else ARROW_UNFOLDED) + title
