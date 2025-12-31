//
//  LanguageManager.swift
//  Quotio
//

import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case vietnamese = "vi"
    case chinese = "zh"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        case .chinese: return "简体中文"
        }
    }
    
    var flag: String {
        switch self {
        case .english: return "🇺🇸"
        case .vietnamese: return "🇻🇳"
        case .chinese: return "🇨🇳"
        }
    }
}

@MainActor
@Observable
final class LanguageManager {
    static let shared = LanguageManager()
    
    var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "appLanguage")
        }
    }
    
    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        self.currentLanguage = AppLanguage(rawValue: saved) ?? .english
    }
    
    func localized(_ key: String) -> String {
        return LocalizedStrings.get(key, language: currentLanguage)
    }
}

struct LocalizedStrings {
    private static let strings: [String: [AppLanguage: String]] = [
        // Navigation
        "nav.dashboard": [.english: "Dashboard", .vietnamese: "Bảng điều khiển", .chinese: "仪表板"],
        "nav.quota": [.english: "Quota", .vietnamese: "Hạn mức", .chinese: "配额"],
        "nav.providers": [.english: "Providers", .vietnamese: "Nhà cung cấp", .chinese: "提供商"],
        "nav.apiKeys": [.english: "API Keys", .vietnamese: "Khóa API", .chinese: "API 密钥"],
        "nav.logs": [.english: "Logs", .vietnamese: "Nhật ký", .chinese: "日志"],
        "nav.settings": [.english: "Settings", .vietnamese: "Cài đặt", .chinese: "设置"],
        "nav.about": [.english: "About", .vietnamese: "Giới thiệu", .chinese: "关于"],
        
        // Status
        "status.running": [.english: "Running", .vietnamese: "Đang chạy", .chinese: "运行中"],
        "status.starting": [.english: "Starting...", .vietnamese: "Đang khởi động...", .chinese: "启动中..."],
        "status.stopped": [.english: "Stopped", .vietnamese: "Đã dừng", .chinese: "已停止"],
        "status.ready": [.english: "Ready", .vietnamese: "Sẵn sàng", .chinese: "就绪"],
        "status.cooling": [.english: "Cooling", .vietnamese: "Đang nghỉ", .chinese: "冷却中"],
        "status.error": [.english: "Error", .vietnamese: "Lỗi", .chinese: "错误"],
        "status.available": [.english: "Available", .vietnamese: "Khả dụng", .chinese: "可用"],
        "status.forbidden": [.english: "Forbidden", .vietnamese: "Bị chặn", .chinese: "已禁止"],
        
        // Dashboard
        "dashboard.accounts": [.english: "Accounts", .vietnamese: "Tài khoản", .chinese: "账户"],
        "dashboard.ready": [.english: "ready", .vietnamese: "sẵn sàng", .chinese: "就绪"],
        "dashboard.requests": [.english: "Requests", .vietnamese: "Yêu cầu", .chinese: "请求"],
        "dashboard.total": [.english: "total", .vietnamese: "tổng", .chinese: "总计"],
        "dashboard.tokens": [.english: "Tokens", .vietnamese: "Token", .chinese: "令牌"],
        "dashboard.processed": [.english: "processed", .vietnamese: "đã xử lý", .chinese: "已处理"],
        "dashboard.successRate": [.english: "Success Rate", .vietnamese: "Tỷ lệ thành công", .chinese: "成功率"],
        "dashboard.failed": [.english: "failed", .vietnamese: "thất bại", .chinese: "失败"],
        "dashboard.providers": [.english: "Providers", .vietnamese: "Nhà cung cấp", .chinese: "提供商"],
        "dashboard.apiEndpoint": [.english: "API Endpoint", .vietnamese: "Điểm cuối API", .chinese: "API 端点"],
        "dashboard.cliNotInstalled": [.english: "CLIProxyAPI Not Installed", .vietnamese: "CLIProxyAPI chưa cài đặt", .chinese: "CLIProxyAPI 未安装"],
        "dashboard.clickToInstall": [.english: "Click the button below to automatically download and install", .vietnamese: "Nhấn nút bên dưới để tự động tải và cài đặt", .chinese: "点击下方按钮自动下载并安装"],
        "dashboard.installCLI": [.english: "Install CLIProxyAPI", .vietnamese: "Cài đặt CLIProxyAPI", .chinese: "安装 CLIProxyAPI"],
        "dashboard.startToBegin": [.english: "Start the proxy server to begin", .vietnamese: "Khởi động máy chủ proxy để bắt đầu", .chinese: "启动代理服务器以开始"],
        
        // Quota
        "quota.overallStatus": [.english: "Overall Status", .vietnamese: "Trạng thái chung", .chinese: "总体状态"],
        "quota.providers": [.english: "providers", .vietnamese: "nhà cung cấp", .chinese: "提供商"],
        "quota.accounts": [.english: "accounts", .vietnamese: "tài khoản", .chinese: "账户"],
        "quota.account": [.english: "account", .vietnamese: "tài khoản", .chinese: "账户"],
        "quota.accountsReady": [.english: "accounts ready", .vietnamese: "tài khoản sẵn sàng", .chinese: "账户就绪"],
        "quota.used": [.english: "used", .vietnamese: "đã dùng", .chinese: "已使用"],
        "quota.reset": [.english: "reset", .vietnamese: "đặt lại", .chinese: "重置"],
        "quota.noDataYet": [.english: "No usage data available", .vietnamese: "Chưa có dữ liệu sử dụng", .chinese: "暂无使用数据"],
        
        // Providers
        "providers.addProvider": [.english: "Add Provider", .vietnamese: "Thêm nhà cung cấp", .chinese: "添加提供商"],
        "providers.connectedAccounts": [.english: "Connected Accounts", .vietnamese: "Tài khoản đã kết nối", .chinese: "已连接账户"],
        "providers.noAccountsYet": [.english: "No accounts connected yet", .vietnamese: "Chưa có tài khoản nào được kết nối", .chinese: "尚未连接账户"],
        "providers.startProxyFirst": [.english: "Start the proxy first to manage providers", .vietnamese: "Khởi động proxy trước để quản lý nhà cung cấp", .chinese: "先启动代理以管理提供商"],
        "providers.connect": [.english: "Connect", .vietnamese: "Kết nối", .chinese: "连接"],
        "providers.authenticate": [.english: "Authenticate", .vietnamese: "Xác thực", .chinese: "认证"],
        "providers.cancel": [.english: "Cancel", .vietnamese: "Hủy", .chinese: "取消"],
        "providers.waitingAuth": [.english: "Waiting for authentication...", .vietnamese: "Đang chờ xác thực...", .chinese: "等待认证..."],
        "providers.connectedSuccess": [.english: "Connected successfully!", .vietnamese: "Kết nối thành công!", .chinese: "连接成功！"],
        "providers.authFailed": [.english: "Authentication failed", .vietnamese: "Xác thực thất bại", .chinese: "认证失败"],
        "providers.projectIdOptional": [.english: "Project ID (optional)", .vietnamese: "ID dự án (tùy chọn)", .chinese: "项目 ID（可选）"],
        "providers.disabled": [.english: "Disabled", .vietnamese: "Đã tắt", .chinese: "已禁用"],
        "providers.autoDetected": [.english: "Auto-detected", .vietnamese: "Tự động phát hiện", .chinese: "自动检测"],
        "providers.proxyRequired.title": [.english: "Proxy Required", .vietnamese: "Cần khởi động Proxy", .chinese: "需要代理"],
        "providers.proxyRequired.message": [.english: "The proxy server must be running to add new provider accounts.", .vietnamese: "Cần khởi động proxy để thêm tài khoản nhà cung cấp mới.", .chinese: "必须运行代理服务器才能添加新的提供商账户。"],
        
        // Settings
        "settings.proxyServer": [.english: "Proxy Server", .vietnamese: "Máy chủ proxy", .chinese: "代理服务器"],
        "settings.port": [.english: "Port", .vietnamese: "Cổng", .chinese: "端口"],
        "settings.endpoint": [.english: "Endpoint", .vietnamese: "Điểm cuối", .chinese: "端点"],
        "settings.status": [.english: "Status", .vietnamese: "Trạng thái", .chinese: "状态"],
        "settings.autoStartProxy": [.english: "Auto-start proxy on launch", .vietnamese: "Tự khởi động proxy khi mở app", .chinese: "启动时自动启动代理"],
        "settings.restartProxy": [.english: "Restart proxy after changing port", .vietnamese: "Khởi động lại proxy sau khi đổi cổng", .chinese: "更改端口后重启代理"],
        "settings.routingStrategy": [.english: "Routing Strategy", .vietnamese: "Chiến lược định tuyến", .chinese: "路由策略"],
        "settings.roundRobin": [.english: "Round Robin", .vietnamese: "Xoay vòng", .chinese: "轮询"],
        "settings.fillFirst": [.english: "Fill First", .vietnamese: "Dùng hết trước", .chinese: "优先填满"],
        "settings.roundRobinDesc": [.english: "Distributes requests evenly across all accounts", .vietnamese: "Phân phối yêu cầu đều cho tất cả tài khoản", .chinese: "在所有账户间均匀分配请求"],
        "settings.fillFirstDesc": [.english: "Uses one account until quota exhausted, then moves to next", .vietnamese: "Dùng một tài khoản đến khi hết hạn mức, rồi chuyển sang tài khoản tiếp", .chinese: "使用一个账户直到配额耗尽，然后切换到下一个"],
        "settings.quotaExceededBehavior": [.english: "Quota Exceeded Behavior", .vietnamese: "Hành vi khi vượt hạn mức", .chinese: "配额超限行为"],
        "settings.autoSwitchAccount": [.english: "Auto-switch to another account", .vietnamese: "Tự động chuyển sang tài khoản khác", .chinese: "自动切换到其他账户"],
        "settings.autoSwitchPreview": [.english: "Auto-switch to preview model", .vietnamese: "Tự động chuyển sang mô hình xem trước", .chinese: "自动切换到预览模型"],
        "settings.quotaExceededHelp": [.english: "When quota is exceeded, automatically try alternative accounts or models", .vietnamese: "Khi vượt hạn mức, tự động thử tài khoản hoặc mô hình khác", .chinese: "配额超限时，自动尝试备选账户或模型"],
        "settings.retryConfiguration": [.english: "Retry Configuration", .vietnamese: "Cấu hình thử lại", .chinese: "重试配置"],
        "settings.maxRetries": [.english: "Max retries", .vietnamese: "Số lần thử lại tối đa", .chinese: "最大重试次数"],
        "settings.retryHelp": [.english: "Number of times to retry failed requests (403, 408, 500, 502, 503, 504)", .vietnamese: "Số lần thử lại yêu cầu thất bại (403, 408, 500, 502, 503, 504)", .chinese: "失败请求的重试次数（403、408、500、502、503、504）"],
        "settings.logging": [.english: "Logging", .vietnamese: "Ghi nhật ký", .chinese: "日志"],
        "settings.loggingToFile": [.english: "Log to file", .vietnamese: "Ghi nhật ký ra file", .chinese: "记录到文件"],
        "settings.loggingHelp": [.english: "Write application logs to rotating files instead of stdout. Disable to log to stdout/stderr.", .vietnamese: "Ghi nhật ký vào file xoay vòng thay vì stdout. Tắt để ghi ra stdout/stderr.", .chinese: "将应用程序日志写入滚动文件而不是 stdout。禁用则记录到 stdout/stderr。"],
        "settings.paths": [.english: "Paths", .vietnamese: "Đường dẫn", .chinese: "路径"],
        "settings.binary": [.english: "Binary", .vietnamese: "Tệp chạy", .chinese: "二进制文件"],
        "settings.config": [.english: "Config", .vietnamese: "Cấu hình", .chinese: "配置"],
        "settings.authDir": [.english: "Auth Dir", .vietnamese: "Thư mục xác thực", .chinese: "认证目录"],
        "settings.language": [.english: "Language", .vietnamese: "Ngôn ngữ", .chinese: "语言"],
        "settings.general": [.english: "General", .vietnamese: "Chung", .chinese: "常规"],
        "settings.about": [.english: "About", .vietnamese: "Giới thiệu", .chinese: "关于"],
        "settings.startup": [.english: "Startup", .vietnamese: "Khởi động", .chinese: "启动"],
        "settings.appearance": [.english: "Appearance", .vietnamese: "Giao diện", .chinese: "外观"],
        "settings.launchAtLogin": [.english: "Launch at login", .vietnamese: "Khởi động cùng hệ thống", .chinese: "登录时启动"],
        "settings.showInDock": [.english: "Show in Dock", .vietnamese: "Hiển thị trên Dock", .chinese: "在 Dock 中显示"],
        "settings.restartForEffect": [.english: "Restart app for full effect", .vietnamese: "Khởi động lại ứng dụng để có hiệu lực đầy đủ", .chinese: "重启应用以完全生效"],
        "settings.apiKeys": [.english: "API Keys", .vietnamese: "Khóa API", .chinese: "API 密钥"],
        "settings.apiKeysHelp": [.english: "API keys for clients to authenticate with the proxy", .vietnamese: "Khóa API để các client xác thực với proxy", .chinese: "客户端用于与代理认证的 API 密钥"],
        "settings.addAPIKey": [.english: "Add API Key", .vietnamese: "Thêm khóa API", .chinese: "添加 API 密钥"],
        "settings.apiKeyPlaceholder": [.english: "Enter API key...", .vietnamese: "Nhập khóa API...", .chinese: "输入 API 密钥..."],
        
        // API Keys Screen
        "apiKeys.list": [.english: "API Keys", .vietnamese: "Danh sách khóa API", .chinese: "API 密钥"],
        "apiKeys.description": [.english: "API keys for clients to authenticate with the proxy service", .vietnamese: "Khóa API để các client xác thực với dịch vụ proxy", .chinese: "客户端用于与代理服务认证的 API 密钥"],
        "apiKeys.add": [.english: "Add Key", .vietnamese: "Thêm khóa", .chinese: "添加密钥"],
        "apiKeys.addHelp": [.english: "Add a new API key", .vietnamese: "Thêm khóa API mới", .chinese: "添加新的 API 密钥"],
        "apiKeys.generate": [.english: "Generate", .vietnamese: "Tạo ngẫu nhiên", .chinese: "生成"],
        "apiKeys.generateHelp": [.english: "Generate a random API key", .vietnamese: "Tạo khóa API ngẫu nhiên", .chinese: "生成随机 API 密钥"],
        "apiKeys.generateFirst": [.english: "Generate Your First Key", .vietnamese: "Tạo khóa đầu tiên", .chinese: "生成您的第一个密钥"],
        "apiKeys.placeholder": [.english: "Enter API key...", .vietnamese: "Nhập khóa API...", .chinese: "输入 API 密钥..."],
        "apiKeys.edit": [.english: "Edit", .vietnamese: "Sửa", .chinese: "编辑"],
        "apiKeys.empty": [.english: "No API Keys", .vietnamese: "Chưa có khóa API", .chinese: "无 API 密钥"],
        "apiKeys.emptyDescription": [.english: "Add API keys to authenticate clients with the proxy", .vietnamese: "Thêm khóa API để xác thực client với proxy", .chinese: "添加 API 密钥以与代理进行客户端认证"],
        "apiKeys.proxyRequired": [.english: "Start the proxy to manage API keys", .vietnamese: "Khởi động proxy để quản lý khóa API", .chinese: "启动代理以管理 API 密钥"],
        
        // Logs
        "logs.clearLogs": [.english: "Clear Logs", .vietnamese: "Xóa nhật ký", .chinese: "清除日志"],
        "logs.noLogs": [.english: "No Logs", .vietnamese: "Không có nhật ký", .chinese: "无日志"],
        "logs.startProxy": [.english: "Start the proxy to view logs", .vietnamese: "Khởi động proxy để xem nhật ký", .chinese: "启动代理以查看日志"],
        "logs.logsWillAppear": [.english: "Logs will appear here as requests are processed", .vietnamese: "Nhật ký sẽ xuất hiện khi có yêu cầu được xử lý", .chinese: "处理请求时，日志将在此处显示"],
        "logs.searchLogs": [.english: "Search logs...", .vietnamese: "Tìm kiếm nhật ký...", .chinese: "搜索日志..."],
        "logs.all": [.english: "All", .vietnamese: "Tất cả", .chinese: "全部"],
        "logs.info": [.english: "Info", .vietnamese: "Thông tin", .chinese: "信息"],
        "logs.warn": [.english: "Warn", .vietnamese: "Cảnh báo", .chinese: "警告"],
        "logs.error": [.english: "Error", .vietnamese: "Lỗi", .chinese: "错误"],
        "logs.autoScroll": [.english: "Auto-scroll", .vietnamese: "Tự cuộn", .chinese: "自动滚动"],
        
        // Actions
        "action.start": [.english: "Start", .vietnamese: "Bắt đầu", .chinese: "开始"],
        "action.stop": [.english: "Stop", .vietnamese: "Dừng", .chinese: "停止"],
        "action.startProxy": [.english: "Start Proxy", .vietnamese: "Khởi động Proxy", .chinese: "启动代理"],
        "action.stopProxy": [.english: "Stop Proxy", .vietnamese: "Dừng Proxy", .chinese: "停止代理"],
        "action.copy": [.english: "Copy", .vietnamese: "Sao chép", .chinese: "复制"],
        "action.copied": [.english: "Copied", .vietnamese: "Đã sao chép", .chinese: "已复制"],
        "action.delete": [.english: "Delete", .vietnamese: "Xóa", .chinese: "删除"],
        "action.refresh": [.english: "Refresh", .vietnamese: "Làm mới", .chinese: "刷新"],
        "action.copyCode": [.english: "Copy Code", .vietnamese: "Sao chép mã", .chinese: "复制代码"],
        "action.quit": [.english: "Quit Quotio", .vietnamese: "Thoát Quotio", .chinese: "退出 Quotio"],
        "action.openApp": [.english: "Open Quotio", .vietnamese: "Mở Quotio", .chinese: "打开 Quotio"],
        
        // Empty states
        "empty.proxyNotRunning": [.english: "Proxy Not Running", .vietnamese: "Proxy chưa chạy", .chinese: "代理未运行"],
        "empty.startProxyToView": [.english: "Start the proxy to view quota information", .vietnamese: "Khởi động proxy để xem thông tin hạn mức", .chinese: "启动代理以查看配额信息"],
        "empty.noAccounts": [.english: "No Accounts", .vietnamese: "Chưa có tài khoản", .chinese: "无账户"],
        "empty.addProviderAccounts": [.english: "Add provider accounts to view quota", .vietnamese: "Thêm tài khoản nhà cung cấp để xem hạn mức", .chinese: "添加提供商账户以查看配额"],
        
        // Subscription
        "subscription.upgrade": [.english: "Upgrade", .vietnamese: "Nâng cấp", .chinese: "升级"],
        "subscription.freeTier": [.english: "Free Tier", .vietnamese: "Gói miễn phí", .chinese: "免费套餐"],
        "subscription.proPlan": [.english: "Pro Plan", .vietnamese: "Gói Pro", .chinese: "专业版"],
        "subscription.project": [.english: "Project", .vietnamese: "Dự án", .chinese: "项目"],
        
        // OAuth
        "oauth.connect": [.english: "Connect", .vietnamese: "Kết nối", .chinese: "连接"],
        "oauth.authenticateWith": [.english: "Authenticate with your", .vietnamese: "Xác thực với tài khoản", .chinese: "使用您的账户进行认证"],
        "oauth.projectId": [.english: "Project ID (optional)", .vietnamese: "ID dự án (tùy chọn)", .chinese: "项目 ID（可选）"],
        "oauth.projectIdPlaceholder": [.english: "Enter project ID...", .vietnamese: "Nhập ID dự án...", .chinese: "输入项目 ID..."],
        "oauth.authenticate": [.english: "Authenticate", .vietnamese: "Xác thực", .chinese: "认证"],
        "oauth.retry": [.english: "Try Again", .vietnamese: "Thử lại", .chinese: "重试"],
        "oauth.openingBrowser": [.english: "Opening browser...", .vietnamese: "Đang mở trình duyệt...", .chinese: "正在打开浏览器..."],
        "oauth.waitingForAuth": [.english: "Waiting for authentication", .vietnamese: "Đang chờ xác thực", .chinese: "等待认证"],
        "oauth.completeBrowser": [.english: "Complete the login in your browser", .vietnamese: "Hoàn tất đăng nhập trong trình duyệt", .chinese: "在浏览器中完成登录"],
        "oauth.success": [.english: "Connected successfully!", .vietnamese: "Kết nối thành công!", .chinese: "连接成功！"],
        "oauth.closingSheet": [.english: "Closing...", .vietnamese: "Đang đóng...", .chinese: "正在关闭..."],
        "oauth.failed": [.english: "Authentication failed", .vietnamese: "Xác thực thất bại", .chinese: "认证失败"],
        "oauth.timeout": [.english: "Authentication timeout", .vietnamese: "Hết thời gian xác thực", .chinese: "认证超时"],
        "oauth.authMethod": [.english: "Authentication Method", .vietnamese: "Phương thức xác thực", .chinese: "认证方法"],
        "oauth.enterCodeInBrowser": [.english: "Enter this code in browser", .vietnamese: "Nhập mã này trong trình duyệt", .chinese: "在浏览器中输入此代码"],
        
        "import.vertexKey": [.english: "Import Service Account Key", .vietnamese: "Nhập khóa tài khoản dịch vụ", .chinese: "导入服务账户密钥"],
        "import.vertexDesc": [.english: "Select the JSON key file for your Vertex AI service account", .vietnamese: "Chọn tệp khóa JSON cho tài khoản dịch vụ Vertex AI", .chinese: "选择您的 Vertex AI 服务账户的 JSON 密钥文件"],
        "import.selectFile": [.english: "Select JSON File", .vietnamese: "Chọn tệp JSON", .chinese: "选择 JSON 文件"],
        "import.success": [.english: "Key imported successfully", .vietnamese: "Đã nhập khóa thành công", .chinese: "密钥导入成功"],
        "import.failed": [.english: "Import failed", .vietnamese: "Nhập thất bại", .chinese: "导入失败"],
        
        // Menu Bar
        "menubar.running": [.english: "Proxy Running", .vietnamese: "Proxy đang chạy", .chinese: "代理运行中"],
        "menubar.stopped": [.english: "Proxy Stopped", .vietnamese: "Proxy đã dừng", .chinese: "代理已停止"],
        "menubar.accounts": [.english: "Accounts", .vietnamese: "Tài khoản", .chinese: "账户"],
        "menubar.requests": [.english: "Requests", .vietnamese: "Yêu cầu", .chinese: "请求"],
        "menubar.success": [.english: "Success", .vietnamese: "Thành công", .chinese: "成功"],
        "menubar.providers": [.english: "Providers", .vietnamese: "Nhà cung cấp", .chinese: "提供商"],
        "menubar.noProviders": [.english: "No providers connected", .vietnamese: "Chưa kết nối nhà cung cấp", .chinese: "未连接提供商"],
        "menubar.andMore": [.english: "+{count} more...", .vietnamese: "+{count} nữa...", .chinese: "+{count} 更多..."],
        "menubar.openApp": [.english: "Open Quotio", .vietnamese: "Mở Quotio", .chinese: "打开 Quotio"],
        "menubar.quit": [.english: "Quit Quotio", .vietnamese: "Thoát Quotio", .chinese: "退出 Quotio"],
        "menubar.quota": [.english: "Quota Usage", .vietnamese: "Sử dụng hạn mức", .chinese: "配额使用"],
        
        // Menu Bar Settings
        "settings.menubar": [.english: "Menu Bar", .vietnamese: "Thanh Menu", .chinese: "菜单栏"],
        "settings.menubar.showIcon": [.english: "Show Menu Bar Icon", .vietnamese: "Hiển thị icon trên Menu Bar", .chinese: "显示菜单栏图标"],
        "settings.menubar.showQuota": [.english: "Show Quota in Menu Bar", .vietnamese: "Hiển thị Quota trên Menu Bar", .chinese: "在菜单栏显示配额"],
        "settings.menubar.colorMode": [.english: "Color Mode", .vietnamese: "Chế độ màu", .chinese: "颜色模式"],
        "settings.menubar.colored": [.english: "Colored", .vietnamese: "Có màu", .chinese: "彩色"],
        "settings.menubar.monochrome": [.english: "Monochrome", .vietnamese: "Trắng đen", .chinese: "单色"],
        "settings.menubar.selectAccounts": [.english: "Select Accounts to Display", .vietnamese: "Chọn tài khoản hiển thị", .chinese: "选择要显示的账户"],
        "settings.menubar.selected": [.english: "Displayed", .vietnamese: "Đang hiển thị", .chinese: "已显示"],
        "settings.menubar.noQuotaData": [.english: "No quota data available. Add accounts with quota support.", .vietnamese: "Không có dữ liệu quota. Thêm tài khoản hỗ trợ quota.", .chinese: "无配额数据可用。添加支持配额的账户。"],
        "settings.menubar.help": [.english: "Choose which accounts to show in the menu bar. Maximum 3 items will be displayed.", .vietnamese: "Chọn tài khoản muốn hiển thị trên thanh menu. Tối đa 3 mục.", .chinese: "选择要在菜单栏显示的账户。最多显示 3 项。"],
        
        "menubar.showOnMenuBar": [.english: "Show on Menu Bar", .vietnamese: "Hiển thị trên Menu Bar", .chinese: "在菜单栏显示"],
        "menubar.hideFromMenuBar": [.english: "Hide from Menu Bar", .vietnamese: "Ẩn khỏi Menu Bar", .chinese: "从菜单栏隐藏"],
        "menubar.limitReached": [.english: "Menu bar limit reached", .vietnamese: "Đã đạt giới hạn Menu Bar", .chinese: "已达到菜单栏限制"],
        
        "menubar.warning.title": [.english: "Too Many Items", .vietnamese: "Quá nhiều mục", .chinese: "项目过多"],
        "menubar.warning.message": [.english: "Displaying more than 3 items may make the menu bar cluttered. Are you sure you want to continue?", .vietnamese: "Hiển thị hơn 3 mục có thể làm thanh menu lộn xộn. Bạn có chắc muốn tiếp tục?", .chinese: "显示超过 3 项可能会使菜单栏混乱。您确定要继续吗？"],
        "menubar.warning.confirm": [.english: "Add Anyway", .vietnamese: "Vẫn thêm", .chinese: "仍然添加"],
        "menubar.warning.cancel": [.english: "Cancel", .vietnamese: "Hủy", .chinese: "取消"],
        
        "menubar.info.title": [.english: "Menu Bar Display", .vietnamese: "Hiển thị Menu Bar", .chinese: "菜单栏显示"],
        "menubar.info.description": [.english: "Click the chart icon to toggle displaying this account's quota in the menu bar.", .vietnamese: "Nhấn vào biểu tượng biểu đồ để bật/tắt hiển thị quota của tài khoản này trên menu bar.", .chinese: "点击图表图标以切换在菜单栏中显示此账户的配额。"],
        "menubar.info.enabled": [.english: "Showing in menu bar", .vietnamese: "Đang hiển thị trên menu bar", .chinese: "在菜单栏中显示"],
        "menubar.info.disabled": [.english: "Not showing in menu bar", .vietnamese: "Không hiển thị trên menu bar", .chinese: "不在菜单栏中显示"],
        "menubar.hint": [.english: "Click the chart icon to toggle menu bar display", .vietnamese: "Nhấn biểu tượng biểu đồ để bật/tắt hiển thị trên menu bar", .chinese: "点击图表图标以切换菜单栏显示"],
        
        // Quota Display Mode Settings
        "settings.quota.display": [.english: "Quota Display", .vietnamese: "Hiển thị Quota", .chinese: "配额显示"],
        "settings.quota.display.help": [.english: "Choose how to display quota percentages across the app.", .vietnamese: "Chọn cách hiển thị phần trăm quota trong ứng dụng.", .chinese: "选择如何在应用中显示配额百分比。"],
        "settings.quota.displayMode": [.english: "Display Mode", .vietnamese: "Chế độ hiển thị", .chinese: "显示模式"],
        "settings.quota.displayMode.used": [.english: "Used", .vietnamese: "Đã dùng", .chinese: "已使用"],
        "settings.quota.displayMode.remaining": [.english: "Remaining", .vietnamese: "Còn lại", .chinese: "剩余"],
        "settings.quota.used": [.english: "used", .vietnamese: "đã dùng", .chinese: "已使用"],
        "settings.quota.left": [.english: "left", .vietnamese: "còn lại", .chinese: "剩余"],
        
        // Notifications
        "settings.notifications": [.english: "Notifications", .vietnamese: "Thông báo", .chinese: "通知"],
        "settings.notifications.enabled": [.english: "Enable Notifications", .vietnamese: "Bật thông báo", .chinese: "启用通知"],
        "settings.notifications.quotaLow": [.english: "Quota Low Warning", .vietnamese: "Cảnh báo hạn mức thấp", .chinese: "配额低警告"],
        "settings.notifications.cooling": [.english: "Account Cooling Alert", .vietnamese: "Cảnh báo tài khoản đang nghỉ", .chinese: "账户冷却警报"],
        "settings.notifications.proxyCrash": [.english: "Proxy Crash Alert", .vietnamese: "Cảnh báo proxy bị lỗi", .chinese: "代理崩溃警报"],
        "settings.notifications.upgradeAvailable": [.english: "Proxy Update Available", .vietnamese: "Có bản cập nhật Proxy", .chinese: "代理更新可用"],
        "settings.notifications.threshold": [.english: "Alert Threshold", .vietnamese: "Ngưỡng cảnh báo", .chinese: "警报阈值"],
        "settings.notifications.help": [.english: "Get notified when quota is low, accounts enter cooling, proxy crashes, or updates are available", .vietnamese: "Nhận thông báo khi hạn mức thấp, tài khoản đang nghỉ, proxy bị lỗi, hoặc có bản cập nhật", .chinese: "当配额低、账户进入冷却、代理崩溃或有更新可用时收到通知"],
        "settings.notifications.notAuthorized": [.english: "Notifications not authorized. Enable in System Settings.", .vietnamese: "Thông báo chưa được cấp quyền. Bật trong Cài đặt hệ thống.", .chinese: "通知未授权。在系统设置中启用。"],
        
        "notification.quotaLow.title": [.english: "⚠️ Quota Low", .vietnamese: "⚠️ Hạn mức thấp", .chinese: "⚠️ 配额低"],
        "notification.quotaLow.body": [.english: "%@ (%@): Only %d%% quota remaining", .vietnamese: "%@ (%@): Chỉ còn %d%% hạn mức", .chinese: "%@ (%@)：仅剩 %d%% 配额"],
        "notification.cooling.title": [.english: "❄️ Account Cooling", .vietnamese: "❄️ Tài khoản đang nghỉ", .chinese: "❄️ 账户冷却"],
        "notification.cooling.body": [.english: "%@ (%@) has entered cooling status", .vietnamese: "%@ (%@) đã vào trạng thái nghỉ", .chinese: "%@ (%@) 已进入冷却状态"],
        "notification.proxyCrash.title": [.english: "🚨 Proxy Crashed", .vietnamese: "🚨 Proxy bị lỗi", .chinese: "🚨 代理崩溃"],
        "notification.proxyCrash.body": [.english: "Proxy process exited with code %d", .vietnamese: "Tiến trình proxy đã thoát với mã %d", .chinese: "代理进程退出，代码 %d"],
        "notification.proxyStarted.title": [.english: "✅ Proxy Started", .vietnamese: "✅ Proxy đã khởi động", .chinese: "✅ 代理已启动"],
        "notification.proxyStarted.body": [.english: "Proxy server is now running", .vietnamese: "Máy chủ proxy đang chạy", .chinese: "代理服务器正在运行"],
        "notification.upgradeAvailable.title": [.english: "🆕 Proxy Update Available", .vietnamese: "🆕 Có bản cập nhật Proxy", .chinese: "🆕 代理更新可用"],
        "notification.upgradeAvailable.body": [.english: "CLIProxyAPI v%@ is available. Open Settings to update.", .vietnamese: "CLIProxyAPI v%@ đã có. Mở Cài đặt để cập nhật.", .chinese: "CLIProxyAPI v%@ 可用。打开设置进行更新。"],
        
        // Agent Setup
        "nav.agents": [.english: "Agents", .vietnamese: "Agent", .chinese: "代理"],
        "agents.title": [.english: "AI Agent Setup", .vietnamese: "Cài đặt AI Agent", .chinese: "AI 代理设置"],
        "agents.subtitle": [.english: "Configure CLI agents to use CLIProxyAPI", .vietnamese: "Cấu hình CLI agent để sử dụng CLIProxyAPI", .chinese: "配置 CLI 代理以使用 CLIProxyAPI"],
        "agents.installed": [.english: "Installed", .vietnamese: "Đã cài đặt", .chinese: "已安装"],
        "agents.notInstalled": [.english: "Not Installed", .vietnamese: "Chưa cài đặt", .chinese: "未安装"],
        "agents.configured": [.english: "Configured", .vietnamese: "Đã cấu hình", .chinese: "已配置"],
        "agents.configure": [.english: "Configure", .vietnamese: "Cấu hình", .chinese: "配置"],
        "agents.reconfigure": [.english: "Reconfigure", .vietnamese: "Cấu hình lại", .chinese: "重新配置"],
        "agents.test": [.english: "Test Connection", .vietnamese: "Kiểm tra kết nối", .chinese: "测试连接"],
        "agents.docs": [.english: "Documentation", .vietnamese: "Tài liệu", .chinese: "文档"],
        
        // Configuration Modes
        "agents.mode": [.english: "Configuration Mode", .vietnamese: "Chế độ cấu hình", .chinese: "配置模式"],
        "agents.mode.automatic": [.english: "Automatic", .vietnamese: "Tự động", .chinese: "自动"],
        "agents.mode.manual": [.english: "Manual", .vietnamese: "Thủ công", .chinese: "手动"],
        "agents.mode.automatic.desc": [.english: "Directly update config files and shell profile", .vietnamese: "Tự động cập nhật file cấu hình và shell profile", .chinese: "直接更新配置文件和 shell 配置文件"],
        "agents.mode.manual.desc": [.english: "View and copy configuration manually", .vietnamese: "Xem và sao chép cấu hình thủ công", .chinese: "手动查看和复制配置"],
        "agents.applyConfig": [.english: "Apply Configuration", .vietnamese: "Áp dụng cấu hình", .chinese: "应用配置"],
        "agents.generateConfig": [.english: "Generate Configuration", .vietnamese: "Tạo cấu hình", .chinese: "生成配置"],
        "agents.configGenerated": [.english: "Configuration Generated", .vietnamese: "Đã tạo cấu hình", .chinese: "配置已生成"],
        "agents.copyInstructions": [.english: "Copy the configuration below and apply manually", .vietnamese: "Sao chép cấu hình bên dưới và áp dụng thủ công", .chinese: "复制下面的配置并手动应用"],
        
        // Model Slots
        "agents.modelSlots": [.english: "Model Slots", .vietnamese: "Slot mô hình", .chinese: "模型槽"],
        "agents.modelSlots.opus": [.english: "Opus (High Intelligence)", .vietnamese: "Opus (Thông minh cao)", .chinese: "Opus（高智能）"],
        "agents.modelSlots.sonnet": [.english: "Sonnet (Balanced)", .vietnamese: "Sonnet (Cân bằng)", .chinese: "Sonnet（平衡）"],
        "agents.modelSlots.haiku": [.english: "Haiku (Fast)", .vietnamese: "Haiku (Nhanh)", .chinese: "Haiku（快速）"],
        "agents.selectModel": [.english: "Select Model", .vietnamese: "Chọn mô hình", .chinese: "选择模型"],
        
        // Config Types
        "agents.config.env": [.english: "Environment Variables", .vietnamese: "Biến môi trường", .chinese: "环境变量"],
        "agents.config.file": [.english: "Configuration Files", .vietnamese: "Tệp cấu hình", .chinese: "配置文件"],
        "agents.copyConfig": [.english: "Copy to Clipboard", .vietnamese: "Sao chép", .chinese: "复制到剪贴板"],
        "agents.addToShell": [.english: "Add to Shell Profile", .vietnamese: "Thêm vào Shell Profile", .chinese: "添加到 Shell 配置文件"],
        "agents.shellAdded": [.english: "Added to shell profile", .vietnamese: "Đã thêm vào shell profile", .chinese: "已添加到 shell 配置文件"],
        "agents.copied": [.english: "Copied to clipboard", .vietnamese: "Đã sao chép", .chinese: "已复制"],
        
        // Status Messages
        "agents.configSuccess": [.english: "Configuration complete!", .vietnamese: "Cấu hình hoàn tất!", .chinese: "配置完成！"],
        "agents.configFailed": [.english: "Configuration failed", .vietnamese: "Cấu hình thất bại", .chinese: "配置失败"],
        "agents.testSuccess": [.english: "Connection successful!", .vietnamese: "Kết nối thành công!", .chinese: "连接成功！"],
        "agents.testFailed": [.english: "Connection failed", .vietnamese: "Kết nối thất bại", .chinese: "连接失败"],
        
        // Instructions
        "agents.instructions.restart": [.english: "Restart your terminal for changes to take effect", .vietnamese: "Khởi động lại terminal để thay đổi có hiệu lực", .chinese: "重启终端以使更改生效"],
        "agents.instructions.env": [.english: "Add these environment variables to your shell profile:", .vietnamese: "Thêm các biến môi trường này vào shell profile:", .chinese: "将这些环境变量添加到您的 shell 配置文件："],
        "agents.instructions.file": [.english: "Configuration files have been created:", .vietnamese: "Các tệp cấu hình đã được tạo:", .chinese: "配置文件已创建："],
        "agents.proxyNotRunning": [.english: "Start the proxy to configure agents", .vietnamese: "Khởi động proxy để cấu hình agent", .chinese: "启动代理以配置代理"],
        "agents.proxyRequired.title": [.english: "Proxy Required", .vietnamese: "Cần khởi động Proxy", .chinese: "需要代理"],
        "agents.proxyRequired.message": [.english: "The proxy server must be running to configure agents. Start the proxy first.", .vietnamese: "Cần khởi động proxy để cấu hình agent. Hãy khởi động proxy trước.", .chinese: "必须运行代理服务器才能配置代理。请先启动代理。"],
        
        // Auth Modes
        "agents.oauthMode": [.english: "Use OAuth Authentication", .vietnamese: "Sử dụng xác thực OAuth", .chinese: "使用 OAuth 认证"],
        "agents.apiKeyMode": [.english: "Use API Key Authentication", .vietnamese: "Sử dụng xác thực API Key", .chinese: "使用 API 密钥认证"],
        
        // Agent Config Sheet
        "agents.configMode": [.english: "Configuration Mode", .vietnamese: "Chế độ cấu hình", .chinese: "配置模式"],
        "agents.connectionInfo": [.english: "Connection Info", .vietnamese: "Thông tin kết nối", .chinese: "连接信息"],
        "agents.proxyURL": [.english: "Proxy URL", .vietnamese: "URL Proxy", .chinese: "代理 URL"],
        "agents.apiKey": [.english: "API Key", .vietnamese: "Khóa API", .chinese: "API 密钥"],
        "agents.shell": [.english: "Shell", .vietnamese: "Shell", .chinese: "Shell"],
        "agents.modelSlotsDesc": [.english: "Configure which models to use for each slot", .vietnamese: "Cấu hình mô hình sử dụng cho mỗi slot", .chinese: "配置每个槽使用的模型"],
        "agents.useOAuth": [.english: "Use OAuth Authentication", .vietnamese: "Sử dụng xác thực OAuth", .chinese: "使用 OAuth 认证"],
        "agents.useOAuthDesc": [.english: "Use your existing Google OAuth credentials", .vietnamese: "Sử dụng thông tin đăng nhập Google OAuth hiện có", .chinese: "使用您现有的 Google OAuth 凭据"],
        "agents.testConnection": [.english: "Test Connection", .vietnamese: "Kiểm tra kết nối", .chinese: "测试连接"],
        "agents.filesModified": [.english: "Files Modified", .vietnamese: "Các tệp đã thay đổi", .chinese: "已修改的文件"],
        "agents.rawConfigs": [.english: "Raw Configurations", .vietnamese: "Cấu hình thô", .chinese: "原始配置"],
        "agents.apply": [.english: "Apply", .vietnamese: "Áp dụng", .chinese: "应用"],
        "agents.generate": [.english: "Generate", .vietnamese: "Tạo", .chinese: "生成"],
        "agents.viewDocs": [.english: "View Docs", .vietnamese: "Xem tài liệu", .chinese: "查看文档"],
        
        // Actions (more)
        "action.copyAll": [.english: "Copy All", .vietnamese: "Sao chép tất cả", .chinese: "全部复制"],
        "action.done": [.english: "Done", .vietnamese: "Xong", .chinese: "完成"],
        "action.cancel": [.english: "Cancel", .vietnamese: "Hủy", .chinese: "取消"],
        "agents.saveConfig": [.english: "Save Config", .vietnamese: "Lưu cấu hình", .chinese: "保存配置"],
        
        // Storage Options
        "agents.storageOption": [.english: "Storage Location", .vietnamese: "Vị trí lưu trữ", .chinese: "存储位置"],
        "agents.storage.jsonOnly": [.english: "JSON Config", .vietnamese: "JSON Config", .chinese: "JSON 配置"],
        "agents.storage.shellOnly": [.english: "Shell Profile", .vietnamese: "Shell Profile", .chinese: "Shell 配置文件"],
        "agents.storage.both": [.english: "Both", .vietnamese: "Cả hai", .chinese: "两者"],
        
        // Updates
        "settings.updates": [.english: "Updates", .vietnamese: "Cập nhật", .chinese: "更新"],
        "settings.autoCheckUpdates": [.english: "Automatically check for updates", .vietnamese: "Tự động kiểm tra cập nhật", .chinese: "自动检查更新"],
        "settings.lastChecked": [.english: "Last checked", .vietnamese: "Lần kiểm tra cuối", .chinese: "上次检查"],
        "settings.never": [.english: "Never", .vietnamese: "Chưa bao giờ", .chinese: "从未"],
        "settings.checkNow": [.english: "Check Now", .vietnamese: "Kiểm tra ngay", .chinese: "立即检查"],
        "settings.version": [.english: "Version", .vietnamese: "Phiên bản", .chinese: "版本"],
        
        // Proxy Updates
        "settings.proxyUpdate": [.english: "Proxy Updates", .vietnamese: "Cập nhật Proxy", .chinese: "代理更新"],
        "settings.proxyUpdate.currentVersion": [.english: "Current Version", .vietnamese: "Phiên bản hiện tại", .chinese: "当前版本"],
        "settings.proxyUpdate.unknown": [.english: "Unknown", .vietnamese: "Không xác định", .chinese: "未知"],
        "settings.proxyUpdate.available": [.english: "Update Available", .vietnamese: "Có bản cập nhật", .chinese: "有可用更新"],
        "settings.proxyUpdate.upToDate": [.english: "Up to date", .vietnamese: "Đã cập nhật", .chinese: "已是最新"],
        "settings.proxyUpdate.checkNow": [.english: "Check for Updates", .vietnamese: "Kiểm tra cập nhật", .chinese: "检查更新"],
        "settings.proxyUpdate.proxyMustRun": [.english: "Proxy must be running to check for updates", .vietnamese: "Proxy phải đang chạy để kiểm tra cập nhật", .chinese: "代理必须运行才能检查更新"],
        "settings.proxyUpdate.help": [.english: "Managed updates with dry-run validation ensure safe upgrades", .vietnamese: "Cập nhật có kiểm soát với xác thực thử nghiệm đảm bảo nâng cấp an toàn", .chinese: "具有预演验证的托管更新可确保安全升级"],
        
        // Proxy Updates - Advanced Mode
        "settings.proxyUpdate.advanced": [.english: "Advanced", .vietnamese: "Nâng cao", .chinese: "高级"],
        "settings.proxyUpdate.advanced.title": [.english: "Version Manager", .vietnamese: "Quản lý phiên bản", .chinese: "版本管理器"],
        "settings.proxyUpdate.advanced.description": [.english: "Install a specific proxy version", .vietnamese: "Cài đặt phiên bản proxy cụ thể", .chinese: "安装特定的代理版本"],
        "settings.proxyUpdate.advanced.availableVersions": [.english: "Available Versions", .vietnamese: "Phiên bản khả dụng", .chinese: "可用版本"],
        "settings.proxyUpdate.advanced.installedVersions": [.english: "Installed Versions", .vietnamese: "Phiên bản đã cài", .chinese: "已安装版本"],
        "settings.proxyUpdate.advanced.current": [.english: "Current", .vietnamese: "Hiện tại", .chinese: "当前"],
        "settings.proxyUpdate.advanced.install": [.english: "Install", .vietnamese: "Cài đặt", .chinese: "安装"],
        "settings.proxyUpdate.advanced.activate": [.english: "Activate", .vietnamese: "Kích hoạt", .chinese: "激活"],
        "settings.proxyUpdate.advanced.delete": [.english: "Delete", .vietnamese: "Xóa", .chinese: "删除"],
        "settings.proxyUpdate.advanced.prerelease": [.english: "Pre-release", .vietnamese: "Thử nghiệm", .chinese: "预发布"],
        "settings.proxyUpdate.advanced.loading": [.english: "Loading releases...", .vietnamese: "Đang tải danh sách...", .chinese: "正在加载版本..."],
        "settings.proxyUpdate.advanced.noReleases": [.english: "No releases found", .vietnamese: "Không tìm thấy phiên bản", .chinese: "未找到版本"],
        "settings.proxyUpdate.advanced.installed": [.english: "Installed", .vietnamese: "Đã cài", .chinese: "已安装"],
        "settings.proxyUpdate.advanced.installing": [.english: "Installing...", .vietnamese: "Đang cài đặt...", .chinese: "正在安装..."],
        "settings.proxyUpdate.advanced.fetchError": [.english: "Failed to fetch releases", .vietnamese: "Không thể tải danh sách phiên bản", .chinese: "无法获取版本"],
        
        // About Screen
        "about.tagline": [.english: "Your AI Coding Command Center", .vietnamese: "Trung tâm điều khiển AI Coding của bạn", .chinese: "您的 AI 编码指挥中心"],
        "about.description": [.english: "Quotio is a native macOS application for managing CLIProxyAPI - a local proxy server that powers your AI coding agents. Manage multiple AI accounts, track quotas, and configure CLI tools in one place.", .vietnamese: "Quotio là ứng dụng macOS để quản lý CLIProxyAPI - máy chủ proxy cục bộ hỗ trợ các AI coding agent. Quản lý nhiều tài khoản AI, theo dõi hạn mức và cấu hình các công cụ CLI tại một nơi.", .chinese: "Quotio 是一个原生 macOS 应用程序，用于管理 CLIProxyAPI - 一个为您的 AI 编码代理提供支持的本地代理服务器。在一个地方管理多个 AI 账户、跟踪配额和配置 CLI 工具。"],
        "about.multiAccount": [.english: "Multi-Account", .vietnamese: "Đa tài khoản", .chinese: "多账户"],
        "about.quotaTracking": [.english: "Quota Tracking", .vietnamese: "Theo dõi quota", .chinese: "配额跟踪"],
        "about.agentConfig": [.english: "Agent Config", .vietnamese: "Cấu hình Agent", .chinese: "代理配置"],
        "about.buyMeCoffee": [.english: "Buy Me a Coffee", .vietnamese: "Mua cho tôi ly cà phê", .chinese: "请我喝咖啡"],
        "about.support": [.english: "Support Us", .vietnamese: "Ủng hộ", .chinese: "支持我们"],
        "about.madeWith": [.english: "Made with ❤️ in Vietnam", .vietnamese: "Được tạo với ❤️ tại Việt Nam", .chinese: "用 ❤️ 在越南制作"],
        
        // Onboarding
        "onboarding.installCLI": [.english: "Install CLIProxyAPI", .vietnamese: "Cài đặt CLIProxyAPI", .chinese: "安装 CLIProxyAPI"],
        "onboarding.installCLIDesc": [.english: "Download the proxy binary to get started", .vietnamese: "Tải xuống binary proxy để bắt đầu", .chinese: "下载代理二进制文件以开始"],
        "onboarding.startProxy": [.english: "Start Proxy Server", .vietnamese: "Khởi động Proxy Server", .chinese: "启动代理服务器"],
        "onboarding.startProxyDesc": [.english: "Start the local proxy to connect AI providers", .vietnamese: "Khởi động proxy cục bộ để kết nối các nhà cung cấp AI", .chinese: "启动本地代理以连接 AI 提供商"],
        "onboarding.addProvider": [.english: "Connect AI Provider", .vietnamese: "Kết nối nhà cung cấp AI", .chinese: "连接 AI 提供商"],
        "onboarding.addProviderDesc": [.english: "Add at least one AI provider account", .vietnamese: "Thêm ít nhất một tài khoản nhà cung cấp AI", .chinese: "至少添加一个 AI 提供商账户"],
        "onboarding.connectAccount": [.english: "Connect Account", .vietnamese: "Kết nối tài khoản", .chinese: "连接账户"],
        "onboarding.configureAgent": [.english: "Configure CLI Agent", .vietnamese: "Cấu hình CLI Agent", .chinese: "配置 CLI 代理"],
        "onboarding.configureAgentDesc": [.english: "Set up your AI coding assistant", .vietnamese: "Thiết lập trợ lý AI coding của bạn", .chinese: "设置您的 AI 编码助手"],
        "onboarding.complete": [.english: "You're All Set!", .vietnamese: "Đã sẵn sàng!", .chinese: "一切就绪！"],
        "onboarding.completeDesc": [.english: "Quotio is ready to supercharge your AI coding", .vietnamese: "Quotio đã sẵn sàng tăng cường AI coding của bạn", .chinese: "Quotio 已准备好增强您的 AI 编码"],
        "onboarding.skip": [.english: "Skip Setup", .vietnamese: "Bỏ qua", .chinese: "跳过设置"],
        "onboarding.goToDashboard": [.english: "Go to Dashboard", .vietnamese: "Đến Dashboard", .chinese: "前往仪表板"],
        "onboarding.providersConfigured": [.english: "providers connected", .vietnamese: "nhà cung cấp đã kết nối", .chinese: "已连接提供商"],
        "onboarding.agentsConfigured": [.english: "agents configured", .vietnamese: "agent đã cấu hình", .chinese: "已配置代理"],
        
        // Dashboard
        "dashboard.gettingStarted": [.english: "Getting Started", .vietnamese: "Bắt đầu", .chinese: "入门"],
        "action.dismiss": [.english: "Dismiss", .vietnamese: "Ẩn", .chinese: "关闭"],
        
        // Quota-Only Mode - New Keys
        "nav.accounts": [.english: "Accounts", .vietnamese: "Tài khoản", .chinese: "账户"],
        "dashboard.trackedAccounts": [.english: "Tracked Accounts", .vietnamese: "Tài khoản theo dõi", .chinese: "跟踪的账户"],
        "dashboard.connected": [.english: "connected", .vietnamese: "đã kết nối", .chinese: "已连接"],
        "dashboard.lowestQuota": [.english: "Lowest Quota", .vietnamese: "Quota thấp nhất", .chinese: "最低配额"],
        "dashboard.remaining": [.english: "remaining", .vietnamese: "còn lại", .chinese: "剩余"],
        "dashboard.lastRefresh": [.english: "Last Refresh", .vietnamese: "Cập nhật lần cuối", .chinese: "上次刷新"],
        "dashboard.updated": [.english: "updated", .vietnamese: "đã cập nhật", .chinese: "已更新"],
        "dashboard.noQuotaData": [.english: "No quota data yet", .vietnamese: "Chưa có dữ liệu quota", .chinese: "暂无配额数据"],
        "dashboard.quotaOverview": [.english: "Quota Overview", .vietnamese: "Tổng quan Quota", .chinese: "配额概览"],
        "dashboard.noAccountsTracked": [.english: "No accounts tracked", .vietnamese: "Chưa theo dõi tài khoản nào", .chinese: "未跟踪账户"],
        "dashboard.addAccountsHint": [.english: "Add provider accounts to start tracking quotas", .vietnamese: "Thêm tài khoản nhà cung cấp để bắt đầu theo dõi quota", .chinese: "添加提供商账户以开始跟踪配额"],
        
        // Providers - Quota-Only Mode
        "providers.noAccountsFound": [.english: "No accounts found", .vietnamese: "Không tìm thấy tài khoản", .chinese: "未找到账户"],
        "providers.quotaOnlyHint": [.english: "Auth files will be detected from ~/.cli-proxy-api and native CLI locations", .vietnamese: "File xác thực sẽ được phát hiện từ ~/.cli-proxy-api và các vị trí CLI gốc", .chinese: "将从 ~/.cli-proxy-api 和本地 CLI 位置检测认证文件"],
        "providers.trackedAccounts": [.english: "Tracked Accounts", .vietnamese: "Tài khoản theo dõi", .chinese: "跟踪的账户"],
        
        // Empty States - New
        "empty.noQuotaData": [.english: "No Quota Data", .vietnamese: "Chưa có dữ liệu Quota", .chinese: "无配额数据"],
        "empty.refreshToLoad": [.english: "Refresh to load quota information", .vietnamese: "Làm mới để tải thông tin quota", .chinese: "刷新以加载配额信息"],
        
        // Menu Bar - Quota Mode
        "menubar.quotaMode": [.english: "Quota Monitor", .vietnamese: "Theo dõi Quota", .chinese: "配额监控"],
        "menubar.trackedAccounts": [.english: "Tracked Accounts", .vietnamese: "Tài khoản theo dõi", .chinese: "跟踪的账户"],
        "menubar.noAccountsFound": [.english: "No accounts found", .vietnamese: "Không tìm thấy tài khoản", .chinese: "未找到账户"],
        "menubar.noData": [.english: "No quota data available", .vietnamese: "Chưa có dữ liệu quota", .chinese: "无可用配额数据"],
        
        // Menu Bar - Tooltips
        "menubar.tooltip.openApp": [.english: "Open main window (⌘O)", .vietnamese: "Mở cửa sổ chính (⌘O)", .chinese: "打开主窗口 (⌘O)"],
        "menubar.tooltip.quit": [.english: "Quit Quotio (⌘Q)", .vietnamese: "Thoát Quotio (⌘Q)", .chinese: "退出 Quotio (⌘Q)"],
        
        // Actions - New
        "action.refreshQuota": [.english: "Refresh Quota", .vietnamese: "Làm mới Quota", .chinese: "刷新配额"],
        "action.switch": [.english: "Switch", .vietnamese: "Chuyển", .chinese: "切换"],
        "action.update": [.english: "Update", .vietnamese: "Cập nhật", .chinese: "更新"],
        
        // Status - New
        "status.refreshing": [.english: "Refreshing...", .vietnamese: "Đang làm mới...", .chinese: "刷新中..."],
        "status.notRefreshed": [.english: "Not refreshed", .vietnamese: "Chưa làm mới", .chinese: "未刷新"],
        
        // Settings - App Mode
        "settings.appMode": [.english: "App Mode", .vietnamese: "Chế độ ứng dụng", .chinese: "应用模式"],
        "settings.appMode.quotaOnlyNote": [.english: "Proxy server is disabled in Quota Monitor mode", .vietnamese: "Máy chủ proxy bị tắt trong chế độ Theo dõi Quota", .chinese: "配额监控模式下代理服务器已禁用"],
        "settings.appMode.switchConfirmTitle": [.english: "Switch to Quota Monitor Mode?", .vietnamese: "Chuyển sang chế độ Theo dõi Quota?", .chinese: "切换到配额监控模式？"],
        "settings.appMode.switchConfirmMessage": [.english: "This will stop the proxy server if running. You can switch back anytime.", .vietnamese: "Điều này sẽ dừng máy chủ proxy nếu đang chạy. Bạn có thể chuyển lại bất cứ lúc nào.", .chinese: "如果正在运行，这将停止代理服务器。您可以随时切换回来。"],
        
        // Appearance Mode
        "settings.appearance.title": [.english: "Appearance", .vietnamese: "Giao diện", .chinese: "外观"],
        "settings.appearance.mode": [.english: "Theme", .vietnamese: "Chủ đề", .chinese: "主题"],
        "settings.appearance.system": [.english: "System", .vietnamese: "Hệ thống", .chinese: "系统"],
        "settings.appearance.light": [.english: "Light", .vietnamese: "Sáng", .chinese: "浅色"],
        "settings.appearance.dark": [.english: "Dark", .vietnamese: "Tối", .chinese: "深色"],
        "settings.appearance.help": [.english: "Choose how the app looks. System will automatically match your Mac's appearance.", .vietnamese: "Chọn giao diện cho ứng dụng. Hệ thống sẽ tự động theo giao diện của Mac.", .chinese: "选择应用的外观。系统将自动匹配您 Mac 的外观。"],
        
        // IDE Scan (Issue #29 - Privacy)
        "ideScan.title": [.english: "Scan for Installed IDEs", .vietnamese: "Quét IDE đã cài đặt", .chinese: "扫描已安装的 IDE"],
        "ideScan.subtitle": [.english: "Detect IDEs and CLI tools to track their quotas", .vietnamese: "Phát hiện IDE và công cụ CLI để theo dõi quota", .chinese: "检测 IDE 和 CLI 工具以跟踪其配额"],
        "ideScan.privacyNotice": [.english: "Privacy Notice", .vietnamese: "Thông báo bảo mật", .chinese: "隐私通知"],
        "ideScan.privacyDescription": [.english: "This will access files from other applications to detect installed IDEs and their authentication status. No data is sent externally.", .vietnamese: "Thao tác này sẽ truy cập file từ các ứng dụng khác để phát hiện IDE đã cài đặt và trạng thái xác thực. Không có dữ liệu nào được gửi ra ngoài.", .chinese: "这将访问其他应用程序的文件以检测已安装的 IDE 及其认证状态。不会对外发送任何数据。"],
        "ideScan.selectSources": [.english: "Select Data Sources", .vietnamese: "Chọn nguồn dữ liệu", .chinese: "选择数据源"],
        "ideScan.cursor.detail": [.english: "Reads ~/Library/Application Support/Cursor/", .vietnamese: "Đọc ~/Library/Application Support/Cursor/", .chinese: "读取 ~/Library/Application Support/Cursor/"],
        "ideScan.trae.detail": [.english: "Reads ~/Library/Application Support/Trae/", .vietnamese: "Đọc ~/Library/Application Support/Trae/", .chinese: "读取 ~/Library/Application Support/Trae/"],
        "ideScan.cliTools": [.english: "CLI Tools (claude, codex, gemini...)", .vietnamese: "Công cụ CLI (claude, codex, gemini...)", .chinese: "CLI 工具（claude、codex、gemini...）"],
        "ideScan.cliTools.detail": [.english: "Uses 'which' command to find installed tools", .vietnamese: "Sử dụng lệnh 'which' để tìm công cụ đã cài", .chinese: "使用 'which' 命令查找已安装的工具"],
        "ideScan.scanNow": [.english: "Scan Now", .vietnamese: "Quét ngay", .chinese: "立即扫描"],
        "ideScan.scanning": [.english: "Scanning...", .vietnamese: "Đang quét...", .chinese: "扫描中..."],
        "ideScan.complete": [.english: "Scan Complete", .vietnamese: "Quét hoàn tất", .chinese: "扫描完成"],
        "ideScan.notFound": [.english: "Not found", .vietnamese: "Không tìm thấy", .chinese: "未找到"],
        "ideScan.error": [.english: "Scan Error", .vietnamese: "Lỗi quét", .chinese: "扫描错误"],
        "ideScan.buttonSubtitle": [.english: "Detect Cursor, Trae, and CLI tools", .vietnamese: "Phát hiện Cursor, Trae và công cụ CLI", .chinese: "检测 Cursor、Trae 和 CLI 工具"],
        "ideScan.sectionTitle": [.english: "Detect IDEs", .vietnamese: "Phát hiện IDE", .chinese: "检测 IDE"],
        "ideScan.sectionFooter": [.english: "Scan for installed IDEs and CLI tools to track their quotas", .vietnamese: "Quét IDE và công cụ CLI đã cài đặt để theo dõi quota", .chinese: "扫描已安装的 IDE 和 CLI 工具以跟踪其配额"],
        
        // Upgrade Notifications
        "notification.upgrade.success.title": [.english: "Proxy Upgraded", .vietnamese: "Đã nâng cấp Proxy", .chinese: "代理已升级"],
        "notification.upgrade.success.body": [.english: "CLIProxyAPI has been upgraded to version %@", .vietnamese: "CLIProxyAPI đã được nâng cấp lên phiên bản %@", .chinese: "CLIProxyAPI 已升级到版本 %@"],
        "notification.upgrade.failed.title": [.english: "Proxy Upgrade Failed", .vietnamese: "Nâng cấp Proxy thất bại", .chinese: "代理升级失败"],
        "notification.upgrade.failed.body": [.english: "Failed to upgrade to version %@: %@", .vietnamese: "Không thể nâng cấp lên phiên bản %@: %@", .chinese: "无法升级到版本 %@：%@"],
        "notification.rollback.title": [.english: "Proxy Rollback", .vietnamese: "Khôi phục Proxy", .chinese: "代理回滚"],
        "notification.rollback.body": [.english: "Rolled back to version %@ due to upgrade failure", .vietnamese: "Đã khôi phục về phiên bản %@ do nâng cấp thất bại", .chinese: "由于升级失败，已回滚到版本 %@"],
        
        // Version Manager - Delete Warning
        "settings.proxyUpdate.deleteWarning.title": [.english: "Old Versions Will Be Deleted", .vietnamese: "Phiên bản cũ sẽ bị xóa", .chinese: "旧版本将被删除"],
        "settings.proxyUpdate.deleteWarning.message": [.english: "Installing this version will delete the following old versions to keep only %d most recent: %@", .vietnamese: "Cài đặt phiên bản này sẽ xóa các phiên bản cũ sau để chỉ giữ lại %d phiên bản gần nhất: %@", .chinese: "安装此版本将删除以下旧版本，仅保留最近的 %d 个：%@"],
        "settings.proxyUpdate.deleteWarning.confirm": [.english: "Install Anyway", .vietnamese: "Vẫn cài đặt", .chinese: "仍然安装"],
        
        // Privacy Settings
        "settings.privacy": [.english: "Privacy", .vietnamese: "Riêng tư", .chinese: "隐私"],
        "settings.privacy.hideSensitive": [.english: "Hide Sensitive Information", .vietnamese: "Ẩn thông tin nhạy cảm", .chinese: "隐藏敏感信息"],
        "settings.privacy.hideSensitiveHelp": [.english: "Masks emails and account names with ● characters across the app", .vietnamese: "Che email và tên tài khoản bằng ký tự ● trong toàn bộ ứng dụng", .chinese: "在应用中使用 ● 字符隐藏邮箱和账户名称"],
    ]
    
    static func get(_ key: String, language: AppLanguage) -> String {
        return strings[key]?[language] ?? strings[key]?[.english] ?? key
    }
}

extension String {
    @MainActor
    func localized() -> String {
        return LanguageManager.shared.localized(self)
    }
}
