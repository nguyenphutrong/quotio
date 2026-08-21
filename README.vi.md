# Quotio

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="screenshots/menu_bar_dark.png" />
    <source media="(prefers-color-scheme: light)" srcset="screenshots/menu_bar.png" />
    <img alt="Quotio Banner" src="screenshots/menu_bar.png" width="720" />
  </picture>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey.svg?style=flat" alt="Platform macOS" />
  <img src="https://img.shields.io/badge/language-Swift-orange.svg?style=flat" alt="Language Swift" />
  <img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat" alt="License MIT" />
  <a href="https://discord.gg/dFzeZ7qS"><img src="https://img.shields.io/badge/Discord-Tham%20gia-5865F2.svg?style=flat&logo=discord&logoColor=white" alt="Discord" /></a>
  <a href="README.md"><img src="https://img.shields.io/badge/lang-English-blue.svg?style=flat" alt="English" /></a>
  <a href="README.zh.md"><img src="https://img.shields.io/badge/lang-zh--CN-green.svg?style=flat" alt="Chinese" /></a>
  <a href="README.fr.md"><img src="https://img.shields.io/badge/lang-Français-blue.svg?style=flat" alt="French" /></a>
</p>

<p align="center">
  <a href="https://trendshift.io/repositories/16304?utm_source=repository-badge&amp;utm_medium=badge&amp;utm_campaign=badge-repository-16304" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/repositories/16304" alt="nguyenphutrong%2Fquotio | Trendshift" width="250" height="55"/></a>
  <a href="https://trendshift.io/repositories/16304?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-16304" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/16304/daily?language=Swift" alt="nguyenphutrong%2Fquotio | Trendshift" width="250" height="55"/></a>
  <a href="https://trendshift.io/repositories/16304?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-16304" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/16304/daily" alt="nguyenphutrong%2Fquotio | Trendshift" width="250" height="55"/></a>
  <a href="https://trendshift.io/repositories/16304?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-16304" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/16304/weekly?language=Swift" alt="nguyenphutrong%2Fquotio | Trendshift" width="250" height="55"/></a>
  <a href="https://trendshift.io/repositories/16304?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-16304" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/16304/weekly" alt="nguyenphutrong%2Fquotio | Trendshift" width="250" height="55"/></a>
  <a href="https://trendshift.io/repositories/16304?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-16304" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/16304/monthly?language=Swift" alt="nguyenphutrong%2Fquotio | Trendshift" width="250" height="55"/></a>
</p>

<p align="center">
  <strong>Trung tâm điều khiển cho các trợ lý lập trình AI trên macOS.</strong>
</p>

Quotio là ứng dụng macOS để quản lý **CLIProxyAPI** - máy chủ proxy cục bộ cung cấp sức mạnh cho các agent lập trình AI. Quotio giúp bạn quản lý nhiều tài khoản AI, theo dõi hạn mức sử dụng và cấu hình các công cụ CLI tại một nơi.

## ✨ Tính năng

- **🔌 Hỗ trợ Đa nhà cung cấp**: Kết nối tài khoản từ Claude, OpenAI Codex, Qwen, Vertex AI, iFlow, Antigravity, Kiro, Trae, và GitHub Copilot qua OAuth hoặc API key.
- **📊 Chế độ Quota độc lập**: Xem quota và tài khoản mà không cần chạy proxy server - hoàn hảo để kiểm tra nhanh.
- **🚀 Cấu hình Agent Một chạm**: Tự động phát hiện và cấu hình các công cụ như Claude Code, OpenCode.
- **📈 Dashboard Thời gian thực**: Giám sát lưu lượng, token sử dụng và tỷ lệ thành công.
- **📉 Quản lý Hạn mức**: Theo dõi quota từng tài khoản với chiến lược chuyển đổi tự động (Round Robin / Fill First).
- **🔑 Quản lý API Key**: Tạo và quản lý các khóa API cho proxy.
- **🖥️ Menu Bar**: Truy cập nhanh trạng thái, tổng quan quota và biểu tượng provider tùy chỉnh từ thanh menu.
- **🔔 Thông báo**: Cảnh báo khi hạn mức thấp, tài khoản đang nghỉ, hoặc lỗi dịch vụ.
- **🔄 Tự động Cập nhật**: Tích hợp Sparkle updater để cập nhật liền mạch.
- **🌍 Đa ngôn ngữ**: Hỗ trợ tiếng Anh, tiếng Việt và tiếng Trung giản thể.

## 🤖 Hệ sinh thái hỗ trợ

### Nhà cung cấp AI
| Provider | Phương thức xác thực |
|----------|----------------------|
| Anthropic Claude | OAuth |
| OpenAI Codex | OAuth |
| Qwen Code | OAuth |
| Vertex AI | Service Account JSON |
| iFlow | OAuth |
| Antigravity | OAuth |
| Kiro | OAuth |
| GitHub Copilot | OAuth |

### Theo dõi Quota IDE (Chỉ giám sát)
| IDE | Mô tả |
|-----|-------|
| Cursor | Tự động phát hiện khi cài đặt và đăng nhập |
| Trae | Tự động phát hiện khi cài đặt và đăng nhập |

> **Lưu ý**: Các IDE này chỉ dùng để theo dõi quota. Không thể sử dụng làm provider cho proxy.

