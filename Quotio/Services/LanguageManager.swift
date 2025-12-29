//
//  LanguageManager.swift
//  Quotio
//

import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case vietnamese = "vi"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        }
    }
    
    var flag: String {
        switch self {
        case .english: return "🇺🇸"
        case .vietnamese: return "🇻🇳"
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
        "nav.dashboard": [.english: "Dashboard", .vietnamese: "Bảng điều khiển"],
        "nav.quota": [.english: "Quota", .vietnamese: "Hạn mức"],
        "nav.providers": [.english: "Providers", .vietnamese: "Nhà cung cấp"],
        "nav.apiKeys": [.english: "API Keys", .vietnamese: "Khóa API"],
        "nav.logs": [.english: "Logs", .vietnamese: "Nhật ký"],
        "nav.settings": [.english: "Settings", .vietnamese: "Cài đặt"],
        "nav.about": [.english: "About", .vietnamese: "Giới thiệu"],
        
        // Status
        "status.running": [.english: "Running", .vietnamese: "Đang chạy"],
        "status.starting": [.english: "Starting...", .vietnamese: "Đang khởi động..."],
        "status.stopped": [.english: "Stopped", .vietnamese: "Đã dừng"],
        "status.ready": [.english: "Ready", .vietnamese: "Sẵn sàng"],
        "status.cooling": [.english: "Cooling", .vietnamese: "Đang nghỉ"],
        "status.error": [.english: "Error", .vietnamese: "Lỗi"],
        "status.available": [.english: "Available", .vietnamese: "Khả dụng"],
        "status.forbidden": [.english: "Forbidden", .vietnamese: "Bị chặn"],
        
        // Dashboard
        "dashboard.accounts": [.english: "Accounts", .vietnamese: "Tài khoản"],
        "dashboard.ready": [.english: "ready", .vietnamese: "sẵn sàng"],
        "dashboard.requests": [.english: "Requests", .vietnamese: "Yêu cầu"],
        "dashboard.total": [.english: "total", .vietnamese: "tổng"],
        "dashboard.tokens": [.english: "Tokens", .vietnamese: "Token"],
        "dashboard.processed": [.english: "processed", .vietnamese: "đã xử lý"],
        "dashboard.successRate": [.english: "Success Rate", .vietnamese: "Tỷ lệ thành công"],
        "dashboard.failed": [.english: "failed", .vietnamese: "thất bại"],
        "dashboard.providers": [.english: "Providers", .vietnamese: "Nhà cung cấp"],
        "dashboard.apiEndpoint": [.english: "API Endpoint", .vietnamese: "Điểm cuối API"],
        "dashboard.cliNotInstalled": [.english: "CLIProxyAPI Not Installed", .vietnamese: "CLIProxyAPI chưa cài đặt"],
        "dashboard.clickToInstall": [.english: "Click the button below to automatically download and install", .vietnamese: "Nhấn nút bên dưới để tự động tải và cài đặt"],
        "dashboard.installCLI": [.english: "Install CLIProxyAPI", .vietnamese: "Cài đặt CLIProxyAPI"],
        "dashboard.startToBegin": [.english: "Start the proxy server to begin", .vietnamese: "Khởi động máy chủ proxy để bắt đầu"],
        
        // Quota
        "quota.overallStatus": [.english: "Overall Status", .vietnamese: "Trạng thái chung"],
        "quota.providers": [.english: "providers", .vietnamese: "nhà cung cấp"],
        "quota.accounts": [.english: "accounts", .vietnamese: "tài khoản"],
        "quota.account": [.english: "account", .vietnamese: "tài khoản"],
        "quota.accountsReady": [.english: "accounts ready", .vietnamese: "tài khoản sẵn sàng"],
        "quota.used": [.english: "used", .vietnamese: "đã dùng"],
        "quota.reset": [.english: "reset", .vietnamese: "đặt lại"],
        "quota.noDataYet": [.english: "No usage data available", .vietnamese: "Chưa có dữ liệu sử dụng"],
        
        // Providers
        "providers.addProvider": [.english: "Add Provider", .vietnamese: "Thêm nhà cung cấp"],
        "providers.connectedAccounts": [.english: "Connected Accounts", .vietnamese: "Tài khoản đã kết nối"],
        "providers.noAccountsYet": [.english: "No accounts connected yet", .vietnamese: "Chưa có tài khoản nào được kết nối"],
        "providers.startProxyFirst": [.english: "Start the proxy first to manage providers", .vietnamese: "Khởi động proxy trước để quản lý nhà cung cấp"],
        "providers.connect": [.english: "Connect", .vietnamese: "Kết nối"],
        "providers.authenticate": [.english: "Authenticate", .vietnamese: "Xác thực"],
        "providers.cancel": [.english: "Cancel", .vietnamese: "Hủy"],
        "providers.waitingAuth": [.english: "Waiting for authentication...", .vietnamese: "Đang chờ xác thực..."],
        "providers.connectedSuccess": [.english: "Connected successfully!", .vietnamese: "Kết nối thành công!"],
        "providers.authFailed": [.english: "Authentication failed", .vietnamese: "Xác thực thất bại"],
        "providers.projectIdOptional": [.english: "Project ID (optional)", .vietnamese: "ID dự án (tùy chọn)"],
        "providers.disabled": [.english: "Disabled", .vietnamese: "Đã tắt"],
        "providers.autoDetected": [.english: "Auto-detected", .vietnamese: "Tự động phát hiện"],
        "providers.proxyRequired.title": [.english: "Proxy Required", .vietnamese: "Cần khởi động Proxy"],
        "providers.proxyRequired.message": [.english: "The proxy server must be running to add new provider accounts.", .vietnamese: "Cần khởi động proxy để thêm tài khoản nhà cung cấp mới."],
        
        // Settings
        "settings.proxyServer": [.english: "Proxy Server", .vietnamese: "Máy chủ proxy"],
        "settings.port": [.english: "Port", .vietnamese: "Cổng"],
        "settings.endpoint": [.english: "Endpoint", .vietnamese: "Điểm cuối"],
        "settings.status": [.english: "Status", .vietnamese: "Trạng thái"],
        "settings.autoStartProxy": [.english: "Auto-start proxy on launch", .vietnamese: "Tự khởi động proxy khi mở app"],
        "settings.restartProxy": [.english: "Restart proxy after changing port", .vietnamese: "Khởi động lại proxy sau khi đổi cổng"],
        "settings.routingStrategy": [.english: "Routing Strategy", .vietnamese: "Chiến lược định tuyến"],
        "settings.roundRobin": [.english: "Round Robin", .vietnamese: "Xoay vòng"],
        "settings.fillFirst": [.english: "Fill First", .vietnamese: "Dùng hết trước"],
        "settings.roundRobinDesc": [.english: "Distributes requests evenly across all accounts", .vietnamese: "Phân phối yêu cầu đều cho tất cả tài khoản"],
        "settings.fillFirstDesc": [.english: "Uses one account until quota exhausted, then moves to next", .vietnamese: "Dùng một tài khoản đến khi hết hạn mức, rồi chuyển sang tài khoản tiếp"],
        "settings.quotaExceededBehavior": [.english: "Quota Exceeded Behavior", .vietnamese: "Hành vi khi vượt hạn mức"],
        "settings.autoSwitchAccount": [.english: "Auto-switch to another account", .vietnamese: "Tự động chuyển sang tài khoản khác"],
        "settings.autoSwitchPreview": [.english: "Auto-switch to preview model", .vietnamese: "Tự động chuyển sang mô hình xem trước"],
        "settings.quotaExceededHelp": [.english: "When quota is exceeded, automatically try alternative accounts or models", .vietnamese: "Khi vượt hạn mức, tự động thử tài khoản hoặc mô hình khác"],
        "settings.retryConfiguration": [.english: "Retry Configuration", .vietnamese: "Cấu hình thử lại"],
        "settings.maxRetries": [.english: "Max retries", .vietnamese: "Số lần thử lại tối đa"],
        "settings.retryHelp": [.english: "Number of times to retry failed requests (403, 408, 500, 502, 503, 504)", .vietnamese: "Số lần thử lại yêu cầu thất bại (403, 408, 500, 502, 503, 504)"],
        "settings.logging": [.english: "Logging", .vietnamese: "Ghi nhật ký"],
        "settings.loggingToFile": [.english: "Log to file", .vietnamese: "Ghi nhật ký ra file"],
        "settings.loggingHelp": [.english: "Write application logs to rotating files instead of stdout. Disable to log to stdout/stderr.", .vietnamese: "Ghi nhật ký vào file xoay vòng thay vì stdout. Tắt để ghi ra stdout/stderr."],
        "settings.paths": [.english: "Paths", .vietnamese: "Đường dẫn"],
        "settings.binary": [.english: "Binary", .vietnamese: "Tệp chạy"],
        "settings.config": [.english: "Config", .vietnamese: "Cấu hình"],
        "settings.authDir": [.english: "Auth Dir", .vietnamese: "Thư mục xác thực"],
        "settings.language": [.english: "Language", .vietnamese: "Ngôn ngữ"],
        "settings.general": [.english: "General", .vietnamese: "Chung"],
        "settings.about": [.english: "About", .vietnamese: "Giới thiệu"],
        "settings.startup": [.english: "Startup", .vietnamese: "Khởi động"],
        "settings.appearance": [.english: "Appearance", .vietnamese: "Giao diện"],
        "settings.launchAtLogin": [.english: "Launch at login", .vietnamese: "Khởi động cùng hệ thống"],
        "settings.showInDock": [.english: "Show in Dock", .vietnamese: "Hiển thị trên Dock"],
        "settings.restartForEffect": [.english: "Restart app for full effect", .vietnamese: "Khởi động lại ứng dụng để có hiệu lực đầy đủ"],
        "settings.apiKeys": [.english: "API Keys", .vietnamese: "Khóa API"],
        "settings.apiKeysHelp": [.english: "API keys for clients to authenticate with the proxy", .vietnamese: "Khóa API để các client xác thực với proxy"],
        "settings.addAPIKey": [.english: "Add API Key", .vietnamese: "Thêm khóa API"],
        "settings.apiKeyPlaceholder": [.english: "Enter API key...", .vietnamese: "Nhập khóa API..."],
        
        // API Keys Screen
        "apiKeys.list": [.english: "API Keys", .vietnamese: "Danh sách khóa API"],
        "apiKeys.description": [.english: "API keys for clients to authenticate with the proxy service", .vietnamese: "Khóa API để các client xác thực với dịch vụ proxy"],
        "apiKeys.add": [.english: "Add Key", .vietnamese: "Thêm khóa"],
        "apiKeys.addHelp": [.english: "Add a new API key", .vietnamese: "Thêm khóa API mới"],
        "apiKeys.generate": [.english: "Generate", .vietnamese: "Tạo ngẫu nhiên"],
        "apiKeys.generateHelp": [.english: "Generate a random API key", .vietnamese: "Tạo khóa API ngẫu nhiên"],
        "apiKeys.generateFirst": [.english: "Generate Your First Key", .vietnamese: "Tạo khóa đầu tiên"],
        "apiKeys.placeholder": [.english: "Enter API key...", .vietnamese: "Nhập khóa API..."],
        "apiKeys.edit": [.english: "Edit", .vietnamese: "Sửa"],
        "apiKeys.empty": [.english: "No API Keys", .vietnamese: "Chưa có khóa API"],
        "apiKeys.emptyDescription": [.english: "Add API keys to authenticate clients with the proxy", .vietnamese: "Thêm khóa API để xác thực client với proxy"],
        "apiKeys.proxyRequired": [.english: "Start the proxy to manage API keys", .vietnamese: "Khởi động proxy để quản lý khóa API"],
        
        // Logs
        "logs.clearLogs": [.english: "Clear Logs", .vietnamese: "Xóa nhật ký"],
        "logs.noLogs": [.english: "No Logs", .vietnamese: "Không có nhật ký"],
        "logs.startProxy": [.english: "Start the proxy to view logs", .vietnamese: "Khởi động proxy để xem nhật ký"],
        "logs.logsWillAppear": [.english: "Logs will appear here as requests are processed", .vietnamese: "Nhật ký sẽ xuất hiện khi có yêu cầu được xử lý"],
        "logs.searchLogs": [.english: "Search logs...", .vietnamese: "Tìm kiếm nhật ký..."],
        "logs.all": [.english: "All", .vietnamese: "Tất cả"],
        "logs.info": [.english: "Info", .vietnamese: "Thông tin"],
        "logs.warn": [.english: "Warn", .vietnamese: "Cảnh báo"],
        "logs.error": [.english: "Error", .vietnamese: "Lỗi"],
        "logs.autoScroll": [.english: "Auto-scroll", .vietnamese: "Tự cuộn"],
        
        // Actions
        "action.start": [.english: "Start", .vietnamese: "Bắt đầu"],
        "action.stop": [.english: "Stop", .vietnamese: "Dừng"],
        "action.startProxy": [.english: "Start Proxy", .vietnamese: "Khởi động Proxy"],
        "action.stopProxy": [.english: "Stop Proxy", .vietnamese: "Dừng Proxy"],
        "action.copy": [.english: "Copy", .vietnamese: "Sao chép"],
        "action.delete": [.english: "Delete", .vietnamese: "Xóa"],
        "action.refresh": [.english: "Refresh", .vietnamese: "Làm mới"],
        "action.copyCode": [.english: "Copy Code", .vietnamese: "Sao chép mã"],
        "action.quit": [.english: "Quit Quotio", .vietnamese: "Thoát Quotio"],
        "action.openApp": [.english: "Open Quotio", .vietnamese: "Mở Quotio"],
        
        // Empty states
        "empty.proxyNotRunning": [.english: "Proxy Not Running", .vietnamese: "Proxy chưa chạy"],
        "empty.startProxyToView": [.english: "Start the proxy to view quota information", .vietnamese: "Khởi động proxy để xem thông tin hạn mức"],
        "empty.noAccounts": [.english: "No Accounts", .vietnamese: "Chưa có tài khoản"],
        "empty.addProviderAccounts": [.english: "Add provider accounts to view quota", .vietnamese: "Thêm tài khoản nhà cung cấp để xem hạn mức"],
        
        // Subscription
        "subscription.upgrade": [.english: "Upgrade", .vietnamese: "Nâng cấp"],
        "subscription.freeTier": [.english: "Free Tier", .vietnamese: "Gói miễn phí"],
        "subscription.proPlan": [.english: "Pro Plan", .vietnamese: "Gói Pro"],
        "subscription.project": [.english: "Project", .vietnamese: "Dự án"],
        
        // OAuth
        "oauth.connect": [.english: "Connect", .vietnamese: "Kết nối"],
        "oauth.authenticateWith": [.english: "Authenticate with your", .vietnamese: "Xác thực với tài khoản"],
        "oauth.projectId": [.english: "Project ID (optional)", .vietnamese: "ID dự án (tùy chọn)"],
        "oauth.projectIdPlaceholder": [.english: "Enter project ID...", .vietnamese: "Nhập ID dự án..."],
        "oauth.authenticate": [.english: "Authenticate", .vietnamese: "Xác thực"],
        "oauth.retry": [.english: "Try Again", .vietnamese: "Thử lại"],
        "oauth.openingBrowser": [.english: "Opening browser...", .vietnamese: "Đang mở trình duyệt..."],
        "oauth.waitingForAuth": [.english: "Waiting for authentication", .vietnamese: "Đang chờ xác thực"],
        "oauth.completeBrowser": [.english: "Complete the login in your browser", .vietnamese: "Hoàn tất đăng nhập trong trình duyệt"],
        "oauth.success": [.english: "Connected successfully!", .vietnamese: "Kết nối thành công!"],
        "oauth.closingSheet": [.english: "Closing...", .vietnamese: "Đang đóng..."],
        "oauth.failed": [.english: "Authentication failed", .vietnamese: "Xác thực thất bại"],
        "oauth.timeout": [.english: "Authentication timeout", .vietnamese: "Hết thời gian xác thực"],
        "oauth.authMethod": [.english: "Authentication Method", .vietnamese: "Phương thức xác thực"],
        "oauth.enterCodeInBrowser": [.english: "Enter this code in browser", .vietnamese: "Nhập mã này trong trình duyệt"],
        
        "import.vertexKey": [.english: "Import Service Account Key", .vietnamese: "Nhập khóa tài khoản dịch vụ"],
        "import.vertexDesc": [.english: "Select the JSON key file for your Vertex AI service account", .vietnamese: "Chọn tệp khóa JSON cho tài khoản dịch vụ Vertex AI"],
        "import.selectFile": [.english: "Select JSON File", .vietnamese: "Chọn tệp JSON"],
        "import.success": [.english: "Key imported successfully", .vietnamese: "Đã nhập khóa thành công"],
        "import.failed": [.english: "Import failed", .vietnamese: "Nhập thất bại"],
        
        // Menu Bar
        "menubar.running": [.english: "Proxy Running", .vietnamese: "Proxy đang chạy"],
        "menubar.stopped": [.english: "Proxy Stopped", .vietnamese: "Proxy đã dừng"],
        "menubar.accounts": [.english: "Accounts", .vietnamese: "Tài khoản"],
        "menubar.requests": [.english: "Requests", .vietnamese: "Yêu cầu"],
        "menubar.success": [.english: "Success", .vietnamese: "Thành công"],
        "menubar.providers": [.english: "Providers", .vietnamese: "Nhà cung cấp"],
        "menubar.noProviders": [.english: "No providers connected", .vietnamese: "Chưa kết nối nhà cung cấp"],
        "menubar.andMore": [.english: "+{count} more...", .vietnamese: "+{count} nữa..."],
        "menubar.openApp": [.english: "Open Quotio", .vietnamese: "Mở Quotio"],
        "menubar.quit": [.english: "Quit Quotio", .vietnamese: "Thoát Quotio"],
        "menubar.quota": [.english: "Quota Usage", .vietnamese: "Sử dụng hạn mức"],
        
        // Menu Bar Settings
        "settings.menubar": [.english: "Menu Bar", .vietnamese: "Thanh Menu"],
        "settings.menubar.showIcon": [.english: "Show Menu Bar Icon", .vietnamese: "Hiển thị icon trên Menu Bar"],
        "settings.menubar.showQuota": [.english: "Show Quota in Menu Bar", .vietnamese: "Hiển thị Quota trên Menu Bar"],
        "settings.menubar.colorMode": [.english: "Color Mode", .vietnamese: "Chế độ màu"],
        "settings.menubar.colored": [.english: "Colored", .vietnamese: "Có màu"],
        "settings.menubar.monochrome": [.english: "Monochrome", .vietnamese: "Trắng đen"],
        "settings.menubar.selectAccounts": [.english: "Select Accounts to Display", .vietnamese: "Chọn tài khoản hiển thị"],
        "settings.menubar.selected": [.english: "Displayed", .vietnamese: "Đang hiển thị"],
        "settings.menubar.noQuotaData": [.english: "No quota data available. Add accounts with quota support.", .vietnamese: "Không có dữ liệu quota. Thêm tài khoản hỗ trợ quota."],
        "settings.menubar.help": [.english: "Choose which accounts to show in the menu bar. Maximum 3 items will be displayed.", .vietnamese: "Chọn tài khoản muốn hiển thị trên thanh menu. Tối đa 3 mục."],
        
        "menubar.showOnMenuBar": [.english: "Show on Menu Bar", .vietnamese: "Hiển thị trên Menu Bar"],
        "menubar.hideFromMenuBar": [.english: "Hide from Menu Bar", .vietnamese: "Ẩn khỏi Menu Bar"],
        "menubar.limitReached": [.english: "Menu bar limit reached", .vietnamese: "Đã đạt giới hạn Menu Bar"],
        
        "menubar.warning.title": [.english: "Too Many Items", .vietnamese: "Quá nhiều mục"],
        "menubar.warning.message": [.english: "Displaying more than 3 items may make the menu bar cluttered. Are you sure you want to continue?", .vietnamese: "Hiển thị hơn 3 mục có thể làm thanh menu lộn xộn. Bạn có chắc muốn tiếp tục?"],
        "menubar.warning.confirm": [.english: "Add Anyway", .vietnamese: "Vẫn thêm"],
        "menubar.warning.cancel": [.english: "Cancel", .vietnamese: "Hủy"],
        
        "menubar.info.title": [.english: "Menu Bar Display", .vietnamese: "Hiển thị Menu Bar"],
        "menubar.info.description": [.english: "Click the chart icon to toggle displaying this account's quota in the menu bar.", .vietnamese: "Nhấn vào biểu tượng biểu đồ để bật/tắt hiển thị quota của tài khoản này trên menu bar."],
        "menubar.info.enabled": [.english: "Showing in menu bar", .vietnamese: "Đang hiển thị trên menu bar"],
        "menubar.info.disabled": [.english: "Not showing in menu bar", .vietnamese: "Không hiển thị trên menu bar"],
        "menubar.hint": [.english: "Click the chart icon to toggle menu bar display", .vietnamese: "Nhấn biểu tượng biểu đồ để bật/tắt hiển thị trên menu bar"],
        
        // Quota Display Mode Settings
        "settings.quota.display": [.english: "Quota Display", .vietnamese: "Hiển thị Quota"],
        "settings.quota.display.help": [.english: "Choose how to display quota percentages across the app.", .vietnamese: "Chọn cách hiển thị phần trăm quota trong ứng dụng."],
        "settings.quota.displayMode": [.english: "Display Mode", .vietnamese: "Chế độ hiển thị"],
        "settings.quota.displayMode.used": [.english: "Used", .vietnamese: "Đã dùng"],
        "settings.quota.displayMode.remaining": [.english: "Remaining", .vietnamese: "Còn lại"],
        "settings.quota.used": [.english: "used", .vietnamese: "đã dùng"],
        "settings.quota.left": [.english: "left", .vietnamese: "còn lại"],
        
        // Notifications
        "settings.notifications": [.english: "Notifications", .vietnamese: "Thông báo"],
        "settings.notifications.enabled": [.english: "Enable Notifications", .vietnamese: "Bật thông báo"],
        "settings.notifications.quotaLow": [.english: "Quota Low Warning", .vietnamese: "Cảnh báo hạn mức thấp"],
        "settings.notifications.cooling": [.english: "Account Cooling Alert", .vietnamese: "Cảnh báo tài khoản đang nghỉ"],
        "settings.notifications.proxyCrash": [.english: "Proxy Crash Alert", .vietnamese: "Cảnh báo proxy bị lỗi"],
        "settings.notifications.threshold": [.english: "Alert Threshold", .vietnamese: "Ngưỡng cảnh báo"],
        "settings.notifications.help": [.english: "Get notified when quota is low, accounts enter cooling, or proxy crashes", .vietnamese: "Nhận thông báo khi hạn mức thấp, tài khoản đang nghỉ, hoặc proxy bị lỗi"],
        "settings.notifications.notAuthorized": [.english: "Notifications not authorized. Enable in System Settings.", .vietnamese: "Thông báo chưa được cấp quyền. Bật trong Cài đặt hệ thống."],
        
        "notification.quotaLow.title": [.english: "⚠️ Quota Low", .vietnamese: "⚠️ Hạn mức thấp"],
        "notification.quotaLow.body": [.english: "%@ (%@): Only %d%% quota remaining", .vietnamese: "%@ (%@): Chỉ còn %d%% hạn mức"],
        "notification.cooling.title": [.english: "❄️ Account Cooling", .vietnamese: "❄️ Tài khoản đang nghỉ"],
        "notification.cooling.body": [.english: "%@ (%@) has entered cooling status", .vietnamese: "%@ (%@) đã vào trạng thái nghỉ"],
        "notification.proxyCrash.title": [.english: "🚨 Proxy Crashed", .vietnamese: "🚨 Proxy bị lỗi"],
        "notification.proxyCrash.body": [.english: "Proxy process exited with code %d", .vietnamese: "Tiến trình proxy đã thoát với mã %d"],
        "notification.proxyStarted.title": [.english: "✅ Proxy Started", .vietnamese: "✅ Proxy đã khởi động"],
        "notification.proxyStarted.body": [.english: "Proxy server is now running", .vietnamese: "Máy chủ proxy đang chạy"],
        
        // Agent Setup
        "nav.agents": [.english: "Agents", .vietnamese: "Agent"],
        "agents.title": [.english: "AI Agent Setup", .vietnamese: "Cài đặt AI Agent"],
        "agents.subtitle": [.english: "Configure CLI agents to use CLIProxyAPI", .vietnamese: "Cấu hình CLI agent để sử dụng CLIProxyAPI"],
        "agents.installed": [.english: "Installed", .vietnamese: "Đã cài đặt"],
        "agents.notInstalled": [.english: "Not Installed", .vietnamese: "Chưa cài đặt"],
        "agents.configured": [.english: "Configured", .vietnamese: "Đã cấu hình"],
        "agents.configure": [.english: "Configure", .vietnamese: "Cấu hình"],
        "agents.reconfigure": [.english: "Reconfigure", .vietnamese: "Cấu hình lại"],
        "agents.test": [.english: "Test Connection", .vietnamese: "Kiểm tra kết nối"],
        "agents.docs": [.english: "Documentation", .vietnamese: "Tài liệu"],
        
        // Configuration Modes
        "agents.mode": [.english: "Configuration Mode", .vietnamese: "Chế độ cấu hình"],
        "agents.mode.automatic": [.english: "Automatic", .vietnamese: "Tự động"],
        "agents.mode.manual": [.english: "Manual", .vietnamese: "Thủ công"],
        "agents.mode.automatic.desc": [.english: "Directly update config files and shell profile", .vietnamese: "Tự động cập nhật file cấu hình và shell profile"],
        "agents.mode.manual.desc": [.english: "View and copy configuration manually", .vietnamese: "Xem và sao chép cấu hình thủ công"],
        "agents.applyConfig": [.english: "Apply Configuration", .vietnamese: "Áp dụng cấu hình"],
        "agents.generateConfig": [.english: "Generate Configuration", .vietnamese: "Tạo cấu hình"],
        "agents.configGenerated": [.english: "Configuration Generated", .vietnamese: "Đã tạo cấu hình"],
        "agents.copyInstructions": [.english: "Copy the configuration below and apply manually", .vietnamese: "Sao chép cấu hình bên dưới và áp dụng thủ công"],
        
        // Model Slots
        "agents.modelSlots": [.english: "Model Slots", .vietnamese: "Slot mô hình"],
        "agents.modelSlots.opus": [.english: "Opus (High Intelligence)", .vietnamese: "Opus (Thông minh cao)"],
        "agents.modelSlots.sonnet": [.english: "Sonnet (Balanced)", .vietnamese: "Sonnet (Cân bằng)"],
        "agents.modelSlots.haiku": [.english: "Haiku (Fast)", .vietnamese: "Haiku (Nhanh)"],
        "agents.selectModel": [.english: "Select Model", .vietnamese: "Chọn mô hình"],
        
        // Config Types
        "agents.config.env": [.english: "Environment Variables", .vietnamese: "Biến môi trường"],
        "agents.config.file": [.english: "Configuration Files", .vietnamese: "Tệp cấu hình"],
        "agents.copyConfig": [.english: "Copy to Clipboard", .vietnamese: "Sao chép"],
        "agents.addToShell": [.english: "Add to Shell Profile", .vietnamese: "Thêm vào Shell Profile"],
        "agents.shellAdded": [.english: "Added to shell profile", .vietnamese: "Đã thêm vào shell profile"],
        "agents.copied": [.english: "Copied to clipboard", .vietnamese: "Đã sao chép"],
        
        // Status Messages
        "agents.configSuccess": [.english: "Configuration complete!", .vietnamese: "Cấu hình hoàn tất!"],
        "agents.configFailed": [.english: "Configuration failed", .vietnamese: "Cấu hình thất bại"],
        "agents.testSuccess": [.english: "Connection successful!", .vietnamese: "Kết nối thành công!"],
        "agents.testFailed": [.english: "Connection failed", .vietnamese: "Kết nối thất bại"],
        
        // Instructions
        "agents.instructions.restart": [.english: "Restart your terminal for changes to take effect", .vietnamese: "Khởi động lại terminal để thay đổi có hiệu lực"],
        "agents.instructions.env": [.english: "Add these environment variables to your shell profile:", .vietnamese: "Thêm các biến môi trường này vào shell profile:"],
        "agents.instructions.file": [.english: "Configuration files have been created:", .vietnamese: "Các tệp cấu hình đã được tạo:"],
        "agents.proxyNotRunning": [.english: "Start the proxy to configure agents", .vietnamese: "Khởi động proxy để cấu hình agent"],
        "agents.proxyRequired.title": [.english: "Proxy Required", .vietnamese: "Cần khởi động Proxy"],
        "agents.proxyRequired.message": [.english: "The proxy server must be running to configure agents. Start the proxy first.", .vietnamese: "Cần khởi động proxy để cấu hình agent. Hãy khởi động proxy trước."],
        
        // Auth Modes
        "agents.oauthMode": [.english: "Use OAuth Authentication", .vietnamese: "Sử dụng xác thực OAuth"],
        "agents.apiKeyMode": [.english: "Use API Key Authentication", .vietnamese: "Sử dụng xác thực API Key"],
        
        // Agent Config Sheet
        "agents.configMode": [.english: "Configuration Mode", .vietnamese: "Chế độ cấu hình"],
        "agents.connectionInfo": [.english: "Connection Info", .vietnamese: "Thông tin kết nối"],
        "agents.proxyURL": [.english: "Proxy URL", .vietnamese: "URL Proxy"],
        "agents.apiKey": [.english: "API Key", .vietnamese: "Khóa API"],
        "agents.shell": [.english: "Shell", .vietnamese: "Shell"],
        "agents.modelSlotsDesc": [.english: "Configure which models to use for each slot", .vietnamese: "Cấu hình mô hình sử dụng cho mỗi slot"],
        "agents.useOAuth": [.english: "Use OAuth Authentication", .vietnamese: "Sử dụng xác thực OAuth"],
        "agents.useOAuthDesc": [.english: "Use your existing Google OAuth credentials", .vietnamese: "Sử dụng thông tin đăng nhập Google OAuth hiện có"],
        "agents.testConnection": [.english: "Test Connection", .vietnamese: "Kiểm tra kết nối"],
        "agents.filesModified": [.english: "Files Modified", .vietnamese: "Các tệp đã thay đổi"],
        "agents.rawConfigs": [.english: "Raw Configurations", .vietnamese: "Cấu hình thô"],
        "agents.apply": [.english: "Apply", .vietnamese: "Áp dụng"],
        "agents.generate": [.english: "Generate", .vietnamese: "Tạo"],
        "agents.viewDocs": [.english: "View Docs", .vietnamese: "Xem tài liệu"],
        
        // Actions (more)
        "action.copyAll": [.english: "Copy All", .vietnamese: "Sao chép tất cả"],
        "action.done": [.english: "Done", .vietnamese: "Xong"],
        "action.cancel": [.english: "Cancel", .vietnamese: "Hủy"],
        "agents.saveConfig": [.english: "Save Config", .vietnamese: "Lưu cấu hình"],
        
        // Storage Options
        "agents.storageOption": [.english: "Storage Location", .vietnamese: "Vị trí lưu trữ"],
        "agents.storage.jsonOnly": [.english: "JSON Config", .vietnamese: "JSON Config"],
        "agents.storage.shellOnly": [.english: "Shell Profile", .vietnamese: "Shell Profile"],
        "agents.storage.both": [.english: "Both", .vietnamese: "Cả hai"],
        
        // Updates
        "settings.updates": [.english: "Updates", .vietnamese: "Cập nhật"],
        "settings.autoCheckUpdates": [.english: "Automatically check for updates", .vietnamese: "Tự động kiểm tra cập nhật"],
        "settings.lastChecked": [.english: "Last checked", .vietnamese: "Lần kiểm tra cuối"],
        "settings.never": [.english: "Never", .vietnamese: "Chưa bao giờ"],
        "settings.checkNow": [.english: "Check Now", .vietnamese: "Kiểm tra ngay"],
        "settings.version": [.english: "Version", .vietnamese: "Phiên bản"],
        
        // About Screen
        "about.tagline": [.english: "Your AI Coding Command Center", .vietnamese: "Trung tâm điều khiển AI Coding của bạn"],
        "about.description": [.english: "Quotio is a native macOS application for managing CLIProxyAPI - a local proxy server that powers your AI coding agents. Manage multiple AI accounts, track quotas, and configure CLI tools in one place.", .vietnamese: "Quotio là ứng dụng macOS để quản lý CLIProxyAPI - máy chủ proxy cục bộ hỗ trợ các AI coding agent. Quản lý nhiều tài khoản AI, theo dõi hạn mức và cấu hình các công cụ CLI tại một nơi."],
        "about.multiAccount": [.english: "Multi-Account", .vietnamese: "Đa tài khoản"],
        "about.quotaTracking": [.english: "Quota Tracking", .vietnamese: "Theo dõi quota"],
        "about.agentConfig": [.english: "Agent Config", .vietnamese: "Cấu hình Agent"],
        "about.buyMeCoffee": [.english: "Buy Me a Coffee", .vietnamese: "Mua cho tôi ly cà phê"],
        "about.buyMePizza": [.english: "Buy Me a Pizza", .vietnamese: "Mua cho tôi miếng pizza"],
        "about.madeWith": [.english: "Made with ❤️ in Vietnam", .vietnamese: "Được tạo với ❤️ tại Việt Nam"],
        
        // Onboarding
        "onboarding.installCLI": [.english: "Install CLIProxyAPI", .vietnamese: "Cài đặt CLIProxyAPI"],
        "onboarding.installCLIDesc": [.english: "Download the proxy binary to get started", .vietnamese: "Tải xuống binary proxy để bắt đầu"],
        "onboarding.startProxy": [.english: "Start Proxy Server", .vietnamese: "Khởi động Proxy Server"],
        "onboarding.startProxyDesc": [.english: "Start the local proxy to connect AI providers", .vietnamese: "Khởi động proxy cục bộ để kết nối các nhà cung cấp AI"],
        "onboarding.addProvider": [.english: "Connect AI Provider", .vietnamese: "Kết nối nhà cung cấp AI"],
        "onboarding.addProviderDesc": [.english: "Add at least one AI provider account", .vietnamese: "Thêm ít nhất một tài khoản nhà cung cấp AI"],
        "onboarding.connectAccount": [.english: "Connect Account", .vietnamese: "Kết nối tài khoản"],
        "onboarding.configureAgent": [.english: "Configure CLI Agent", .vietnamese: "Cấu hình CLI Agent"],
        "onboarding.configureAgentDesc": [.english: "Set up your AI coding assistant", .vietnamese: "Thiết lập trợ lý AI coding của bạn"],
        "onboarding.complete": [.english: "You're All Set!", .vietnamese: "Đã sẵn sàng!"],
        "onboarding.completeDesc": [.english: "Quotio is ready to supercharge your AI coding", .vietnamese: "Quotio đã sẵn sàng tăng cường AI coding của bạn"],
        "onboarding.skip": [.english: "Skip Setup", .vietnamese: "Bỏ qua"],
        "onboarding.goToDashboard": [.english: "Go to Dashboard", .vietnamese: "Đến Dashboard"],
        "onboarding.providersConfigured": [.english: "providers connected", .vietnamese: "nhà cung cấp đã kết nối"],
        "onboarding.agentsConfigured": [.english: "agents configured", .vietnamese: "agent đã cấu hình"],
        
        // Dashboard
        "dashboard.gettingStarted": [.english: "Getting Started", .vietnamese: "Bắt đầu"],
        "action.dismiss": [.english: "Dismiss", .vietnamese: "Ẩn"],
        
        // Quota-Only Mode - New Keys
        "nav.accounts": [.english: "Accounts", .vietnamese: "Tài khoản"],
        "dashboard.trackedAccounts": [.english: "Tracked Accounts", .vietnamese: "Tài khoản theo dõi"],
        "dashboard.connected": [.english: "connected", .vietnamese: "đã kết nối"],
        "dashboard.lowestQuota": [.english: "Lowest Quota", .vietnamese: "Quota thấp nhất"],
        "dashboard.remaining": [.english: "remaining", .vietnamese: "còn lại"],
        "dashboard.lastRefresh": [.english: "Last Refresh", .vietnamese: "Cập nhật lần cuối"],
        "dashboard.updated": [.english: "updated", .vietnamese: "đã cập nhật"],
        "dashboard.noQuotaData": [.english: "No quota data yet", .vietnamese: "Chưa có dữ liệu quota"],
        "dashboard.quotaOverview": [.english: "Quota Overview", .vietnamese: "Tổng quan Quota"],
        "dashboard.noAccountsTracked": [.english: "No accounts tracked", .vietnamese: "Chưa theo dõi tài khoản nào"],
        "dashboard.addAccountsHint": [.english: "Add provider accounts to start tracking quotas", .vietnamese: "Thêm tài khoản nhà cung cấp để bắt đầu theo dõi quota"],
        
        // Providers - Quota-Only Mode
        "providers.noAccountsFound": [.english: "No accounts found", .vietnamese: "Không tìm thấy tài khoản"],
        "providers.quotaOnlyHint": [.english: "Auth files will be detected from ~/.cli-proxy-api and native CLI locations", .vietnamese: "File xác thực sẽ được phát hiện từ ~/.cli-proxy-api và các vị trí CLI gốc"],
        "providers.trackedAccounts": [.english: "Tracked Accounts", .vietnamese: "Tài khoản theo dõi"],
        
        // Empty States - New
        "empty.noQuotaData": [.english: "No Quota Data", .vietnamese: "Chưa có dữ liệu Quota"],
        "empty.refreshToLoad": [.english: "Refresh to load quota information", .vietnamese: "Làm mới để tải thông tin quota"],
        
        // Menu Bar - Quota Mode
        "menubar.quotaMode": [.english: "Quota Monitor", .vietnamese: "Theo dõi Quota"],
        "menubar.trackedAccounts": [.english: "Tracked Accounts", .vietnamese: "Tài khoản theo dõi"],
        "menubar.noAccountsFound": [.english: "No accounts found", .vietnamese: "Không tìm thấy tài khoản"],
        "menubar.noData": [.english: "No quota data available", .vietnamese: "Chưa có dữ liệu quota"],
        
        // Menu Bar - Tooltips
        "menubar.tooltip.openApp": [.english: "Open main window (⌘O)", .vietnamese: "Mở cửa sổ chính (⌘O)"],
        "menubar.tooltip.quit": [.english: "Quit Quotio (⌘Q)", .vietnamese: "Thoát Quotio (⌘Q)"],
        
        // Actions - New
        "action.refreshQuota": [.english: "Refresh Quota", .vietnamese: "Làm mới Quota"],
        "action.switch": [.english: "Switch", .vietnamese: "Chuyển"],
        
        // Status - New
        "status.refreshing": [.english: "Refreshing...", .vietnamese: "Đang làm mới..."],
        "status.notRefreshed": [.english: "Not refreshed", .vietnamese: "Chưa làm mới"],
        
        // Settings - App Mode
        "settings.appMode": [.english: "App Mode", .vietnamese: "Chế độ ứng dụng"],
        "settings.appMode.quotaOnlyNote": [.english: "Proxy server is disabled in Quota Monitor mode", .vietnamese: "Máy chủ proxy bị tắt trong chế độ Theo dõi Quota"],
        "settings.appMode.switchConfirmTitle": [.english: "Switch to Quota Monitor Mode?", .vietnamese: "Chuyển sang chế độ Theo dõi Quota?"],
        "settings.appMode.switchConfirmMessage": [.english: "This will stop the proxy server if running. You can switch back anytime.", .vietnamese: "Điều này sẽ dừng máy chủ proxy nếu đang chạy. Bạn có thể chuyển lại bất cứ lúc nào."],
        
        // Appearance Mode
        "settings.appearance.title": [.english: "Appearance", .vietnamese: "Giao diện"],
        "settings.appearance.mode": [.english: "Theme", .vietnamese: "Chủ đề"],
        "settings.appearance.system": [.english: "System", .vietnamese: "Hệ thống"],
        "settings.appearance.light": [.english: "Light", .vietnamese: "Sáng"],
        "settings.appearance.dark": [.english: "Dark", .vietnamese: "Tối"],
        "settings.appearance.help": [.english: "Choose how the app looks. System will automatically match your Mac's appearance.", .vietnamese: "Chọn giao diện cho ứng dụng. Hệ thống sẽ tự động theo giao diện của Mac."],
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
