//
//  LanguageManager.swift
//  Quotio
//

import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case vietnamese = "vi"
    case chinese = "zh"
    case french = "fr"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        case .chinese: return "简体中文"
        case .french: return "Français"
        }
    }
    
    var flag: String {
        switch self {
        case .english: return "🇺🇸"
        case .vietnamese: return "🇻🇳"
        case .chinese: return "🇨🇳"
        case .french: return "🇫🇷"
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
        "nav.dashboard": [.english: "Dashboard", .vietnamese: "Bảng điều khiển", .chinese: "仪表板", .french: "Tableau de bord"],
        "nav.quota": [.english: "Quota", .vietnamese: "Hạn mức", .chinese: "配额", .french: "Quota"],
        "nav.providers": [.english: "Providers", .vietnamese: "Nhà cung cấp", .chinese: "提供商", .french: "Fournisseurs"],
        "nav.apiKeys": [.english: "API Keys", .vietnamese: "Khóa API", .chinese: "API 密钥", .french: "Clés API"],
        "nav.logs": [.english: "Logs", .vietnamese: "Nhật ký", .chinese: "日志", .french: "Journaux"],
        "nav.settings": [.english: "Settings", .vietnamese: "Cài đặt", .chinese: "设置", .french: "Paramètres"],
        "nav.about": [.english: "About", .vietnamese: "Giới thiệu", .chinese: "关于", .french: "À propos"],
        
        // Status
        "status.running": [.english: "Running", .vietnamese: "Đang chạy", .chinese: "运行中", .french: "En cours"],
        "status.starting": [.english: "Starting...", .vietnamese: "Đang khởi động...", .chinese: "启动中...", .french: "Démarrage..."],
        "status.stopped": [.english: "Stopped", .vietnamese: "Đã dừng", .chinese: "已停止", .french: "Arrêté"],
        "status.ready": [.english: "Ready", .vietnamese: "Sẵn sàng", .chinese: "就绪", .french: "Prêt"],
        "status.cooling": [.english: "Cooling", .vietnamese: "Đang nghỉ", .chinese: "冷却中", .french: "Refroidissement"],
        "status.error": [.english: "Error", .vietnamese: "Lỗi", .chinese: "错误", .french: "Erreur"],
        "status.available": [.english: "Available", .vietnamese: "Khả dụng", .chinese: "可用", .french: "Disponible"],
        "status.forbidden": [.english: "Forbidden", .vietnamese: "Bị chặn", .chinese: "已禁止", .french: "Interdit"],
        
        // Dashboard
        "dashboard.accounts": [.english: "Accounts", .vietnamese: "Tài khoản", .chinese: "账户", .french: "Comptes"],
        "dashboard.ready": [.english: "ready", .vietnamese: "sẵn sàng", .chinese: "就绪", .french: "prêt"],
        "dashboard.requests": [.english: "Requests", .vietnamese: "Yêu cầu", .chinese: "请求", .french: "Requêtes"],
        "dashboard.total": [.english: "total", .vietnamese: "tổng", .chinese: "总计", .french: "total"],
        "dashboard.tokens": [.english: "Tokens", .vietnamese: "Token", .chinese: "令牌", .french: "Jetons"],
        "dashboard.processed": [.english: "processed", .vietnamese: "đã xử lý", .chinese: "已处理", .french: "traités"],
        "dashboard.successRate": [.english: "Success Rate", .vietnamese: "Tỷ lệ thành công", .chinese: "成功率", .french: "Taux de réussite"],
        "dashboard.failed": [.english: "failed", .vietnamese: "thất bại", .chinese: "失败", .french: "échoué"],
        "dashboard.providers": [.english: "Providers", .vietnamese: "Nhà cung cấp", .chinese: "提供商", .french: "Fournisseurs"],
        "dashboard.apiEndpoint": [.english: "API Endpoint", .vietnamese: "Điểm cuối API", .chinese: "API 端点", .french: "Point d'accès API"],
        "dashboard.cliNotInstalled": [.english: "CLIProxyAPI Not Installed", .vietnamese: "CLIProxyAPI chưa cài đặt", .chinese: "CLIProxyAPI 未安装", .french: "CLIProxyAPI non installé"],
        "dashboard.clickToInstall": [.english: "Click the button below to automatically download and install", .vietnamese: "Nhấn nút bên dưới để tự động tải và cài đặt", .chinese: "点击下方按钮自动下载并安装", .french: "Cliquez sur le bouton ci-dessous pour télécharger et installer automatiquement"],
        "dashboard.installCLI": [.english: "Install CLIProxyAPI", .vietnamese: "Cài đặt CLIProxyAPI", .chinese: "安装 CLIProxyAPI", .french: "Installer CLIProxyAPI"],
        "dashboard.startToBegin": [.english: "Start the proxy server to begin", .vietnamese: "Khởi động máy chủ proxy để bắt đầu", .chinese: "启动代理服务器以开始", .french: "Démarrez le serveur proxy pour commencer"],
        
        // Quota
        "quota.overallStatus": [.english: "Overall Status", .vietnamese: "Trạng thái chung", .chinese: "总体状态", .french: "État général"],
        "quota.providers": [.english: "providers", .vietnamese: "nhà cung cấp", .chinese: "提供商", .french: "fournisseurs"],
        "quota.accounts": [.english: "accounts", .vietnamese: "tài khoản", .chinese: "账户", .french: "comptes"],
        "quota.account": [.english: "account", .vietnamese: "tài khoản", .chinese: "账户", .french: "compte"],
        "quota.accountsReady": [.english: "accounts ready", .vietnamese: "tài khoản sẵn sàng", .chinese: "账户就绪", .french: "comptes prêts"],
        "quota.used": [.english: "used", .vietnamese: "đã dùng", .chinese: "已使用", .french: "utilisé"],
        "quota.reset": [.english: "reset", .vietnamese: "đặt lại", .chinese: "重置", .french: "réinitialiser"],
        "quota.noDataYet": [.english: "No usage data available", .vietnamese: "Chưa có dữ liệu sử dụng", .chinese: "暂无使用数据", .french: "Aucune donnée d'utilisation disponible"],
        
        // Providers
        "providers.addProvider": [.english: "Add Provider", .vietnamese: "Thêm nhà cung cấp", .chinese: "添加提供商", .french: "Ajouter un fournisseur"],
        "providers.connectedAccounts": [.english: "Connected Accounts", .vietnamese: "Tài khoản đã kết nối", .chinese: "已连接账户", .french: "Comptes connectés"],
        "providers.noAccountsYet": [.english: "No accounts connected yet", .vietnamese: "Chưa có tài khoản nào được kết nối", .chinese: "尚未连接账户", .french: "Aucun compte connecté"],
        "providers.startProxyFirst": [.english: "Start the proxy first to manage providers", .vietnamese: "Khởi động proxy trước để quản lý nhà cung cấp", .chinese: "先启动代理以管理提供商", .french: "Démarrez d'abord le proxy pour gérer les fournisseurs"],
        "providers.connect": [.english: "Connect", .vietnamese: "Kết nối", .chinese: "连接", .french: "Connecter"],
        "providers.authenticate": [.english: "Authenticate", .vietnamese: "Xác thực", .chinese: "认证", .french: "Authentifier"],
        "providers.cancel": [.english: "Cancel", .vietnamese: "Hủy", .chinese: "取消", .french: "Annuler"],
        "providers.waitingAuth": [.english: "Waiting for authentication...", .vietnamese: "Đang chờ xác thực...", .chinese: "等待认证...", .french: "En attente d'authentification..."],
        "providers.connectedSuccess": [.english: "Connected successfully!", .vietnamese: "Kết nối thành công!", .chinese: "连接成功！", .french: "Connexion réussie !"],
        "providers.authFailed": [.english: "Authentication failed", .vietnamese: "Xác thực thất bại", .chinese: "认证失败", .french: "Échec de l'authentification"],
        "providers.projectIdOptional": [.english: "Project ID (optional)", .vietnamese: "ID dự án (tùy chọn)", .chinese: "项目 ID（可选）", .french: "ID du projet (optionnel)"],
        "providers.disabled": [.english: "Disabled", .vietnamese: "Đã tắt", .chinese: "已禁用", .french: "Désactivé"],
        "providers.autoDetected": [.english: "Auto-detected", .vietnamese: "Tự động phát hiện", .chinese: "自动检测", .french: "Détecté automatiquement"],
        "providers.source.proxy": [.english: "Proxy", .vietnamese: "Proxy", .chinese: "代理", .french: "Proxy"],
        "providers.source.disk": [.english: "Disk", .vietnamese: "Đĩa", .chinese: "磁盘", .french: "Disque"],
        "providers.yourAccounts": [.english: "Your Accounts", .vietnamese: "Tài khoản của bạn", .chinese: "您的账户", .french: "Vos comptes"],
        "providers.addAccount": [.english: "Add Account", .vietnamese: "Thêm tài khoản", .chinese: "添加账户", .french: "Ajouter un compte"],
        "providers.addManually": [.english: "Add Manually", .vietnamese: "Thêm thủ công", .chinese: "手动添加", .french: "Ajouter manuellement"],
        "providers.emptyState.title": [.english: "No Accounts", .vietnamese: "Chưa có tài khoản", .chinese: "无账户", .french: "Aucun compte"],
        "providers.emptyState.message": [.english: "Scan for installed IDEs or add a provider account to get started.", .vietnamese: "Quét IDE đã cài đặt hoặc thêm tài khoản nhà cung cấp để bắt đầu.", .chinese: "扫描已安装的 IDE 或添加提供商账户以开始。", .french: "Recherchez les IDE installés ou ajoutez un compte fournisseur pour commencer."],
        "providers.deleteConfirm": [.english: "Delete Account", .vietnamese: "Xóa tài khoản", .chinese: "删除账户", .french: "Supprimer le compte"],
        "providers.deleteMessage": [.english: "Are you sure you want to delete this account?", .vietnamese: "Bạn có chắc muốn xóa tài khoản này?", .chinese: "您确定要删除此账户吗？", .french: "Êtes-vous sûr de vouloir supprimer ce compte ?"],
        "providers.proxyRequired.title": [.english: "Proxy Required", .vietnamese: "Cần khởi động Proxy", .chinese: "需要代理", .french: "Proxy requis"],
        "providers.proxyRequired.message": [.english: "The proxy server must be running to add new provider accounts.", .vietnamese: "Cần khởi động proxy để thêm tài khoản nhà cung cấp mới.", .chinese: "必须运行代理服务器才能添加新的提供商账户。", .french: "Le serveur proxy doit être en cours d'exécution pour ajouter de nouveaux comptes fournisseur."],
        
        // Settings
        "settings.proxyServer": [.english: "Proxy Server", .vietnamese: "Máy chủ proxy", .chinese: "代理服务器", .french: "Serveur proxy"],
        "settings.port": [.english: "Port", .vietnamese: "Cổng", .chinese: "端口", .french: "Port"],
        "settings.endpoint": [.english: "Endpoint", .vietnamese: "Điểm cuối", .chinese: "端点", .french: "Point d'accès"],
        "settings.status": [.english: "Status", .vietnamese: "Trạng thái", .chinese: "状态", .french: "Statut"],
        "settings.autoStartProxy": [.english: "Auto-start proxy on launch", .vietnamese: "Tự khởi động proxy khi mở app", .chinese: "启动时自动启动代理", .french: "Démarrage automatique du proxy au lancement"],
        "settings.restartProxy": [.english: "Restart proxy after changing port", .vietnamese: "Khởi động lại proxy sau khi đổi cổng", .chinese: "更改端口后重启代理", .french: "Redémarrer le proxy après changement de port"],
        "settings.routingStrategy": [.english: "Routing Strategy", .vietnamese: "Chiến lược định tuyến", .chinese: "路由策略", .french: "Stratégie de routage"],
        "settings.roundRobin": [.english: "Round Robin", .vietnamese: "Xoay vòng", .chinese: "轮询", .french: "Tourniquet"],
        "settings.fillFirst": [.english: "Fill First", .vietnamese: "Dùng hết trước", .chinese: "优先填满", .french: "Remplir d'abord"],
        "settings.roundRobinDesc": [.english: "Distributes requests evenly across all accounts", .vietnamese: "Phân phối yêu cầu đều cho tất cả tài khoản", .chinese: "在所有账户间均匀分配请求", .french: "Distribue les requêtes uniformément entre tous les comptes"],
        "settings.fillFirstDesc": [.english: "Uses one account until quota exhausted, then moves to next", .vietnamese: "Dùng một tài khoản đến khi hết hạn mức, rồi chuyển sang tài khoản tiếp", .chinese: "使用一个账户直到配额耗尽，然后切换到下一个", .french: "Utilise un compte jusqu'à épuisement du quota, puis passe au suivant"],
        "settings.quotaExceededBehavior": [.english: "Quota Exceeded Behavior", .vietnamese: "Hành vi khi vượt hạn mức", .chinese: "配额超限行为", .french: "Comportement en cas de dépassement de quota"],
        "settings.autoSwitchAccount": [.english: "Auto-switch to another account", .vietnamese: "Tự động chuyển sang tài khoản khác", .chinese: "自动切换到其他账户", .french: "Basculer automatiquement vers un autre compte"],
        "settings.autoSwitchPreview": [.english: "Auto-switch to preview model", .vietnamese: "Tự động chuyển sang mô hình xem trước", .chinese: "自动切换到预览模型", .french: "Basculer automatiquement vers le modèle de prévisualisation"],
        "settings.quotaExceededHelp": [.english: "When quota is exceeded, automatically try alternative accounts or models", .vietnamese: "Khi vượt hạn mức, tự động thử tài khoản hoặc mô hình khác", .chinese: "配额超限时，自动尝试备选账户或模型", .french: "Lorsque le quota est dépassé, essayer automatiquement d'autres comptes ou modèles"],
        "settings.retryConfiguration": [.english: "Retry Configuration", .vietnamese: "Cấu hình thử lại", .chinese: "重试配置", .french: "Configuration des tentatives"],
        "settings.maxRetries": [.english: "Max retries", .vietnamese: "Số lần thử lại tối đa", .chinese: "最大重试次数", .french: "Tentatives max"],
        "settings.retryHelp": [.english: "Number of times to retry failed requests (403, 408, 500, 502, 503, 504)", .vietnamese: "Số lần thử lại yêu cầu thất bại (403, 408, 500, 502, 503, 504)", .chinese: "失败请求的重试次数（403、408、500、502、503、504）", .french: "Nombre de tentatives pour les requêtes échouées (403, 408, 500, 502, 503, 504)"],
        "settings.logging": [.english: "Logging", .vietnamese: "Ghi nhật ký", .chinese: "日志", .french: "Journalisation"],
        "settings.loggingToFile": [.english: "Log to file", .vietnamese: "Ghi nhật ký ra file", .chinese: "记录到文件", .french: "Enregistrer dans un fichier"],
        "settings.loggingHelp": [.english: "Write application logs to rotating files instead of stdout. Disable to log to stdout/stderr.", .vietnamese: "Ghi nhật ký vào file xoay vòng thay vì stdout. Tắt để ghi ra stdout/stderr.", .chinese: "将应用程序日志写入滚动文件而不是 stdout。禁用则记录到 stdout/stderr。", .french: "Écrire les journaux dans des fichiers rotatifs au lieu de stdout. Désactiver pour journaliser vers stdout/stderr."],
        "settings.paths": [.english: "Paths", .vietnamese: "Đường dẫn", .chinese: "路径", .french: "Chemins"],
        "settings.binary": [.english: "Binary", .vietnamese: "Tệp chạy", .chinese: "二进制文件", .french: "Binaire"],
        "settings.config": [.english: "Config", .vietnamese: "Cấu hình", .chinese: "配置", .french: "Configuration"],
        "settings.authDir": [.english: "Auth Dir", .vietnamese: "Thư mục xác thực", .chinese: "认证目录", .french: "Répertoire d'auth"],
        "settings.language": [.english: "Language", .vietnamese: "Ngôn ngữ", .chinese: "语言", .french: "Langue"],
        "settings.general": [.english: "General", .vietnamese: "Chung", .chinese: "常规", .french: "Général"],
        "settings.about": [.english: "About", .vietnamese: "Giới thiệu", .chinese: "关于", .french: "À propos"],
        "settings.startup": [.english: "Startup", .vietnamese: "Khởi động", .chinese: "启动", .french: "Démarrage"],
        "settings.appearance": [.english: "Appearance", .vietnamese: "Giao diện", .chinese: "外观", .french: "Apparence"],
        "settings.launchAtLogin": [.english: "Launch at login", .vietnamese: "Khởi động cùng hệ thống", .chinese: "登录时启动", .french: "Lancer à la connexion"],
        "settings.showInDock": [.english: "Show in Dock", .vietnamese: "Hiển thị trên Dock", .chinese: "在 Dock 中显示", .french: "Afficher dans le Dock"],
        "settings.restartForEffect": [.english: "Restart app for full effect", .vietnamese: "Khởi động lại ứng dụng để có hiệu lực đầy đủ", .chinese: "重启应用以完全生效", .french: "Redémarrer l'application pour un effet complet"],
        "settings.apiKeys": [.english: "API Keys", .vietnamese: "Khóa API", .chinese: "API 密钥", .french: "Clés API"],
        "settings.apiKeysHelp": [.english: "API keys for clients to authenticate with the proxy", .vietnamese: "Khóa API để các client xác thực với proxy", .chinese: "客户端用于与代理认证的 API 密钥", .french: "Clés API pour l'authentification des clients avec le proxy"],
        "settings.addAPIKey": [.english: "Add API Key", .vietnamese: "Thêm khóa API", .chinese: "添加 API 密钥", .french: "Ajouter une clé API"],
        "settings.apiKeyPlaceholder": [.english: "Enter API key...", .vietnamese: "Nhập khóa API...", .chinese: "输入 API 密钥...", .french: "Entrez la clé API..."],
        
        // API Keys Screen
        "apiKeys.list": [.english: "API Keys", .vietnamese: "Danh sách khóa API", .chinese: "API 密钥", .french: "Clés API"],
        "apiKeys.description": [.english: "API keys for clients to authenticate with the proxy service", .vietnamese: "Khóa API để các client xác thực với dịch vụ proxy", .chinese: "客户端用于与代理服务认证的 API 密钥", .french: "Clés API pour l'authentification des clients avec le service proxy"],
        "apiKeys.add": [.english: "Add Key", .vietnamese: "Thêm khóa", .chinese: "添加密钥", .french: "Ajouter une clé"],
        "apiKeys.addHelp": [.english: "Add a new API key", .vietnamese: "Thêm khóa API mới", .chinese: "添加新的 API 密钥", .french: "Ajouter une nouvelle clé API"],
        "apiKeys.generate": [.english: "Generate", .vietnamese: "Tạo ngẫu nhiên", .chinese: "生成", .french: "Générer"],
        "apiKeys.generateHelp": [.english: "Generate a random API key", .vietnamese: "Tạo khóa API ngẫu nhiên", .chinese: "生成随机 API 密钥", .french: "Générer une clé API aléatoire"],
        "apiKeys.generateFirst": [.english: "Generate Your First Key", .vietnamese: "Tạo khóa đầu tiên", .chinese: "生成您的第一个密钥", .french: "Générer votre première clé"],
        "apiKeys.placeholder": [.english: "Enter API key...", .vietnamese: "Nhập khóa API...", .chinese: "输入 API 密钥...", .french: "Entrez la clé API..."],
        "apiKeys.edit": [.english: "Edit", .vietnamese: "Sửa", .chinese: "编辑", .french: "Modifier"],
        "apiKeys.empty": [.english: "No API Keys", .vietnamese: "Chưa có khóa API", .chinese: "无 API 密钥", .french: "Aucune clé API"],
        "apiKeys.emptyDescription": [.english: "Add API keys to authenticate clients with the proxy", .vietnamese: "Thêm khóa API để xác thực client với proxy", .chinese: "添加 API 密钥以与代理进行客户端认证", .french: "Ajoutez des clés API pour authentifier les clients avec le proxy"],
        "apiKeys.proxyRequired": [.english: "Start the proxy to manage API keys", .vietnamese: "Khởi động proxy để quản lý khóa API", .chinese: "启动代理以管理 API 密钥", .french: "Démarrez le proxy pour gérer les clés API"],
        
        // Logs
        "logs.clearLogs": [.english: "Clear Logs", .vietnamese: "Xóa nhật ký", .chinese: "清除日志", .french: "Effacer les journaux"],
        "logs.noLogs": [.english: "No Logs", .vietnamese: "Không có nhật ký", .chinese: "无日志", .french: "Aucun journal"],
        "logs.startProxy": [.english: "Start the proxy to view logs", .vietnamese: "Khởi động proxy để xem nhật ký", .chinese: "启动代理以查看日志", .french: "Démarrez le proxy pour voir les journaux"],
        "logs.logsWillAppear": [.english: "Logs will appear here as requests are processed", .vietnamese: "Nhật ký sẽ xuất hiện khi có yêu cầu được xử lý", .chinese: "处理请求时，日志将在此处显示", .french: "Les journaux apparaîtront ici au fur et à mesure du traitement des requêtes"],
        "logs.searchLogs": [.english: "Search logs...", .vietnamese: "Tìm kiếm nhật ký...", .chinese: "搜索日志...", .french: "Rechercher dans les journaux..."],
        "logs.all": [.english: "All", .vietnamese: "Tất cả", .chinese: "全部", .french: "Tous"],
        "logs.info": [.english: "Info", .vietnamese: "Thông tin", .chinese: "信息", .french: "Info"],
        "logs.warn": [.english: "Warn", .vietnamese: "Cảnh báo", .chinese: "警告", .french: "Avertissement"],
        "logs.error": [.english: "Error", .vietnamese: "Lỗi", .chinese: "错误", .french: "Erreur"],
        "logs.autoScroll": [.english: "Auto-scroll", .vietnamese: "Tự cuộn", .chinese: "自动滚动", .french: "Défilement auto"],
        "logs.tab.requests": [.english: "Requests", .vietnamese: "Yêu cầu", .chinese: "请求", .french: "Requêtes"],
        "logs.tab.proxyLogs": [.english: "Proxy Logs", .vietnamese: "Nhật ký Proxy", .chinese: "代理日志", .french: "Journaux du proxy"],
        "logs.searchRequests": [.english: "Search requests...", .vietnamese: "Tìm kiếm yêu cầu...", .chinese: "搜索请求...", .french: "Rechercher des requêtes..."],
        "logs.noRequests": [.english: "No Requests", .vietnamese: "Chưa có yêu cầu", .chinese: "无请求", .french: "Aucune requête"],
        "logs.requestsWillAppear": [.english: "API requests will appear here as they pass through the proxy", .vietnamese: "Yêu cầu API sẽ xuất hiện khi đi qua proxy", .chinese: "API 请求通过代理时将显示在此处", .french: "Les requêtes API apparaîtront ici lorsqu'elles passeront par le proxy"],
        "logs.stats.totalRequests": [.english: "Total", .vietnamese: "Tổng", .chinese: "总计", .french: "Total"],
        "logs.stats.successRate": [.english: "Success", .vietnamese: "Thành công", .chinese: "成功率", .french: "Succès"],
        "logs.stats.totalTokens": [.english: "Tokens", .vietnamese: "Token", .chinese: "令牌", .french: "Jetons"],
        "logs.stats.avgDuration": [.english: "Avg Time", .vietnamese: "TB Thời gian", .chinese: "平均时间", .french: "Temps moy."],
        "logs.filter.allProviders": [.english: "All Providers", .vietnamese: "Tất cả nhà cung cấp", .chinese: "所有提供商", .french: "Tous les fournisseurs"],
        
        // Actions
        "action.start": [.english: "Start", .vietnamese: "Bắt đầu", .chinese: "开始", .french: "Démarrer"],
        "action.stop": [.english: "Stop", .vietnamese: "Dừng", .chinese: "停止", .french: "Arrêter"],
        "action.startProxy": [.english: "Start Proxy", .vietnamese: "Khởi động Proxy", .chinese: "启动代理", .french: "Démarrer le proxy"],
        "action.stopProxy": [.english: "Stop Proxy", .vietnamese: "Dừng Proxy", .chinese: "停止代理", .french: "Arrêter le proxy"],
        "action.copy": [.english: "Copy", .vietnamese: "Sao chép", .chinese: "复制", .french: "Copier"],
        "action.delete": [.english: "Delete", .vietnamese: "Xóa", .chinese: "删除", .french: "Supprimer"],
        "action.refresh": [.english: "Refresh", .vietnamese: "Làm mới", .chinese: "刷新", .french: "Actualiser"],
        "action.copyCode": [.english: "Copy Code", .vietnamese: "Sao chép mã", .chinese: "复制代码", .french: "Copier le code"],
        "action.quit": [.english: "Quit Quotio", .vietnamese: "Thoát Quotio", .chinese: "退出 Quotio", .french: "Quitter Quotio"],
        "action.openApp": [.english: "Open Quotio", .vietnamese: "Mở Quotio", .chinese: "打开 Quotio", .french: "Ouvrir Quotio"],
        
        // Empty states
        "empty.proxyNotRunning": [.english: "Proxy Not Running", .vietnamese: "Proxy chưa chạy", .chinese: "代理未运行", .french: "Proxy non démarré"],
        "empty.startProxyToView": [.english: "Start the proxy to view quota information", .vietnamese: "Khởi động proxy để xem thông tin hạn mức", .chinese: "启动代理以查看配额信息", .french: "Démarrez le proxy pour voir les informations de quota"],
        "empty.noAccounts": [.english: "No Accounts", .vietnamese: "Chưa có tài khoản", .chinese: "无账户", .french: "Aucun compte"],
        "empty.addProviderAccounts": [.english: "Add provider accounts to view quota", .vietnamese: "Thêm tài khoản nhà cung cấp để xem hạn mức", .chinese: "添加提供商账户以查看配额", .french: "Ajoutez des comptes fournisseur pour voir le quota"],
        
        // Subscription
        "subscription.upgrade": [.english: "Upgrade", .vietnamese: "Nâng cấp", .chinese: "升级", .french: "Mettre à niveau"],
        "subscription.freeTier": [.english: "Free Tier", .vietnamese: "Gói miễn phí", .chinese: "免费套餐", .french: "Gratuit"],
        "subscription.proPlan": [.english: "Pro Plan", .vietnamese: "Gói Pro", .chinese: "专业版", .french: "Plan Pro"],
        "subscription.project": [.english: "Project", .vietnamese: "Dự án", .chinese: "项目", .french: "Projet"],
        
        // OAuth
        "oauth.connect": [.english: "Connect", .vietnamese: "Kết nối", .chinese: "连接", .french: "Connecter"],
        "oauth.authenticateWith": [.english: "Authenticate with your", .vietnamese: "Xác thực với tài khoản", .chinese: "使用您的账户进行认证", .french: "Authentifier avec votre"],
        "oauth.projectId": [.english: "Project ID (optional)", .vietnamese: "ID dự án (tùy chọn)", .chinese: "项目 ID（可选）", .french: "ID du projet (optionnel)"],
        "oauth.projectIdPlaceholder": [.english: "Enter project ID...", .vietnamese: "Nhập ID dự án...", .chinese: "输入项目 ID...", .french: "Entrez l'ID du projet..."],
        "oauth.authenticate": [.english: "Authenticate", .vietnamese: "Xác thực", .chinese: "认证", .french: "Authentifier"],
        "oauth.retry": [.english: "Try Again", .vietnamese: "Thử lại", .chinese: "重试", .french: "Réessayer"],
        "oauth.openingBrowser": [.english: "Opening browser...", .vietnamese: "Đang mở trình duyệt...", .chinese: "正在打开浏览器...", .french: "Ouverture du navigateur..."],
        "oauth.waitingForAuth": [.english: "Waiting for authentication", .vietnamese: "Đang chờ xác thực", .chinese: "等待认证", .french: "En attente d'authentification"],
        "oauth.completeBrowser": [.english: "Complete the login in your browser", .vietnamese: "Hoàn tất đăng nhập trong trình duyệt", .chinese: "在浏览器中完成登录", .french: "Terminez la connexion dans votre navigateur"],
        "oauth.success": [.english: "Connected successfully!", .vietnamese: "Kết nối thành công!", .chinese: "连接成功！", .french: "Connexion réussie !"],
        "oauth.closingSheet": [.english: "Closing...", .vietnamese: "Đang đóng...", .chinese: "正在关闭...", .french: "Fermeture..."],
        "oauth.failed": [.english: "Authentication failed", .vietnamese: "Xác thực thất bại", .chinese: "认证失败", .french: "Échec de l'authentification"],
        "oauth.timeout": [.english: "Authentication timeout", .vietnamese: "Hết thời gian xác thực", .chinese: "认证超时", .french: "Délai d'authentification dépassé"],
        "oauth.authMethod": [.english: "Authentication Method", .vietnamese: "Phương thức xác thực", .chinese: "认证方法", .french: "Méthode d'authentification"],
        "oauth.enterCodeInBrowser": [.english: "Enter this code in browser", .vietnamese: "Nhập mã này trong trình duyệt", .chinese: "在浏览器中输入此代码", .french: "Entrez ce code dans le navigateur"],
        
        "import.vertexKey": [.english: "Import Service Account Key", .vietnamese: "Nhập khóa tài khoản dịch vụ", .chinese: "导入服务账户密钥", .french: "Importer la clé du compte de service"],
        "import.vertexDesc": [.english: "Select the JSON key file for your Vertex AI service account", .vietnamese: "Chọn tệp khóa JSON cho tài khoản dịch vụ Vertex AI", .chinese: "选择您的 Vertex AI 服务账户的 JSON 密钥文件", .french: "Sélectionnez le fichier de clé JSON pour votre compte de service Vertex AI"],
        "import.selectFile": [.english: "Select JSON File", .vietnamese: "Chọn tệp JSON", .chinese: "选择 JSON 文件", .french: "Sélectionner le fichier JSON"],
        "import.success": [.english: "Key imported successfully", .vietnamese: "Đã nhập khóa thành công", .chinese: "密钥导入成功", .french: "Clé importée avec succès"],
        "import.failed": [.english: "Import failed", .vietnamese: "Nhập thất bại", .chinese: "导入失败", .french: "Échec de l'importation"],
        
        // Menu Bar
        "menubar.running": [.english: "Proxy Running", .vietnamese: "Proxy đang chạy", .chinese: "代理运行中", .french: "Proxy en cours"],
        "menubar.stopped": [.english: "Proxy Stopped", .vietnamese: "Proxy đã dừng", .chinese: "代理已停止", .french: "Proxy arrêté"],
        "menubar.accounts": [.english: "Accounts", .vietnamese: "Tài khoản", .chinese: "账户", .french: "Comptes"],
        "menubar.requests": [.english: "Requests", .vietnamese: "Yêu cầu", .chinese: "请求", .french: "Requêtes"],
        "menubar.success": [.english: "Success", .vietnamese: "Thành công", .chinese: "成功", .french: "Succès"],
        "menubar.providers": [.english: "Providers", .vietnamese: "Nhà cung cấp", .chinese: "提供商", .french: "Fournisseurs"],
        "menubar.noProviders": [.english: "No providers connected", .vietnamese: "Chưa kết nối nhà cung cấp", .chinese: "未连接提供商", .french: "Aucun fournisseur connecté"],
        "menubar.andMore": [.english: "+{count} more...", .vietnamese: "+{count} nữa...", .chinese: "+{count} 更多...", .french: "+{count} de plus..."],
        "menubar.openApp": [.english: "Open Quotio", .vietnamese: "Mở Quotio", .chinese: "打开 Quotio", .french: "Ouvrir Quotio"],
        "menubar.quit": [.english: "Quit Quotio", .vietnamese: "Thoát Quotio", .chinese: "退出 Quotio", .french: "Quitter Quotio"],
        "menubar.quota": [.english: "Quota Usage", .vietnamese: "Sử dụng hạn mức", .chinese: "配额使用", .french: "Utilisation du quota"],
        
        // Menu Bar Settings
        "settings.menubar": [.english: "Menu Bar", .vietnamese: "Thanh Menu", .chinese: "菜单栏", .french: "Barre de menus"],
        "settings.menubar.showIcon": [.english: "Show Menu Bar Icon", .vietnamese: "Hiển thị icon trên Menu Bar", .chinese: "显示菜单栏图标", .french: "Afficher l'icône dans la barre de menus"],
        "settings.menubar.showQuota": [.english: "Show Quota in Menu Bar", .vietnamese: "Hiển thị Quota trên Menu Bar", .chinese: "在菜单栏显示配额", .french: "Afficher le quota dans la barre de menus"],
        "settings.menubar.colorMode": [.english: "Color Mode", .vietnamese: "Chế độ màu", .chinese: "颜色模式", .french: "Mode couleur"],
        "settings.menubar.colored": [.english: "Colored", .vietnamese: "Có màu", .chinese: "彩色", .french: "Coloré"],
        "settings.menubar.monochrome": [.english: "Monochrome", .vietnamese: "Trắng đen", .chinese: "单色", .french: "Monochrome"],
        "settings.menubar.selectAccounts": [.english: "Select Accounts to Display", .vietnamese: "Chọn tài khoản hiển thị", .chinese: "选择要显示的账户", .french: "Sélectionner les comptes à afficher"],
        "settings.menubar.selected": [.english: "Displayed", .vietnamese: "Đang hiển thị", .chinese: "已显示", .french: "Affiché"],
        "settings.menubar.noQuotaData": [.english: "No quota data available. Add accounts with quota support.", .vietnamese: "Không có dữ liệu quota. Thêm tài khoản hỗ trợ quota.", .chinese: "无配额数据可用。添加支持配额的账户。", .french: "Aucune donnée de quota disponible. Ajoutez des comptes avec support quota."],
        "settings.menubar.help": [.english: "Choose which accounts to show in the menu bar. Maximum 3 items will be displayed.", .vietnamese: "Chọn tài khoản muốn hiển thị trên thanh menu. Tối đa 3 mục.", .chinese: "选择要在菜单栏显示的账户。最多显示 3 项。", .french: "Choisissez les comptes à afficher dans la barre de menus. Maximum 3 éléments."],
        
        "menubar.showOnMenuBar": [.english: "Show on Menu Bar", .vietnamese: "Hiển thị trên Menu Bar", .chinese: "在菜单栏显示", .french: "Afficher dans la barre de menus"],
        "menubar.hideFromMenuBar": [.english: "Hide from Menu Bar", .vietnamese: "Ẩn khỏi Menu Bar", .chinese: "从菜单栏隐藏", .french: "Masquer de la barre de menus"],
        "menubar.limitReached": [.english: "Menu bar limit reached", .vietnamese: "Đã đạt giới hạn Menu Bar", .chinese: "已达到菜单栏限制", .french: "Limite de la barre de menus atteinte"],
        
        "menubar.warning.title": [.english: "Too Many Items", .vietnamese: "Quá nhiều mục", .chinese: "项目过多", .french: "Trop d'éléments"],
        "menubar.warning.message": [.english: "Displaying more than 3 items may make the menu bar cluttered. Are you sure you want to continue?", .vietnamese: "Hiển thị hơn 3 mục có thể làm thanh menu lộn xộn. Bạn có chắc muốn tiếp tục?", .chinese: "显示超过 3 项可能会使菜单栏混乱。您确定要继续吗？", .french: "Afficher plus de 3 éléments peut encombrer la barre de menus. Êtes-vous sûr de vouloir continuer ?"],
        "menubar.warning.confirm": [.english: "Add Anyway", .vietnamese: "Vẫn thêm", .chinese: "仍然添加", .french: "Ajouter quand même"],
        "menubar.warning.cancel": [.english: "Cancel", .vietnamese: "Hủy", .chinese: "取消", .french: "Annuler"],
        
        "menubar.info.title": [.english: "Menu Bar Display", .vietnamese: "Hiển thị Menu Bar", .chinese: "菜单栏显示", .french: "Affichage de la barre de menus"],
        "menubar.info.description": [.english: "Click the chart icon to toggle displaying this account's quota in the menu bar.", .vietnamese: "Nhấn vào biểu tượng biểu đồ để bật/tắt hiển thị quota của tài khoản này trên menu bar.", .chinese: "点击图表图标以切换在菜单栏中显示此账户的配额。", .french: "Cliquez sur l'icône du graphique pour activer/désactiver l'affichage du quota de ce compte dans la barre de menus."],
        "menubar.info.enabled": [.english: "Showing in menu bar", .vietnamese: "Đang hiển thị trên menu bar", .chinese: "在菜单栏中显示", .french: "Affiché dans la barre de menus"],
        "menubar.info.disabled": [.english: "Not showing in menu bar", .vietnamese: "Không hiển thị trên menu bar", .chinese: "不在菜单栏中显示", .french: "Non affiché dans la barre de menus"],
        "menubar.hint": [.english: "Click the chart icon to toggle menu bar display", .vietnamese: "Nhấn biểu tượng biểu đồ để bật/tắt hiển thị trên menu bar", .chinese: "点击图表图标以切换菜单栏显示", .french: "Cliquez sur l'icône du graphique pour activer/désactiver l'affichage"],
        
        // Quota Display Mode Settings
        "settings.quota.display": [.english: "Quota Display", .vietnamese: "Hiển thị Quota", .chinese: "配额显示", .french: "Affichage du quota"],
        "settings.quota.display.help": [.english: "Choose how to display quota percentages across the app.", .vietnamese: "Chọn cách hiển thị phần trăm quota trong ứng dụng.", .chinese: "选择如何在应用中显示配额百分比。", .french: "Choisissez comment afficher les pourcentages de quota dans l'application."],
        "settings.quota.displayMode": [.english: "Display Mode", .vietnamese: "Chế độ hiển thị", .chinese: "显示模式", .french: "Mode d'affichage"],
        "settings.quota.displayMode.used": [.english: "Used", .vietnamese: "Đã dùng", .chinese: "已使用", .french: "Utilisé"],
        "settings.quota.displayMode.remaining": [.english: "Remaining", .vietnamese: "Còn lại", .chinese: "剩余", .french: "Restant"],
        "settings.quota.used": [.english: "used", .vietnamese: "đã dùng", .chinese: "已使用", .french: "utilisé"],
        "settings.quota.left": [.english: "left", .vietnamese: "còn lại", .chinese: "剩余", .french: "restant"],
        
        // Notifications
        "settings.notifications": [.english: "Notifications", .vietnamese: "Thông báo", .chinese: "通知", .french: "Notifications"],
        "settings.notifications.enabled": [.english: "Enable Notifications", .vietnamese: "Bật thông báo", .chinese: "启用通知", .french: "Activer les notifications"],
        "settings.notifications.quotaLow": [.english: "Quota Low Warning", .vietnamese: "Cảnh báo hạn mức thấp", .chinese: "配额低警告", .french: "Avertissement quota faible"],
        "settings.notifications.cooling": [.english: "Account Cooling Alert", .vietnamese: "Cảnh báo tài khoản đang nghỉ", .chinese: "账户冷却警报", .french: "Alerte refroidissement du compte"],
        "settings.notifications.proxyCrash": [.english: "Proxy Crash Alert", .vietnamese: "Cảnh báo proxy bị lỗi", .chinese: "代理崩溃警报", .french: "Alerte crash du proxy"],
        "settings.notifications.upgradeAvailable": [.english: "Proxy Update Available", .vietnamese: "Có bản cập nhật Proxy", .chinese: "代理更新可用", .french: "Mise à jour du proxy disponible"],
        "settings.notifications.threshold": [.english: "Alert Threshold", .vietnamese: "Ngưỡng cảnh báo", .chinese: "警报阈值", .french: "Seuil d'alerte"],
        "settings.notifications.help": [.english: "Get notified when quota is low, accounts enter cooling, proxy crashes, or updates are available", .vietnamese: "Nhận thông báo khi hạn mức thấp, tài khoản đang nghỉ, proxy bị lỗi, hoặc có bản cập nhật", .chinese: "当配额低、账户进入冷却、代理崩溃或有更新可用时收到通知", .french: "Soyez notifié lorsque le quota est faible, les comptes entrent en refroidissement, le proxy plante, ou des mises à jour sont disponibles"],
        "settings.notifications.notAuthorized": [.english: "Notifications not authorized. Enable in System Settings.", .vietnamese: "Thông báo chưa được cấp quyền. Bật trong Cài đặt hệ thống.", .chinese: "通知未授权。在系统设置中启用。", .french: "Notifications non autorisées. Activez dans les Préférences Système."],
        
        "notification.quotaLow.title": [.english: "⚠️ Quota Low", .vietnamese: "⚠️ Hạn mức thấp", .chinese: "⚠️ 配额低", .french: "⚠️ Quota faible"],
        "notification.quotaLow.body": [.english: "%@ (%@): Only %d%% quota remaining", .vietnamese: "%@ (%@): Chỉ còn %d%% hạn mức", .chinese: "%@ (%@)：仅剩 %d%% 配额", .french: "%@ (%@) : Seulement %d%% de quota restant"],
        "notification.cooling.title": [.english: "❄️ Account Cooling", .vietnamese: "❄️ Tài khoản đang nghỉ", .chinese: "❄️ 账户冷却", .french: "❄️ Compte en refroidissement"],
        "notification.cooling.body": [.english: "%@ (%@) has entered cooling status", .vietnamese: "%@ (%@) đã vào trạng thái nghỉ", .chinese: "%@ (%@) 已进入冷却状态", .french: "%@ (%@) est entré en état de refroidissement"],
        "notification.proxyCrash.title": [.english: "🚨 Proxy Crashed", .vietnamese: "🚨 Proxy bị lỗi", .chinese: "🚨 代理崩溃", .french: "🚨 Proxy planté"],
        "notification.proxyCrash.body": [.english: "Proxy process exited with code %d", .vietnamese: "Tiến trình proxy đã thoát với mã %d", .chinese: "代理进程退出，代码 %d", .french: "Le processus proxy s'est terminé avec le code %d"],
        "notification.proxyStarted.title": [.english: "✅ Proxy Started", .vietnamese: "✅ Proxy đã khởi động", .chinese: "✅ 代理已启动", .french: "✅ Proxy démarré"],
        "notification.proxyStarted.body": [.english: "Proxy server is now running", .vietnamese: "Máy chủ proxy đang chạy", .chinese: "代理服务器正在运行", .french: "Le serveur proxy est maintenant en cours d'exécution"],
        "notification.upgradeAvailable.title": [.english: "🆕 Proxy Update Available", .vietnamese: "🆕 Có bản cập nhật Proxy", .chinese: "🆕 代理更新可用", .french: "🆕 Mise à jour du proxy disponible"],
        "notification.upgradeAvailable.body": [.english: "CLIProxyAPI v%@ is available. Open Settings to update.", .vietnamese: "CLIProxyAPI v%@ đã có. Mở Cài đặt để cập nhật.", .chinese: "CLIProxyAPI v%@ 可用。打开设置进行更新。", .french: "CLIProxyAPI v%@ est disponible. Ouvrez les Paramètres pour mettre à jour."],
        
        // Agent Setup
        "nav.agents": [.english: "Agents", .vietnamese: "Agent", .chinese: "代理", .french: "Agents"],
        "agents.title": [.english: "AI Agent Setup", .vietnamese: "Cài đặt AI Agent", .chinese: "AI 代理设置", .french: "Configuration des agents IA"],
        "agents.subtitle": [.english: "Configure CLI agents to use CLIProxyAPI", .vietnamese: "Cấu hình CLI agent để sử dụng CLIProxyAPI", .chinese: "配置 CLI 代理以使用 CLIProxyAPI", .french: "Configurer les agents CLI pour utiliser CLIProxyAPI"],
        "agents.installed": [.english: "Installed", .vietnamese: "Đã cài đặt", .chinese: "已安装", .french: "Installé"],
        "agents.notInstalled": [.english: "Not Installed", .vietnamese: "Chưa cài đặt", .chinese: "未安装", .french: "Non installé"],
        "agents.configured": [.english: "Configured", .vietnamese: "Đã cấu hình", .chinese: "已配置", .french: "Configuré"],
        "agents.configure": [.english: "Configure", .vietnamese: "Cấu hình", .chinese: "配置", .french: "Configurer"],
        "agents.reconfigure": [.english: "Reconfigure", .vietnamese: "Cấu hình lại", .chinese: "重新配置", .french: "Reconfigurer"],
        "agents.test": [.english: "Test Connection", .vietnamese: "Kiểm tra kết nối", .chinese: "测试连接", .french: "Tester la connexion"],
        "agents.docs": [.english: "Documentation", .vietnamese: "Tài liệu", .chinese: "文档", .french: "Documentation"],
        
        // Configuration Modes
        "agents.mode": [.english: "Configuration Mode", .vietnamese: "Chế độ cấu hình", .chinese: "配置模式", .french: "Mode de configuration"],
        "agents.mode.automatic": [.english: "Automatic", .vietnamese: "Tự động", .chinese: "自动", .french: "Automatique"],
        "agents.mode.manual": [.english: "Manual", .vietnamese: "Thủ công", .chinese: "手动", .french: "Manuel"],
        "agents.mode.automatic.desc": [.english: "Directly update config files and shell profile", .vietnamese: "Tự động cập nhật file cấu hình và shell profile", .chinese: "直接更新配置文件和 shell 配置文件", .french: "Mettre à jour directement les fichiers de configuration et le profil shell"],
        "agents.mode.manual.desc": [.english: "View and copy configuration manually", .vietnamese: "Xem và sao chép cấu hình thủ công", .chinese: "手动查看和复制配置", .french: "Voir et copier la configuration manuellement"],
        "agents.applyConfig": [.english: "Apply Configuration", .vietnamese: "Áp dụng cấu hình", .chinese: "应用配置", .french: "Appliquer la configuration"],
        "agents.generateConfig": [.english: "Generate Configuration", .vietnamese: "Tạo cấu hình", .chinese: "生成配置", .french: "Générer la configuration"],
        "agents.configGenerated": [.english: "Configuration Generated", .vietnamese: "Đã tạo cấu hình", .chinese: "配置已生成", .french: "Configuration générée"],
        "agents.copyInstructions": [.english: "Copy the configuration below and apply manually", .vietnamese: "Sao chép cấu hình bên dưới và áp dụng thủ công", .chinese: "复制下面的配置并手动应用", .french: "Copiez la configuration ci-dessous et appliquez-la manuellement"],
        
        // Model Slots
        "agents.modelSlots": [.english: "Model Slots", .vietnamese: "Slot mô hình", .chinese: "模型槽", .french: "Emplacements de modèle"],
        "agents.modelSlots.opus": [.english: "Opus (High Intelligence)", .vietnamese: "Opus (Thông minh cao)", .chinese: "Opus（高智能）", .french: "Opus (Haute intelligence)"],
        "agents.modelSlots.sonnet": [.english: "Sonnet (Balanced)", .vietnamese: "Sonnet (Cân bằng)", .chinese: "Sonnet（平衡）", .french: "Sonnet (Équilibré)"],
        "agents.modelSlots.haiku": [.english: "Haiku (Fast)", .vietnamese: "Haiku (Nhanh)", .chinese: "Haiku（快速）", .french: "Haiku (Rapide)"],
        "agents.selectModel": [.english: "Select Model", .vietnamese: "Chọn mô hình", .chinese: "选择模型", .french: "Sélectionner le modèle"],
        
        // Config Types
        "agents.config.env": [.english: "Environment Variables", .vietnamese: "Biến môi trường", .chinese: "环境变量", .french: "Variables d'environnement"],
        "agents.config.file": [.english: "Configuration Files", .vietnamese: "Tệp cấu hình", .chinese: "配置文件", .french: "Fichiers de configuration"],
        "agents.copyConfig": [.english: "Copy to Clipboard", .vietnamese: "Sao chép", .chinese: "复制到剪贴板", .french: "Copier dans le presse-papiers"],
        "agents.addToShell": [.english: "Add to Shell Profile", .vietnamese: "Thêm vào Shell Profile", .chinese: "添加到 Shell 配置文件", .french: "Ajouter au profil Shell"],
        "agents.shellAdded": [.english: "Added to shell profile", .vietnamese: "Đã thêm vào shell profile", .chinese: "已添加到 shell 配置文件", .french: "Ajouté au profil shell"],
        "agents.copied": [.english: "Copied to clipboard", .vietnamese: "Đã sao chép", .chinese: "已复制", .french: "Copié dans le presse-papiers"],
        
        // Status Messages
        "agents.configSuccess": [.english: "Configuration complete!", .vietnamese: "Cấu hình hoàn tất!", .chinese: "配置完成！", .french: "Configuration terminée !"],
        "agents.configFailed": [.english: "Configuration failed", .vietnamese: "Cấu hình thất bại", .chinese: "配置失败", .french: "Échec de la configuration"],
        "agents.testSuccess": [.english: "Connection successful!", .vietnamese: "Kết nối thành công!", .chinese: "连接成功！", .french: "Connexion réussie !"],
        "agents.testFailed": [.english: "Connection failed", .vietnamese: "Kết nối thất bại", .chinese: "连接失败", .french: "Échec de la connexion"],
        
        // Instructions
        "agents.instructions.restart": [.english: "Restart your terminal for changes to take effect", .vietnamese: "Khởi động lại terminal để thay đổi có hiệu lực", .chinese: "重启终端以使更改生效", .french: "Redémarrez votre terminal pour que les modifications prennent effet"],
        "agents.instructions.env": [.english: "Add these environment variables to your shell profile:", .vietnamese: "Thêm các biến môi trường này vào shell profile:", .chinese: "将这些环境变量添加到您的 shell 配置文件：", .french: "Ajoutez ces variables d'environnement à votre profil shell :"],
        "agents.instructions.file": [.english: "Configuration files have been created:", .vietnamese: "Các tệp cấu hình đã được tạo:", .chinese: "配置文件已创建：", .french: "Les fichiers de configuration ont été créés :"],
        "agents.proxyNotRunning": [.english: "Start the proxy to configure agents", .vietnamese: "Khởi động proxy để cấu hình agent", .chinese: "启动代理以配置代理", .french: "Démarrez le proxy pour configurer les agents"],
        "agents.proxyRequired.title": [.english: "Proxy Required", .vietnamese: "Cần khởi động Proxy", .chinese: "需要代理", .french: "Proxy requis"],
        "agents.proxyRequired.message": [.english: "The proxy server must be running to configure agents. Start the proxy first.", .vietnamese: "Cần khởi động proxy để cấu hình agent. Hãy khởi động proxy trước.", .chinese: "必须运行代理服务器才能配置代理。请先启动代理。", .french: "Le serveur proxy doit être en cours d'exécution pour configurer les agents. Démarrez d'abord le proxy."],
        
        // Auth Modes
        "agents.oauthMode": [.english: "Use OAuth Authentication", .vietnamese: "Sử dụng xác thực OAuth", .chinese: "使用 OAuth 认证", .french: "Utiliser l'authentification OAuth"],
        "agents.apiKeyMode": [.english: "Use API Key Authentication", .vietnamese: "Sử dụng xác thực API Key", .chinese: "使用 API 密钥认证", .french: "Utiliser l'authentification par clé API"],
        
        // Agent Config Sheet
        "agents.configMode": [.english: "Configuration Mode", .vietnamese: "Chế độ cấu hình", .chinese: "配置模式", .french: "Mode de configuration"],
        "agents.connectionInfo": [.english: "Connection Info", .vietnamese: "Thông tin kết nối", .chinese: "连接信息", .french: "Informations de connexion"],
        "agents.proxyURL": [.english: "Proxy URL", .vietnamese: "URL Proxy", .chinese: "代理 URL", .french: "URL du proxy"],
        "agents.apiKey": [.english: "API Key", .vietnamese: "Khóa API", .chinese: "API 密钥", .french: "Clé API"],
        "agents.shell": [.english: "Shell", .vietnamese: "Shell", .chinese: "Shell", .french: "Shell"],
        "agents.modelSlotsDesc": [.english: "Configure which models to use for each slot", .vietnamese: "Cấu hình mô hình sử dụng cho mỗi slot", .chinese: "配置每个槽使用的模型", .french: "Configurer les modèles à utiliser pour chaque emplacement"],
        "agents.useOAuth": [.english: "Use OAuth Authentication", .vietnamese: "Sử dụng xác thực OAuth", .chinese: "使用 OAuth 认证", .french: "Utiliser l'authentification OAuth"],
        "agents.useOAuthDesc": [.english: "Use your existing Google OAuth credentials", .vietnamese: "Sử dụng thông tin đăng nhập Google OAuth hiện có", .chinese: "使用您现有的 Google OAuth 凭据", .french: "Utiliser vos identifiants Google OAuth existants"],
        "agents.testConnection": [.english: "Test Connection", .vietnamese: "Kiểm tra kết nối", .chinese: "测试连接", .french: "Tester la connexion"],
        "agents.filesModified": [.english: "Files Modified", .vietnamese: "Các tệp đã thay đổi", .chinese: "已修改的文件", .french: "Fichiers modifiés"],
        "agents.rawConfigs": [.english: "Raw Configurations", .vietnamese: "Cấu hình thô", .chinese: "原始配置", .french: "Configurations brutes"],
        "agents.apply": [.english: "Apply", .vietnamese: "Áp dụng", .chinese: "应用", .french: "Appliquer"],
        "agents.generate": [.english: "Generate", .vietnamese: "Tạo", .chinese: "生成", .french: "Générer"],
        "agents.viewDocs": [.english: "View Docs", .vietnamese: "Xem tài liệu", .chinese: "查看文档", .french: "Voir la documentation"],
        
        // Actions (more)
        "action.copyAll": [.english: "Copy All", .vietnamese: "Sao chép tất cả", .chinese: "全部复制", .french: "Tout copier"],
        "action.done": [.english: "Done", .vietnamese: "Xong", .chinese: "完成", .french: "Terminé"],
        "action.cancel": [.english: "Cancel", .vietnamese: "Hủy", .chinese: "取消", .french: "Annuler"],
        "action.edit": [.english: "Edit", .vietnamese: "Sửa", .chinese: "编辑", .french: "Modifier"],
        "action.ok": [.english: "OK", .vietnamese: "Đồng ý", .chinese: "确定", .french: "OK"],
        "agents.saveConfig": [.english: "Save Config", .vietnamese: "Lưu cấu hình", .chinese: "保存配置", .french: "Enregistrer la configuration"],
        
        // Storage Options
        "agents.storageOption": [.english: "Storage Location", .vietnamese: "Vị trí lưu trữ", .chinese: "存储位置", .french: "Emplacement de stockage"],
        "agents.storage.jsonOnly": [.english: "JSON Config", .vietnamese: "JSON Config", .chinese: "JSON 配置", .french: "Config JSON"],
        "agents.storage.shellOnly": [.english: "Shell Profile", .vietnamese: "Shell Profile", .chinese: "Shell 配置文件", .french: "Profil Shell"],
        "agents.storage.both": [.english: "Both", .vietnamese: "Cả hai", .chinese: "两者", .french: "Les deux"],
        
        // Updates
        "settings.updates": [.english: "Updates", .vietnamese: "Cập nhật", .chinese: "更新", .french: "Mises à jour"],
        "settings.autoCheckUpdates": [.english: "Automatically check for updates", .vietnamese: "Tự động kiểm tra cập nhật", .chinese: "自动检查更新", .french: "Vérifier automatiquement les mises à jour"],
        "settings.lastChecked": [.english: "Last checked", .vietnamese: "Lần kiểm tra cuối", .chinese: "上次检查", .french: "Dernière vérification"],
        "settings.never": [.english: "Never", .vietnamese: "Chưa bao giờ", .chinese: "从未", .french: "Jamais"],
        "settings.checkNow": [.english: "Check Now", .vietnamese: "Kiểm tra ngay", .chinese: "立即检查", .french: "Vérifier maintenant"],
        "settings.version": [.english: "Version", .vietnamese: "Phiên bản", .chinese: "版本", .french: "Version"],
        
        // Update Channel
        "settings.updateChannel": [.english: "Update Channel", .vietnamese: "Kênh cập nhật", .chinese: "更新渠道", .french: "Canal de mise à jour"],
        "settings.updateChannel.title": [.english: "Update Channel", .vietnamese: "Kênh cập nhật", .chinese: "更新渠道", .french: "Canal de mise à jour"],
        "settings.updateChannel.stable": [.english: "Stable", .vietnamese: "Ổn định", .chinese: "稳定版", .french: "Stable"],
        "settings.updateChannel.beta": [.english: "Beta", .vietnamese: "Beta", .chinese: "测试版", .french: "Bêta"],
        "settings.updateChannel.receiveBeta": [.english: "Receive beta updates", .vietnamese: "Nhận bản cập nhật beta", .chinese: "接收测试版更新", .french: "Recevoir les mises à jour bêta"],
        "settings.updateChannel.betaWarning": [.english: "Beta versions may contain bugs and incomplete features. Use at your own risk.", .vietnamese: "Phiên bản Beta có thể chứa lỗi và tính năng chưa hoàn chỉnh. Sử dụng theo rủi ro của bạn.", .chinese: "测试版可能包含错误和不完整的功能。使用风险自负。", .french: "Les versions bêta peuvent contenir des bugs et des fonctionnalités incomplètes. À utiliser à vos risques."],
        "settings.updateChannel.help": [.english: "Choose which updates to receive. Beta includes pre-release versions.", .vietnamese: "Chọn loại cập nhật muốn nhận. Beta bao gồm các phiên bản thử nghiệm.", .chinese: "选择要接收的更新类型。测试版包括预发布版本。", .french: "Choisissez les mises à jour à recevoir. Bêta inclut les versions préliminaires."],
        "settings.updateChannel.downgrade.title": [.english: "Switch to Stable?", .vietnamese: "Chuyển sang Ổn định?", .chinese: "切换到稳定版？", .french: "Passer à Stable ?"],
        "settings.updateChannel.downgrade.message": [.english: "You're currently on a beta version. Switching to Stable means you won't receive updates until a newer stable version is released.", .vietnamese: "Bạn đang sử dụng phiên bản beta. Chuyển sang Ổn định có nghĩa là bạn sẽ không nhận được cập nhật cho đến khi có phiên bản ổn định mới hơn.", .chinese: "您当前使用的是测试版。切换到稳定版意味着在发布更新的稳定版之前，您将不会收到更新。", .french: "Vous êtes actuellement sur une version bêta. Passer à Stable signifie que vous ne recevrez pas de mises à jour jusqu'à la sortie d'une nouvelle version stable."],
        "settings.updateChannel.downgrade.stayBeta": [.english: "Stay on Beta", .vietnamese: "Giữ Beta", .chinese: "保持测试版", .french: "Rester sur Bêta"],
        "settings.updateChannel.downgrade.switchStable": [.english: "Switch to Stable", .vietnamese: "Chuyển sang Ổn định", .chinese: "切换到稳定版", .french: "Passer à Stable"],
        
        // Proxy Updates
        "settings.proxyUpdate": [.english: "Proxy Updates", .vietnamese: "Cập nhật Proxy", .chinese: "代理更新", .french: "Mises à jour du proxy"],
        "settings.proxyUpdate.currentVersion": [.english: "Current Version", .vietnamese: "Phiên bản hiện tại", .chinese: "当前版本", .french: "Version actuelle"],
        "settings.proxyUpdate.unknown": [.english: "Unknown", .vietnamese: "Không xác định", .chinese: "未知", .french: "Inconnu"],
        "settings.proxyUpdate.available": [.english: "Update Available", .vietnamese: "Có bản cập nhật", .chinese: "有可用更新", .french: "Mise à jour disponible"],
        "settings.proxyUpdate.upToDate": [.english: "Up to date", .vietnamese: "Đã cập nhật", .chinese: "已是最新", .french: "À jour"],
        "settings.proxyUpdate.checkNow": [.english: "Check for Updates", .vietnamese: "Kiểm tra cập nhật", .chinese: "检查更新", .french: "Vérifier les mises à jour"],
        "settings.proxyUpdate.proxyMustRun": [.english: "Proxy must be running to check for updates", .vietnamese: "Proxy phải đang chạy để kiểm tra cập nhật", .chinese: "代理必须运行才能检查更新", .french: "Le proxy doit être en cours d'exécution pour vérifier les mises à jour"],
        "settings.proxyUpdate.help": [.english: "Managed updates with dry-run validation ensure safe upgrades", .vietnamese: "Cập nhật có kiểm soát với xác thực thử nghiệm đảm bảo nâng cấp an toàn", .chinese: "具有预演验证的托管更新可确保安全升级", .french: "Les mises à jour gérées avec validation à blanc garantissent des mises à niveau sûres"],
        
        // Proxy Updates - Advanced Mode
        "settings.proxyUpdate.advanced": [.english: "Advanced", .vietnamese: "Nâng cao", .chinese: "高级", .french: "Avancé"],
        "settings.proxyUpdate.advanced.title": [.english: "Version Manager", .vietnamese: "Quản lý phiên bản", .chinese: "版本管理器", .french: "Gestionnaire de versions"],
        "settings.proxyUpdate.advanced.description": [.english: "Install a specific proxy version", .vietnamese: "Cài đặt phiên bản proxy cụ thể", .chinese: "安装特定的代理版本", .french: "Installer une version spécifique du proxy"],
        "settings.proxyUpdate.advanced.availableVersions": [.english: "Available Versions", .vietnamese: "Phiên bản khả dụng", .chinese: "可用版本", .french: "Versions disponibles"],
        "settings.proxyUpdate.advanced.installedVersions": [.english: "Installed Versions", .vietnamese: "Phiên bản đã cài", .chinese: "已安装版本", .french: "Versions installées"],
        "settings.proxyUpdate.advanced.current": [.english: "Current", .vietnamese: "Hiện tại", .chinese: "当前", .french: "Actuel"],
        "settings.proxyUpdate.advanced.install": [.english: "Install", .vietnamese: "Cài đặt", .chinese: "安装", .french: "Installer"],
        "settings.proxyUpdate.advanced.activate": [.english: "Activate", .vietnamese: "Kích hoạt", .chinese: "激活", .french: "Activer"],
        "settings.proxyUpdate.advanced.delete": [.english: "Delete", .vietnamese: "Xóa", .chinese: "删除", .french: "Supprimer"],
        "settings.proxyUpdate.advanced.prerelease": [.english: "Pre-release", .vietnamese: "Thử nghiệm", .chinese: "预发布", .french: "Pré-version"],
        "settings.proxyUpdate.advanced.loading": [.english: "Loading releases...", .vietnamese: "Đang tải danh sách...", .chinese: "正在加载版本...", .french: "Chargement des versions..."],
        "settings.proxyUpdate.advanced.noReleases": [.english: "No releases found", .vietnamese: "Không tìm thấy phiên bản", .chinese: "未找到版本", .french: "Aucune version trouvée"],
        "settings.proxyUpdate.advanced.installed": [.english: "Installed", .vietnamese: "Đã cài", .chinese: "已安装", .french: "Installé"],
        "settings.proxyUpdate.advanced.installing": [.english: "Installing...", .vietnamese: "Đang cài đặt...", .chinese: "正在安装...", .french: "Installation..."],
        "settings.proxyUpdate.advanced.fetchError": [.english: "Failed to fetch releases", .vietnamese: "Không thể tải danh sách phiên bản", .chinese: "无法获取版本", .french: "Échec du chargement des versions"],
        
        // About Screen
        "about.tagline": [.english: "Your AI Coding Command Center", .vietnamese: "Trung tâm điều khiển AI Coding của bạn", .chinese: "您的 AI 编码指挥中心", .french: "Votre centre de commande IA pour le code"],
        "about.description": [.english: "Quotio is a native macOS application for managing CLIProxyAPI - a local proxy server that powers your AI coding agents. Manage multiple AI accounts, track quotas, and configure CLI tools in one place.", .vietnamese: "Quotio là ứng dụng macOS để quản lý CLIProxyAPI - máy chủ proxy cục bộ hỗ trợ các AI coding agent. Quản lý nhiều tài khoản AI, theo dõi hạn mức và cấu hình các công cụ CLI tại một nơi.", .chinese: "Quotio 是一个原生 macOS 应用程序，用于管理 CLIProxyAPI - 一个为您的 AI 编码代理提供支持的本地代理服务器。在一个地方管理多个 AI 账户、跟踪配额和配置 CLI 工具。", .french: "Quotio est une application macOS native pour gérer CLIProxyAPI - un serveur proxy local qui alimente vos agents de codage IA. Gérez plusieurs comptes IA, suivez les quotas et configurez les outils CLI en un seul endroit."],
        "about.multiAccount": [.english: "Multi-Account", .vietnamese: "Đa tài khoản", .chinese: "多账户", .french: "Multi-comptes"],
        "about.quotaTracking": [.english: "Quota Tracking", .vietnamese: "Theo dõi quota", .chinese: "配额跟踪", .french: "Suivi des quotas"],
        "about.agentConfig": [.english: "Agent Config", .vietnamese: "Cấu hình Agent", .chinese: "代理配置", .french: "Config. des agents"],
        "about.buyMeCoffee": [.english: "Buy Me a Coffee", .vietnamese: "Mua cho tôi ly cà phê", .chinese: "请我喝咖啡", .french: "Offrez-moi un café"],
        "about.support": [.english: "Support Us", .vietnamese: "Ủng hộ", .chinese: "支持我们", .french: "Nous soutenir"],
        "about.madeWith": [.english: "Made with ❤️ in Vietnam", .vietnamese: "Được tạo với ❤️ tại Việt Nam", .chinese: "用 ❤️ 在越南制作", .french: "Fait avec ❤️ au Vietnam"],
        
        // Onboarding
        "onboarding.installCLI": [.english: "Install CLIProxyAPI", .vietnamese: "Cài đặt CLIProxyAPI", .chinese: "安装 CLIProxyAPI", .french: "Installer CLIProxyAPI"],
        "onboarding.installCLIDesc": [.english: "Download the proxy binary to get started", .vietnamese: "Tải xuống binary proxy để bắt đầu", .chinese: "下载代理二进制文件以开始", .french: "Téléchargez le binaire du proxy pour commencer"],
        "onboarding.startProxy": [.english: "Start Proxy Server", .vietnamese: "Khởi động Proxy Server", .chinese: "启动代理服务器", .french: "Démarrer le serveur proxy"],
        "onboarding.startProxyDesc": [.english: "Start the local proxy to connect AI providers", .vietnamese: "Khởi động proxy cục bộ để kết nối các nhà cung cấp AI", .chinese: "启动本地代理以连接 AI 提供商", .french: "Démarrez le proxy local pour connecter les fournisseurs IA"],
        "onboarding.addProvider": [.english: "Connect AI Provider", .vietnamese: "Kết nối nhà cung cấp AI", .chinese: "连接 AI 提供商", .french: "Connecter un fournisseur IA"],
        "onboarding.addProviderDesc": [.english: "Add at least one AI provider account", .vietnamese: "Thêm ít nhất một tài khoản nhà cung cấp AI", .chinese: "至少添加一个 AI 提供商账户", .french: "Ajoutez au moins un compte fournisseur IA"],
        "onboarding.connectAccount": [.english: "Connect Account", .vietnamese: "Kết nối tài khoản", .chinese: "连接账户", .french: "Connecter un compte"],
        "onboarding.configureAgent": [.english: "Configure CLI Agent", .vietnamese: "Cấu hình CLI Agent", .chinese: "配置 CLI 代理", .french: "Configurer l'agent CLI"],
        "onboarding.configureAgentDesc": [.english: "Set up your AI coding assistant", .vietnamese: "Thiết lập trợ lý AI coding của bạn", .chinese: "设置您的 AI 编码助手", .french: "Configurez votre assistant de codage IA"],
        "onboarding.complete": [.english: "You're All Set!", .vietnamese: "Đã sẵn sàng!", .chinese: "一切就绪！", .french: "Tout est prêt !"],
        "onboarding.completeDesc": [.english: "Quotio is ready to supercharge your AI coding", .vietnamese: "Quotio đã sẵn sàng tăng cường AI coding của bạn", .chinese: "Quotio 已准备好增强您的 AI 编码", .french: "Quotio est prêt à booster votre codage IA"],
        "onboarding.skip": [.english: "Skip Setup", .vietnamese: "Bỏ qua", .chinese: "跳过设置", .french: "Passer la configuration"],
        "onboarding.goToDashboard": [.english: "Go to Dashboard", .vietnamese: "Đến Dashboard", .chinese: "前往仪表板", .french: "Aller au tableau de bord"],
        "onboarding.providersConfigured": [.english: "providers connected", .vietnamese: "nhà cung cấp đã kết nối", .chinese: "已连接提供商", .french: "fournisseurs connectés"],
        "onboarding.agentsConfigured": [.english: "agents configured", .vietnamese: "agent đã cấu hình", .chinese: "已配置代理", .french: "agents configurés"],
        
        // Dashboard
        "dashboard.gettingStarted": [.english: "Getting Started", .vietnamese: "Bắt đầu", .chinese: "入门", .french: "Démarrage"],
        "action.dismiss": [.english: "Dismiss", .vietnamese: "Ẩn", .chinese: "关闭", .french: "Fermer"],
        
        // Quota-Only Mode - New Keys
        "nav.accounts": [.english: "Accounts", .vietnamese: "Tài khoản", .chinese: "账户", .french: "Comptes"],
        "dashboard.trackedAccounts": [.english: "Tracked Accounts", .vietnamese: "Tài khoản theo dõi", .chinese: "跟踪的账户", .french: "Comptes suivis"],
        "dashboard.connected": [.english: "connected", .vietnamese: "đã kết nối", .chinese: "已连接", .french: "connecté"],
        "dashboard.lowestQuota": [.english: "Lowest Quota", .vietnamese: "Quota thấp nhất", .chinese: "最低配额", .french: "Quota le plus bas"],
        "dashboard.remaining": [.english: "remaining", .vietnamese: "còn lại", .chinese: "剩余", .french: "restant"],
        "dashboard.lastRefresh": [.english: "Last Refresh", .vietnamese: "Cập nhật lần cuối", .chinese: "上次刷新", .french: "Dernière actualisation"],
        "dashboard.updated": [.english: "updated", .vietnamese: "đã cập nhật", .chinese: "已更新", .french: "mis à jour"],
        "dashboard.noQuotaData": [.english: "No quota data yet", .vietnamese: "Chưa có dữ liệu quota", .chinese: "暂无配额数据", .french: "Pas encore de données de quota"],
        "dashboard.quotaOverview": [.english: "Quota Overview", .vietnamese: "Tổng quan Quota", .chinese: "配额概览", .french: "Aperçu des quotas"],
        "dashboard.noAccountsTracked": [.english: "No accounts tracked", .vietnamese: "Chưa theo dõi tài khoản nào", .chinese: "未跟踪账户", .french: "Aucun compte suivi"],
        "dashboard.addAccountsHint": [.english: "Add provider accounts to start tracking quotas", .vietnamese: "Thêm tài khoản nhà cung cấp để bắt đầu theo dõi quota", .chinese: "添加提供商账户以开始跟踪配额", .french: "Ajoutez des comptes fournisseur pour commencer à suivre les quotas"],
        
        // Providers - Quota-Only Mode
        "providers.noAccountsFound": [.english: "No accounts found", .vietnamese: "Không tìm thấy tài khoản", .chinese: "未找到账户", .french: "Aucun compte trouvé"],
        "providers.quotaOnlyHint": [.english: "Auth files will be detected from ~/.cli-proxy-api and native CLI locations", .vietnamese: "File xác thực sẽ được phát hiện từ ~/.cli-proxy-api và các vị trí CLI gốc", .chinese: "将从 ~/.cli-proxy-api 和本地 CLI 位置检测认证文件", .french: "Les fichiers d'authentification seront détectés depuis ~/.cli-proxy-api et les emplacements CLI natifs"],
        "providers.trackedAccounts": [.english: "Tracked Accounts", .vietnamese: "Tài khoản theo dõi", .chinese: "跟踪的账户", .french: "Comptes suivis"],
        
        // Empty States - New
        "empty.noQuotaData": [.english: "No Quota Data", .vietnamese: "Chưa có dữ liệu Quota", .chinese: "无配额数据", .french: "Aucune donnée de quota"],
        "empty.refreshToLoad": [.english: "Refresh to load quota information", .vietnamese: "Làm mới để tải thông tin quota", .chinese: "刷新以加载配额信息", .french: "Actualisez pour charger les informations de quota"],
        
        // Menu Bar - Quota Mode
        "menubar.quotaMode": [.english: "Quota Monitor", .vietnamese: "Theo dõi Quota", .chinese: "配额监控", .french: "Moniteur de quota"],
        "menubar.trackedAccounts": [.english: "Tracked Accounts", .vietnamese: "Tài khoản theo dõi", .chinese: "跟踪的账户", .french: "Comptes suivis"],
        "menubar.noAccountsFound": [.english: "No accounts found", .vietnamese: "Không tìm thấy tài khoản", .chinese: "未找到账户", .french: "Aucun compte trouvé"],
        "menubar.noData": [.english: "No quota data available", .vietnamese: "Chưa có dữ liệu quota", .chinese: "无可用配额数据", .french: "Aucune donnée de quota disponible"],
        
        // Menu Bar - Tooltips
        "menubar.tooltip.openApp": [.english: "Open main window (⌘O)", .vietnamese: "Mở cửa sổ chính (⌘O)", .chinese: "打开主窗口 (⌘O)", .french: "Ouvrir la fenêtre principale (⌘O)"],
        "menubar.tooltip.quit": [.english: "Quit Quotio (⌘Q)", .vietnamese: "Thoát Quotio (⌘Q)", .chinese: "退出 Quotio (⌘Q)", .french: "Quitter Quotio (⌘Q)"],
        
        // Actions - New
        "action.refreshQuota": [.english: "Refresh Quota", .vietnamese: "Làm mới Quota", .chinese: "刷新配额", .french: "Actualiser le quota"],
        "action.switch": [.english: "Switch", .vietnamese: "Chuyển", .chinese: "切换", .french: "Changer"],
        "action.update": [.english: "Update", .vietnamese: "Cập nhật", .chinese: "更新", .french: "Mettre à jour"],
        
        // Status - New
        "status.refreshing": [.english: "Refreshing...", .vietnamese: "Đang làm mới...", .chinese: "刷新中...", .french: "Actualisation..."],
        "status.notRefreshed": [.english: "Not refreshed", .vietnamese: "Chưa làm mới", .chinese: "未刷新", .french: "Non actualisé"],
        
        // Settings - App Mode
        "settings.appMode": [.english: "App Mode", .vietnamese: "Chế độ ứng dụng", .chinese: "应用模式", .french: "Mode de l'application"],
        "settings.appMode.quotaOnlyNote": [.english: "Proxy server is disabled in Quota Monitor mode", .vietnamese: "Máy chủ proxy bị tắt trong chế độ Theo dõi Quota", .chinese: "配额监控模式下代理服务器已禁用", .french: "Le serveur proxy est désactivé en mode Moniteur de quota"],
        "settings.appMode.switchConfirmTitle": [.english: "Switch to Quota Monitor Mode?", .vietnamese: "Chuyển sang chế độ Theo dõi Quota?", .chinese: "切换到配额监控模式？", .french: "Passer en mode Moniteur de quota ?"],
        "settings.appMode.switchConfirmMessage": [.english: "This will stop the proxy server if running. You can switch back anytime.", .vietnamese: "Điều này sẽ dừng máy chủ proxy nếu đang chạy. Bạn có thể chuyển lại bất cứ lúc nào.", .chinese: "如果正在运行，这将停止代理服务器。您可以随时切换回来。", .french: "Cela arrêtera le serveur proxy s'il est en cours d'exécution. Vous pouvez revenir en arrière à tout moment."],
        
        // Appearance Mode
        "settings.appearance.title": [.english: "Appearance", .vietnamese: "Giao diện", .chinese: "外观", .french: "Apparence"],
        "settings.appearance.mode": [.english: "Theme", .vietnamese: "Chủ đề", .chinese: "主题", .french: "Thème"],
        "settings.appearance.system": [.english: "System", .vietnamese: "Hệ thống", .chinese: "系统", .french: "Système"],
        "settings.appearance.light": [.english: "Light", .vietnamese: "Sáng", .chinese: "浅色", .french: "Clair"],
        "settings.appearance.dark": [.english: "Dark", .vietnamese: "Tối", .chinese: "深色", .french: "Sombre"],
        "settings.appearance.help": [.english: "Choose how the app looks. System will automatically match your Mac's appearance.", .vietnamese: "Chọn giao diện cho ứng dụng. Hệ thống sẽ tự động theo giao diện của Mac.", .chinese: "选择应用的外观。系统将自动匹配您 Mac 的外观。", .french: "Choisissez l'apparence de l'application. Système correspondra automatiquement à l'apparence de votre Mac."],
        
        // IDE Scan (Issue #29 - Privacy)
        "ideScan.title": [.english: "Scan for Installed IDEs", .vietnamese: "Quét IDE đã cài đặt", .chinese: "扫描已安装的 IDE", .french: "Rechercher les IDE installés"],
        "ideScan.subtitle": [.english: "Detect IDEs and CLI tools to track their quotas", .vietnamese: "Phát hiện IDE và công cụ CLI để theo dõi quota", .chinese: "检测 IDE 和 CLI 工具以跟踪其配额", .french: "Détecter les IDE et les outils CLI pour suivre leurs quotas"],
        "ideScan.privacyNotice": [.english: "Privacy Notice", .vietnamese: "Thông báo bảo mật", .chinese: "隐私通知", .french: "Avis de confidentialité"],
        "ideScan.privacyDescription": [.english: "This will access files from other applications to detect installed IDEs and their authentication status. No data is sent externally.", .vietnamese: "Thao tác này sẽ truy cập file từ các ứng dụng khác để phát hiện IDE đã cài đặt và trạng thái xác thực. Không có dữ liệu nào được gửi ra ngoài.", .chinese: "这将访问其他应用程序的文件以检测已安装的 IDE 及其认证状态。不会对外发送任何数据。", .french: "Cela accédera aux fichiers d'autres applications pour détecter les IDE installés et leur état d'authentification. Aucune donnée n'est envoyée à l'extérieur."],
        "ideScan.selectSources": [.english: "Select Data Sources", .vietnamese: "Chọn nguồn dữ liệu", .chinese: "选择数据源", .french: "Sélectionner les sources de données"],
        "ideScan.cursor.detail": [.english: "Reads ~/Library/Application Support/Cursor/", .vietnamese: "Đọc ~/Library/Application Support/Cursor/", .chinese: "读取 ~/Library/Application Support/Cursor/", .french: "Lit ~/Library/Application Support/Cursor/"],
        "ideScan.trae.detail": [.english: "Reads ~/Library/Application Support/Trae/", .vietnamese: "Đọc ~/Library/Application Support/Trae/", .chinese: "读取 ~/Library/Application Support/Trae/", .french: "Lit ~/Library/Application Support/Trae/"],
        "ideScan.cliTools": [.english: "CLI Tools (claude, codex, gemini...)", .vietnamese: "Công cụ CLI (claude, codex, gemini...)", .chinese: "CLI 工具（claude、codex、gemini...）", .french: "Outils CLI (claude, codex, gemini...)"],
        "ideScan.cliTools.detail": [.english: "Uses 'which' command to find installed tools", .vietnamese: "Sử dụng lệnh 'which' để tìm công cụ đã cài", .chinese: "使用 'which' 命令查找已安装的工具", .french: "Utilise la commande 'which' pour trouver les outils installés"],
        "ideScan.scanNow": [.english: "Scan Now", .vietnamese: "Quét ngay", .chinese: "立即扫描", .french: "Analyser maintenant"],
        "ideScan.scanning": [.english: "Scanning...", .vietnamese: "Đang quét...", .chinese: "扫描中...", .french: "Analyse en cours..."],
        "ideScan.complete": [.english: "Scan Complete", .vietnamese: "Quét hoàn tất", .chinese: "扫描完成", .french: "Analyse terminée"],
        "ideScan.notFound": [.english: "Not found", .vietnamese: "Không tìm thấy", .chinese: "未找到", .french: "Non trouvé"],
        "ideScan.error": [.english: "Scan Error", .vietnamese: "Lỗi quét", .chinese: "扫描错误", .french: "Erreur d'analyse"],
        "ideScan.buttonSubtitle": [.english: "Detect Cursor, Trae, and CLI tools", .vietnamese: "Phát hiện Cursor, Trae và công cụ CLI", .chinese: "检测 Cursor、Trae 和 CLI 工具", .french: "Détecter Cursor, Trae et les outils CLI"],
        "ideScan.sectionTitle": [.english: "Detect IDEs", .vietnamese: "Phát hiện IDE", .chinese: "检测 IDE", .french: "Détecter les IDE"],
        "ideScan.sectionFooter": [.english: "Scan for installed IDEs and CLI tools to track their quotas", .vietnamese: "Quét IDE và công cụ CLI đã cài đặt để theo dõi quota", .chinese: "扫描已安装的 IDE 和 CLI 工具以跟踪其配额", .french: "Rechercher les IDE et outils CLI installés pour suivre leurs quotas"],
        "ideScan.scanExisting": [.english: "Scan for Existing IDEs", .vietnamese: "Quét IDE đã cài đặt", .chinese: "扫描已安装的 IDE", .french: "Rechercher les IDE existants"],
        
        // Upgrade Notifications
        "notification.upgrade.success.title": [.english: "Proxy Upgraded", .vietnamese: "Đã nâng cấp Proxy", .chinese: "代理已升级", .french: "Proxy mis à jour"],
        "notification.upgrade.success.body": [.english: "CLIProxyAPI has been upgraded to version %@", .vietnamese: "CLIProxyAPI đã được nâng cấp lên phiên bản %@", .chinese: "CLIProxyAPI 已升级到版本 %@", .french: "CLIProxyAPI a été mis à jour vers la version %@"],
        "notification.upgrade.failed.title": [.english: "Proxy Upgrade Failed", .vietnamese: "Nâng cấp Proxy thất bại", .chinese: "代理升级失败", .french: "Échec de la mise à jour du proxy"],
        "notification.upgrade.failed.body": [.english: "Failed to upgrade to version %@: %@", .vietnamese: "Không thể nâng cấp lên phiên bản %@: %@", .chinese: "无法升级到版本 %@：%@", .french: "Échec de la mise à jour vers la version %@ : %@"],
        "notification.rollback.title": [.english: "Proxy Rollback", .vietnamese: "Khôi phục Proxy", .chinese: "代理回滚", .french: "Restauration du proxy"],
        "notification.rollback.body": [.english: "Rolled back to version %@ due to upgrade failure", .vietnamese: "Đã khôi phục về phiên bản %@ do nâng cấp thất bại", .chinese: "由于升级失败，已回滚到版本 %@", .french: "Restauré à la version %@ suite à l'échec de la mise à jour"],
        
        // Version Manager - Delete Warning
        "settings.proxyUpdate.deleteWarning.title": [.english: "Old Versions Will Be Deleted", .vietnamese: "Phiên bản cũ sẽ bị xóa", .chinese: "旧版本将被删除", .french: "Les anciennes versions seront supprimées"],
        "settings.proxyUpdate.deleteWarning.message": [.english: "Installing this version will delete the following old versions to keep only %d most recent: %@", .vietnamese: "Cài đặt phiên bản này sẽ xóa các phiên bản cũ sau để chỉ giữ lại %d phiên bản gần nhất: %@", .chinese: "安装此版本将删除以下旧版本，仅保留最近的 %d 个：%@", .french: "L'installation de cette version supprimera les anciennes versions suivantes pour ne garder que les %d plus récentes : %@"],
        "settings.proxyUpdate.deleteWarning.confirm": [.english: "Install Anyway", .vietnamese: "Vẫn cài đặt", .chinese: "仍然安装", .french: "Installer quand même"],
        
        // Privacy Settings
        "settings.privacy": [.english: "Privacy", .vietnamese: "Riêng tư", .chinese: "隐私", .french: "Confidentialité"],
        "settings.privacy.hideSensitive": [.english: "Hide Sensitive Information", .vietnamese: "Ẩn thông tin nhạy cảm", .chinese: "隐藏敏感信息", .french: "Masquer les informations sensibles"],
        "settings.privacy.hideSensitiveHelp": [.english: "Masks emails and account names with ● characters across the app", .vietnamese: "Che email và tên tài khoản bằng ký tự ● trong toàn bộ ứng dụng", .chinese: "在应用中使用 ● 字符隐藏邮箱和账户名称", .french: "Masque les e-mails et noms de compte avec des caractères ● dans toute l'application"],
        
        // Upstream Proxy Settings
        "settings.upstreamProxy": [.english: "Upstream Proxy", .vietnamese: "Proxy thượng nguồn", .chinese: "上游代理", .french: "Proxy amont"],
        "settings.upstreamProxy.placeholder": [.english: "socks5://host:port or http://host:port", .vietnamese: "socks5://host:port hoặc http://host:port", .chinese: "socks5://host:port 或 http://host:port", .french: "socks5://host:port ou http://host:port"],
        "settings.upstreamProxy.help": [.english: "Route all proxy traffic through an upstream SOCKS5/HTTP/HTTPS proxy server", .vietnamese: "Định tuyến toàn bộ traffic proxy qua máy chủ proxy SOCKS5/HTTP/HTTPS thượng nguồn", .chinese: "将所有代理流量通过上游 SOCKS5/HTTP/HTTPS 代理服务器路由", .french: "Acheminer tout le trafic proxy via un serveur proxy SOCKS5/HTTP/HTTPS amont"],
        
        // Proxy URL Validation Errors
        "settings.proxy.error.invalidScheme": [.english: "Invalid scheme. Use socks5://, http://, or https://", .vietnamese: "Scheme không hợp lệ. Sử dụng socks5://, http://, hoặc https://", .chinese: "无效的协议。使用 socks5://、http:// 或 https://", .french: "Schéma invalide. Utilisez socks5://, http:// ou https://"],
        "settings.proxy.error.invalidURL": [.english: "Invalid URL format", .vietnamese: "Định dạng URL không hợp lệ", .chinese: "无效的 URL 格式", .french: "Format d'URL invalide"],
        "settings.proxy.error.missingHost": [.english: "Missing host", .vietnamese: "Thiếu host", .chinese: "缺少主机", .french: "Hôte manquant"],
        "settings.proxy.error.missingPort": [.english: "Port is required for socks5", .vietnamese: "Port là bắt buộc cho socks5", .chinese: "socks5 需要端口号", .french: "Le port est requis pour socks5"],
        "settings.proxy.error.invalidPort": [.english: "Invalid port number", .vietnamese: "Số port không hợp lệ", .chinese: "无效的端口号", .french: "Numéro de port invalide"],
        
        // Custom Providers
        "customProviders.title": [.english: "Custom Providers", .vietnamese: "Nhà cung cấp tùy chỉnh", .chinese: "自定义提供商", .french: "Fournisseurs personnalisés"],
        "customProviders.add": [.english: "Add Custom Provider", .vietnamese: "Thêm nhà cung cấp tùy chỉnh", .chinese: "添加自定义提供商", .french: "Ajouter un fournisseur personnalisé"],
        "customProviders.edit": [.english: "Edit Custom Provider", .vietnamese: "Sửa nhà cung cấp tùy chỉnh", .chinese: "编辑自定义提供商", .french: "Modifier le fournisseur personnalisé"],
        "customProviders.description": [.english: "OpenAI-compatible, Claude, Gemini, or Codex APIs", .vietnamese: "API tương thích OpenAI, Claude, Gemini hoặc Codex", .chinese: "OpenAI 兼容、Claude、Gemini 或 Codex API", .french: "API compatibles OpenAI, Claude, Gemini ou Codex"],
        "customProviders.footer": [.english: "Custom providers let you connect OpenRouter, Ollama, LM Studio, or any compatible API endpoint.", .vietnamese: "Nhà cung cấp tùy chỉnh cho phép bạn kết nối OpenRouter, Ollama, LM Studio, hoặc bất kỳ API endpoint tương thích nào.", .chinese: "自定义提供商允许您连接 OpenRouter、Ollama、LM Studio 或任何兼容的 API 端点。", .french: "Les fournisseurs personnalisés vous permettent de connecter OpenRouter, Ollama, LM Studio ou tout point d'accès API compatible."],
        "customProviders.syncConfig": [.english: "Sync to config", .vietnamese: "Đồng bộ cấu hình", .chinese: "同步配置", .french: "Synchroniser la configuration"],
        "customProviders.basicInfo": [.english: "Basic Information", .vietnamese: "Thông tin cơ bản", .chinese: "基本信息", .french: "Informations de base"],
        "customProviders.providerName": [.english: "Provider Name", .vietnamese: "Tên nhà cung cấp", .chinese: "提供商名称", .french: "Nom du fournisseur"],
        "customProviders.providerType": [.english: "Provider Type", .vietnamese: "Loại nhà cung cấp", .chinese: "提供商类型", .french: "Type de fournisseur"],
        "customProviders.baseURL": [.english: "Base URL", .vietnamese: "URL cơ sở", .chinese: "基础 URL", .french: "URL de base"],
        "customProviders.apiKeys": [.english: "API Keys", .vietnamese: "Khóa API", .chinese: "API 密钥", .french: "Clés API"],
        "customProviders.addKey": [.english: "Add Key", .vietnamese: "Thêm khóa", .chinese: "添加密钥", .french: "Ajouter une clé"],
        "customProviders.proxyURL": [.english: "Proxy URL (optional)", .vietnamese: "URL Proxy (tùy chọn)", .chinese: "代理 URL（可选）", .french: "URL du proxy (optionnel)"],
        "customProviders.modelMapping": [.english: "Model Mapping", .vietnamese: "Ánh xạ mô hình", .chinese: "模型映射", .french: "Mappage de modèles"],
        "customProviders.modelMappingDesc": [.english: "Map upstream model names to local aliases", .vietnamese: "Ánh xạ tên mô hình upstream sang bí danh local", .chinese: "将上游模型名称映射到本地别名", .french: "Mapper les noms de modèles amont vers des alias locaux"],
        "customProviders.addMapping": [.english: "Add Mapping", .vietnamese: "Thêm ánh xạ", .chinese: "添加映射", .french: "Ajouter un mappage"],
        "customProviders.noMappings": [.english: "No model mappings configured. Models will use their original names.", .vietnamese: "Chưa cấu hình ánh xạ mô hình. Các mô hình sẽ sử dụng tên gốc.", .chinese: "未配置模型映射。模型将使用其原始名称。", .french: "Aucun mappage de modèle configuré. Les modèles utiliseront leurs noms d'origine."],
        "customProviders.upstreamModel": [.english: "Upstream Model", .vietnamese: "Mô hình upstream", .chinese: "上游模型", .french: "Modèle amont"],
        "customProviders.localAlias": [.english: "Local Alias", .vietnamese: "Bí danh local", .chinese: "本地别名", .french: "Alias local"],
        "customProviders.customHeaders": [.english: "Custom Headers", .vietnamese: "Headers tùy chỉnh", .chinese: "自定义标头", .french: "En-têtes personnalisés"],
        "customProviders.customHeadersDesc": [.english: "Add custom HTTP headers for API requests", .vietnamese: "Thêm HTTP headers tùy chỉnh cho các yêu cầu API", .chinese: "为 API 请求添加自定义 HTTP 标头", .french: "Ajouter des en-têtes HTTP personnalisés pour les requêtes API"],
        "customProviders.addHeader": [.english: "Add Header", .vietnamese: "Thêm header", .chinese: "添加标头", .french: "Ajouter un en-tête"],
        "customProviders.noHeaders": [.english: "No custom headers configured.", .vietnamese: "Chưa cấu hình headers tùy chỉnh.", .chinese: "未配置自定义标头。", .french: "Aucun en-tête personnalisé configuré."],
        "customProviders.headerName": [.english: "Header Name", .vietnamese: "Tên header", .chinese: "标头名称", .french: "Nom de l'en-tête"],
        "customProviders.headerValue": [.english: "Header Value", .vietnamese: "Giá trị header", .chinese: "标头值", .french: "Valeur de l'en-tête"],
        "customProviders.enableProvider": [.english: "Enable this provider", .vietnamese: "Bật nhà cung cấp này", .chinese: "启用此提供商", .french: "Activer ce fournisseur"],
        "customProviders.disabledNote": [.english: "Disabled providers are not included in the proxy configuration", .vietnamese: "Nhà cung cấp bị tắt sẽ không được bao gồm trong cấu hình proxy", .chinese: "禁用的提供商不会包含在代理配置中", .french: "Les fournisseurs désactivés ne sont pas inclus dans la configuration du proxy"],
        "customProviders.saveChanges": [.english: "Save Changes", .vietnamese: "Lưu thay đổi", .chinese: "保存更改", .french: "Enregistrer les modifications"],
        "customProviders.addProvider": [.english: "Add Provider", .vietnamese: "Thêm nhà cung cấp", .chinese: "添加提供商", .french: "Ajouter le fournisseur"],
        "customProviders.validationError": [.english: "Validation Error", .vietnamese: "Lỗi xác thực", .chinese: "验证错误", .french: "Erreur de validation"],
        "customProviders.disabled": [.english: "Disabled", .vietnamese: "Đã tắt", .chinese: "已禁用", .french: "Désactivé"],
        "customProviders.keys": [.english: "keys", .vietnamese: "khóa", .chinese: "密钥", .french: "clés"],
        "customProviders.key": [.english: "key", .vietnamese: "khóa", .chinese: "密钥", .french: "clé"],
        "customProviders.enable": [.english: "Enable", .vietnamese: "Bật", .chinese: "启用", .french: "Activer"],
        "customProviders.disable": [.english: "Disable", .vietnamese: "Tắt", .chinese: "禁用", .french: "Désactiver"],
        "customProviders.deleteConfirm": [.english: "Delete Custom Provider", .vietnamese: "Xóa nhà cung cấp tùy chỉnh", .chinese: "删除自定义提供商", .french: "Supprimer le fournisseur personnalisé"],
        "customProviders.deleteMessage": [.english: "Are you sure you want to delete this provider? This action cannot be undone.", .vietnamese: "Bạn có chắc muốn xóa nhà cung cấp này? Hành động này không thể hoàn tác.", .chinese: "您确定要删除此提供商吗？此操作无法撤消。", .french: "Êtes-vous sûr de vouloir supprimer ce fournisseur ? Cette action ne peut pas être annulée."],
        
        // Custom Provider Types
        "customProviders.type.openai": [.english: "OpenAI Compatible", .vietnamese: "Tương thích OpenAI", .chinese: "OpenAI 兼容", .french: "Compatible OpenAI"],
        "customProviders.type.openai.desc": [.english: "OpenRouter, Ollama, LM Studio, vLLM, or any OpenAI-compatible API", .vietnamese: "OpenRouter, Ollama, LM Studio, vLLM, hoặc bất kỳ API tương thích OpenAI nào", .chinese: "OpenRouter、Ollama、LM Studio、vLLM 或任何 OpenAI 兼容 API", .french: "OpenRouter, Ollama, LM Studio, vLLM ou toute API compatible OpenAI"],
        "customProviders.type.claude": [.english: "Claude Compatible", .vietnamese: "Tương thích Claude", .chinese: "Claude 兼容", .french: "Compatible Claude"],
        "customProviders.type.claude.desc": [.english: "Anthropic API or Claude-compatible providers", .vietnamese: "API Anthropic hoặc các nhà cung cấp tương thích Claude", .chinese: "Anthropic API 或 Claude 兼容提供商", .french: "API Anthropic ou fournisseurs compatibles Claude"],
        "customProviders.type.gemini": [.english: "Gemini Compatible", .vietnamese: "Tương thích Gemini", .chinese: "Gemini 兼容", .french: "Compatible Gemini"],
        "customProviders.type.gemini.desc": [.english: "Google Gemini API or Gemini-compatible providers", .vietnamese: "API Google Gemini hoặc các nhà cung cấp tương thích Gemini", .chinese: "Google Gemini API 或 Gemini 兼容提供商", .french: "API Google Gemini ou fournisseurs compatibles Gemini"],
        "customProviders.type.codex": [.english: "Codex Compatible", .vietnamese: "Tương thích Codex", .chinese: "Codex 兼容", .french: "Compatible Codex"],
        "customProviders.type.codex.desc": [.english: "Custom Codex-compatible endpoints", .vietnamese: "Các endpoint tương thích Codex tùy chỉnh", .chinese: "自定义 Codex 兼容端点", .french: "Points d'accès personnalisés compatibles Codex"],
        
        // Thinking Budget
        "customProviders.thinkingBudget": [.english: "Thinking Budget", .vietnamese: "Ngân sách suy nghĩ", .chinese: "思考预算", .french: "Budget de réflexion"],
        "customProviders.thinkingBudgetDesc": [.english: "Append (value) to model names for reasoning control", .vietnamese: "Thêm (value) vào tên mô hình để kiểm soát suy luận", .chinese: "在模型名称后添加 (value) 以控制推理", .french: "Ajouter (value) aux noms de modèles pour le contrôle du raisonnement"],
        "customProviders.thinkingBudgetHint": [.english: "e.g., claude-sonnet-4(16000) or gemini-2.5-flash(max)", .vietnamese: "ví dụ: claude-sonnet-4(16000) hoặc gemini-2.5-flash(max)", .chinese: "例如：claude-sonnet-4(16000) 或 gemini-2.5-flash(max)", .french: "ex. claude-sonnet-4(16000) ou gemini-2.5-flash(max)"],
        
        // Antigravity Account Switching
        "antigravity.switch.title": [.english: "Switch Account", .vietnamese: "Chuyển tài khoản", .chinese: "切换账户", .french: "Changer de compte"],
        "antigravity.switch.confirm": [.english: "Switch to this account in Antigravity IDE?", .vietnamese: "Chuyển sang tài khoản này trong Antigravity IDE?", .chinese: "切换到 Antigravity IDE 中的此账户？", .french: "Passer à ce compte dans Antigravity IDE ?"],
        "antigravity.switch.ideRunning": [.english: "Antigravity IDE is running and will be restarted.", .vietnamese: "Antigravity IDE đang chạy và sẽ được khởi động lại.", .chinese: "Antigravity IDE 正在运行，将被重启。", .french: "Antigravity IDE est en cours d'exécution et sera redémarré."],
        "antigravity.switch.progress.closing": [.english: "Closing Antigravity IDE...", .vietnamese: "Đang đóng Antigravity IDE...", .chinese: "正在关闭 Antigravity IDE...", .french: "Fermeture d'Antigravity IDE..."],
        "antigravity.switch.progress.backup": [.english: "Creating backup...", .vietnamese: "Đang tạo bản sao lưu...", .chinese: "正在创建备份...", .french: "Création de la sauvegarde..."],
        "antigravity.switch.progress.injecting": [.english: "Switching account...", .vietnamese: "Đang chuyển tài khoản...", .chinese: "正在切换账户...", .french: "Changement de compte..."],
        "antigravity.switch.progress.restarting": [.english: "Restarting Antigravity IDE...", .vietnamese: "Đang khởi động lại Antigravity IDE...", .chinese: "正在重启 Antigravity IDE...", .french: "Redémarrage d'Antigravity IDE..."],
        "antigravity.switch.success": [.english: "Account switched successfully", .vietnamese: "Đã chuyển tài khoản thành công", .chinese: "账户切换成功", .french: "Compte changé avec succès"],
        "antigravity.switch.failed": [.english: "Failed to switch account", .vietnamese: "Chuyển tài khoản thất bại", .chinese: "账户切换失败", .french: "Échec du changement de compte"],
        "antigravity.active": [.english: "Active in IDE", .vietnamese: "Đang dùng trong IDE", .chinese: "在 IDE 中激活", .french: "Actif dans l'IDE"],
        "antigravity.useInIDE": [.english: "Use in IDE", .vietnamese: "Dùng trong IDE", .chinese: "在 IDE 中使用", .french: "Utiliser dans l'IDE"],
        "action.retry": [.english: "Retry", .vietnamese: "Thử lại", .chinese: "重试", .french: "Réessayer"],
        "action.ok": [.english: "OK", .vietnamese: "OK", .chinese: "确定", .french: "OK"],
        
        // Quota Details
        "quota.details": [.english: "Details", .vietnamese: "Chi tiết", .chinese: "详情", .french: "Détails"],
        "quota.allModels": [.english: "All Models", .vietnamese: "Tất cả model", .chinese: "所有模型", .french: "Tous les modèles"],
        "quota.limitReached": [.english: "Limit Reached", .vietnamese: "Đã đạt giới hạn", .chinese: "已达上限", .french: "Limite atteinte"],
        "quota.usage": [.english: "Usage", .vietnamese: "Sử dụng", .chinese: "使用量", .french: "Utilisation"],
        "quota.used": [.english: "used", .vietnamese: "đã dùng", .chinese: "已用", .french: "utilisé"],
        
        // Settings
        "settings.appDescription": [.english: "CLIProxyAPI GUI Wrapper", .vietnamese: "Giao diện quản lý CLIProxyAPI", .chinese: "CLIProxyAPI 图形界面", .french: "Interface graphique CLIProxyAPI"],
        "settings.links": [.english: "Links", .vietnamese: "Liên kết", .chinese: "链接", .french: "Liens"],
        "settings.versionCopied": [.english: "Version copied to clipboard", .vietnamese: "Đã sao chép phiên bản", .chinese: "版本已复制到剪贴板", .french: "Version copiée dans le presse-papiers"],
        
        // Agent Config
        "agent.generatingPreview": [.english: "Generating preview...", .vietnamese: "Đang tạo xem trước...", .chinese: "正在生成预览...", .french: "Génération de l'aperçu..."],
        
        // Custom Provider
        "customProviders.apiKeyNumber": [.english: "API Key #%@", .vietnamese: "API Key #%@", .chinese: "API 密钥 #%@", .french: "Clé API #%@"],
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
