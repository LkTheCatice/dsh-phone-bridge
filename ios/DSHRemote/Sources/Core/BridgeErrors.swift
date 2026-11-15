import Foundation

/// 桥返回的错误码 → 用户能读懂的一句话。
///
/// 为什么在 App 侧翻译：桥是"服务器"，它不知道这台手机设成什么语言，
/// 也不该知道（同一个桥可能同时服务多台设备）。所以桥只说**是什么错**（code），
/// 措辞由客户端决定。
///
/// 约定：**未收录的码保留服务端原文**（方便报障），但去掉 `code（HTTP 403）：` 这种前缀。
func localizedBridgeError(code: String, fallback: String) -> String {
    switch code {
    case "outside-roots":
        return L("这个文件不在电脑允许的目录里",
                 "That file is outside the folders the computer allows")
    case "unauthorized":
        return L("配对已失效，请重新配对", "Pairing expired — pair again")
    case "handshake-required":
        return L("连接还没握手完成，正在重试", "The connection isn't handshaken yet")
    case "e2ee-required":
        return L("这个接口只接受加密请求", "This endpoint only accepts encrypted requests")
    case "device-pending":
        return L("这台设备还没在电脑上确认", "This device hasn't been approved on the computer yet")
    case "device-blocked":
        return L("这台设备已在电脑上被移出", "This device was removed on the computer")
    case "too-many-attempts":
        return L("尝试次数过多，请稍后再试", "Too many attempts — try again in a bit")
    case "payload-too-large":
        return L("文件太大，超出了电脑端的单次上限", "File is larger than the computer's limit")
    case "not-ready":
        return L("电脑端还没准备好，稍等几秒再试", "The computer isn't ready yet — try again in a moment")
    case "not-found":
        return L("电脑上找不到这个对象", "Not found on the computer")
    case "closed":
        return L("桥已关闭，请重启电脑上的 DSH", "The bridge is closed — restart DSH on the computer")
    case "forbidden":
        return L("这个操作只能在电脑本机进行", "This action is only allowed on the computer itself")
    case "admin-header-required":
        return L("缺少管理员标记，请在电脑端操作", "Missing admin marker — do this on the computer")
    case "bad-json":
        return L("请求格式不对", "Malformed request")
    case "bad-request":
        return L("请求参数不完整", "Missing request parameters")
    case "create-failed":
        return L("电脑端创建失败", "The computer failed to create it")
    case "update-failed":
        return L("电脑端更新失败", "The computer failed to update it")
    default:
        // 未知码：保留服务端原文，但别把"HTTP 401"这类噪音塞给用户
        return fallback
    }
}