### Agent tương thích
Quotio có thể tự động cấu hình các công cụ sau:
- Claude Code
- Codex CLI
- Amp CLI
- OpenCode
- Factory Droid

## 🚀 Cài đặt

### Yêu cầu
- macOS 14.0 (Sonoma) trở lên
- Kết nối internet để xác thực OAuth

### Homebrew (Khuyến nghị)
```bash
brew tap nguyenphutrong/tap
brew install --cask quotio
```

### Tải xuống
Tải file `.dmg` mới nhất từ trang [Releases](https://github.com/nguyenphutrong/quotio/releases).

Các bản phát hành chính thức được ký bằng Developer ID và được Apple công chứng, vì vậy không cần bỏ qua Gatekeeper.

### Build từ source

1. **Clone repo:**
   ```bash
   git clone https://github.com/nguyenphutrong/quotio.git
   cd Quotio
   ```

2. **Mở trong Xcode:**
   ```bash
   open Quotio.xcodeproj
   ```

3. **Build và chạy:**
   - Chọn scheme "Quotio"
   - Nhấn `Cmd + R`

> Ứng dụng sẽ tự động tải binary `CLIProxyAPI` trong lần chạy đầu tiên.

## 📖 Hướng dẫn sử dụng

### 1. Khởi động Server
Mở Quotio và nhấn **Start** trên dashboard để khởi động proxy server.

### 2. Kết nối Tài khoản
Vào tab **Providers** → Chọn provider → Xác thực qua OAuth hoặc import credentials.

### 3. Cấu hình Agent
Vào tab **Agents** → Chọn agent đã cài → Nhấn **Configure** → Chọn Automatic hoặc Manual.

### 4. Giám sát
- **Dashboard**: Tình trạng chung và lưu lượng
- **Quota**: Chi tiết sử dụng từng tài khoản
- **Logs**: Nhật ký request/response để debug

## ⚙️ Cài đặt

- **Port**: Đổi cổng proxy
- **Chiến lược định tuyến**: Round Robin hoặc Fill First
- **Auto-start**: Tự động khởi động proxy khi mở app
- **Notifications**: Bật/tắt thông báo

## 📸 Hình ảnh

### Bảng điều khiển
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/dashboard_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/dashboard.png" />
  <img alt="Bảng điều khiển" src="screenshots/dashboard.png" />
</picture>

### Nhà cung cấp
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/provider_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/provider.png" />
  <img alt="Nhà cung cấp" src="screenshots/provider.png" />
</picture>

### Cài đặt Agent
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/agent_setup_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/agent_setup.png" />
  <img alt="Cài đặt Agent" src="screenshots/agent_setup.png" />
</picture>

### Giám sát Hạn mức
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/quota_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/quota.png" />
  <img alt="Giám sát Hạn mức" src="screenshots/quota.png" />
</picture>

### API Keys
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/api_keys_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/api_keys.png" />
  <img alt="API Keys" src="screenshots/api_keys.png" />
</picture>

### Nhật ký
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/logs_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/logs.png" />
  <img alt="Nhật ký" src="screenshots/logs.png" />
</picture>

### Cài đặt
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/settings_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/settings.png" />
  <img alt="Cài đặt" src="screenshots/settings.png" />
</picture>

### Menu Bar
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/menu_bar_dark.png" />
  <source media="(prefers-color-scheme: light)" srcset="screenshots/menu_bar.png" />
  <img alt="Menu Bar" src="screenshots/menu_bar.png" width="720" />
</picture>

## 🤝 Đóng góp

1. Fork dự án
2. Tạo nhánh (`git checkout -b feature/tinh-nang-moi`)
3. Commit (`git commit -m 'Thêm tính năng mới'`)
4. Push (`git push origin feature/tinh-nang-moi`)
5. Mở Pull Request

## 💬 Cộng đồng

Tham gia cộng đồng Discord để được hỗ trợ, chia sẻ phản hồi và kết nối với người dùng khác:

<a href="https://discord.gg/dFzeZ7qS">
  <img src="https://img.shields.io/badge/Discord-Tham%20gia%20cộng%20đồng-5865F2.svg?style=for-the-badge&logo=discord&logoColor=white" alt="Tham gia Discord" />
</a>

## ⭐ Star History

<picture>
  <source
    media="(prefers-color-scheme: dark)"
    srcset="
      https://api.star-history.com/svg?repos=nguyenphutrong/quotio&type=Date&theme=dark
    "
  />
  <source
    media="(prefers-color-scheme: light)"
    srcset="
      https://api.star-history.com/svg?repos=nguyenphutrong/quotio&type=Date
    "
  />
  <img
    alt="Star History Chart"
    src="https://api.star-history.com/svg?repos=nguyenphutrong/quotio&type=Date"
  />
</picture>

## 📊 Hoạt động Repo

![Repo Activity](https://repobeats.axiom.co/api/embed/884e7349c8939bfd4bdba4bc582b6fdc0ecc21ee.svg "Repobeats analytics image")

## 💖 Người đóng góp

Chúng tôi không thể làm được điều này nếu thiếu các bạn. Cảm ơn! 🙏

<a href="https://github.com/nguyenphutrong/quotio/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=nguyenphutrong/quotio" />
</a>

## 📄 Giấy phép

MIT License. Xem file `LICENSE` để biết thêm.
