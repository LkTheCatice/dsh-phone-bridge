import Foundation

// 真实 payload（来自工具详情截图）：read_image 的结果是一个 JSON 数组，
// 第一个元素是 text 块（<path> 包裹 + JSON 转义的分隔符），第二个是 image attachment。
let detail = """
[
  {
    "type": "text",
    "text": "<path>D:\\output\\sample-image-01.png</path>\n<type>image</type>\n<content>\nimage/webp image, 1024x768 px</content>"
  },
  {
    "type": "image",
    "attachment": { "mediaType": "image/webp", "bytes": 108686, "name": "深夜的书桌特写.png" }
  }
]
"""

let paths = ToolSummary.imagePaths(from: detail)
print("count:", paths.count)
for p in paths { print("  ->", p) }

// 断言：必须解出真实 Windows 路径（反斜杠已还原）
let want = "D:\\output\\sample-image-01.png"
if paths.contains(want) {
    print("PASS 路径还原正确")
} else {
    print("FAIL 期望:", want)
}

// 反向用例：普通文案 + 非图片扩展名不应被当成图片
print("plain text ->", ToolSummary.imagePaths(from: "运行命令 npm run build，日志在 build/out.txt"))
