# DSS tồn kho CompanyX — ASP.NET Core MVC

Ứng dụng đọc kết quả mô phỏng đã lưu. Trang đơn lớn mặc định chọn ROP mất đơn tại hạn giao và chỉ liệt kê xe đạp thành phẩm tự sản xuất. Chọn xe và ngày để xem tồn cuối ngày liền trước. Khi có ca đơn lớn đã công bố, chọn đơn để mở các phương án và kế hoạch sản xuất.

## Mở bằng Visual Studio

Mở `DssInventoryMvc.sln` bằng Visual Studio có hỗ trợ .NET 10, sau đó chạy dự án `DssInventoryMvc`. Nếu Visual Studio báo không chép được `apphost.exe`, dừng phiên Debug cũ bằng **Shift+F5** rồi build lại; một tiến trình đang chạy có thể giữ khóa file `.exe`.

Có thể chạy bằng lệnh trong thư mục dự án:

```powershell
dotnet run --project DssInventoryMvc.csproj --urls http://localhost:5080
```

## SQL Server

`appsettings.Development.json` hiện dùng Windows Authentication tới `localhost`, database `CompanyX_DW_SIM_20261107`. Máy chạy web cần có quyền đọc các schema `bi`, `act_input`, `cxcontrol`, `cxactive`, `cxdetail`, `dss`. Khi chuyển sang máy chủ khác, sửa `ConnectionStrings:DssSqlServer` hoặc đặt biến môi trường `ConnectionStrings__DssSqlServer`. Không đưa mật khẩu vào mã nguồn.

Các nguồn chính: `bi.CompletedRuns`, `bi.RunSummary`, `bi.InventoryPerRunDay`, `bi.SimulationDaily`, `bi.SimulationMonthly`, `cxdetail.ProductionExecution`, `act_input.BusinessProduct` và các bảng liên kết baseline/candidate. Truy vấn tập trung tại `Data/DssSqlRepository.cs`.

## Các trang

- `/` — Dashboard: chỉ số của lượt đã lưu, hai biểu đồ tròn, xu hướng lost sales và hoạt động sản xuất.
- `/Orders` — Chọn xe đạp và đơn đã lưu. Hạn gốc của demo là hạn sớm nhất trong các phương án FULL khai báo cho cùng ca, xe và số lượng. Các hạn muộn hơn xuất hiện ở B. C dùng BASELINE của cùng ca và trạng thái khởi đầu. Nếu chưa có dữ liệu, thẻ chờ kết quả. Dữ liệu chi tiết đọc từ warehouse SIM.
- `/Operations` — Tổng quan vận hành: so sánh cặp ROP và Quetschlich Adapt, bộ lọc kỳ/quy tắc giao, biểu đồ tròn, bốn biểu đồ xu hướng và bảng tháng.

API đọc dữ liệu: `/api/database/status`, `/api/dss/bootstrap`, `/api/dss/run/{id}`, `/api/dss/snapshot?runId=51&productId=783&date=2013-09-16`, `/api/dss/compare?candidateRunId=51&months=18`.

Bootstrap và Chart.js đã nằm trong `wwwroot/lib`, nên phần giao diện không cần CDN. Các ảnh tham khảo ban đầu chỉ được dùng cho cấu trúc thông tin; những giá trị trên web lấy từ database hiện tại.
