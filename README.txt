COMPANYX — ACT / SIM

MỞ PROJECT
Visual Studio 2022: CompanyX.ACT_SIM.sln (extension SSIS và Analysis Services Projects).
Web local: http://localhost:5087
Chạy web từ thư mục project: dotnet run --project Web/DssInventoryMvc --launch-profile http
Web đọc kết quả đã lưu trong SQL SIM; không gọi mô phỏng mới khi bấm xem phương án.

CẤU TRÚC
Database/, SSIS/, CompanyX.Split.Integration/: nguồn và ETL/điều phối.
Warehouse/: cấu trúc hai warehouse ACT/SIM.
MOLAP/: hai project cube ACT/SIM và XMLA.
DSS/, Tools/cube_pipeline/: Python mô phỏng/tối ưu và bộ nối SQL/SSAS.
Web/: giao diện ASP.NET Core MVC. PowerBI-XQ-0811.pbix: báo cáo nhóm.
KetQua/Demo_01/: bốn đầu vào đóng băng cần tái chạy; không chứa log kiểm thử.
RuntimeData/: cấu hình, dự báo và baseline-reference.zip cần tái chạy.
_local/: trạng thái, request, kết quả và log phát sinh; không đưa lên Git.

TECH STACK / MÁY CHẠY
Windows x64; SQL Server 2022 Developer; SSIS 2022; SSAS 2022 Multidimensional/MOLAP.
Python 3.11 x64 + Gurobi/CPLEX theo requirements DSS; .NET SDK 10 cho web; Power BI Desktop.
ODBC Driver 17, MSOLEDBSQL 18, MSOLAP, SQLCMD, DTExec 2022.
Máy đã dùng: i7-14700F, RAM 64 GiB; chưa xác định cấu hình tối thiểu.
SQL localhost; SSAS localhost\COMPANYXOLAP. Hai database/cube có hậu tố _20261107.

CHUYỂN MÁY
1. Tạo .venv và cài DSS/requirements-base.txt cùng requirements bộ giải phù hợp.
2. Chạy: .venv\Scripts\python.exe -B Tools/configure_checkout.py
   Công cụ cập nhật đường dẫn theo nơi clone, kiểm checksum và giải nén baseline trong project.
3. Giữ license Gurobi tại E:\Gurobi\gurobi.lic trên máy demo; máy khác cấu hình GRB_LICENSE_FILE. Không commit license.
4. Khôi phục nguồn CompanyX_Demo và hai warehouse bằng bộ dữ liệu bàn giao, rồi deploy/process hai cube.
   Git không chứa MDF/LDF/BAK hoặc kết quả SQL. Chỉ clone source chưa có dữ liệu demo trên SQL.
5. Trước lượt DSS mới, dùng gói 70 để chuẩn bị snapshot ACT qua MDX; gói 80 chạy DSS/process SIM;
   gói 00 chạy nguyên luồng. Request JSON đặt trong _local; đổi RequestID cho lượt mới.
Không sao chép .venv như bộ cài. Log/kiểm thử/bằng chứng cũ không cần để chạy và bị ignore.
