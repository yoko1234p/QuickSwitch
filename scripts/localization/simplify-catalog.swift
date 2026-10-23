import Foundation

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let records = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [[String: Any]]
let keys = Set(records.compactMap { $0["key"] as? String })
// Region-appropriate macOS terminology, followed by ICU script conversion.
let terms = [
    "全螢幕": "全屏", "螢幕": "屏幕", "視窗": "窗口", "滑鼠": "鼠标", "資料夾": "文件夹",
    "檔案": "文件", "剪貼簿": "剪贴板", "垃圾桶": "废纸篓", "回收桶": "废纸篓",
    "記憶體": "内存", "帳戶": "账户", "資料": "数据", "儲存": "保存", "還原": "恢复",
    "復原": "撤销", "連線": "连接", "網路": "网络", "選單列": "菜单栏", "選單": "菜单",
    "圖示": "图标", "硬碟": "磁盘", "快取": "缓存", "軟體": "软件", "預設": "默认",
    "貼上": "粘贴", "開啟": "打开", "冇得": "不能", "唔會": "不会", "唔係": "不是",
    "冇": "没有", "喺": "在", "嘅": "的", "咗": "了", "搵": "查找", "俾": "给", "呢": "这",
]
var result: [String: String] = [:]
for key in keys {
    var value = key
    for term in terms.keys.sorted(by: { $0.count > $1.count }) {
        value = value.replacingOccurrences(of: term, with: terms[term]!)
    }
    result[key] = value.applyingTransform(.init("Traditional-Simplified"), reverse: false) ?? value
}
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    .write(to: output, options: .atomic)
