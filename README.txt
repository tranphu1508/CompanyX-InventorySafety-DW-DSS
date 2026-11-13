COMPANYX — ACT / SIM

MỞ PROJECT
Visual Studio 2022: CompanyX.ACT_SIM.sln (extension SSIS và Analysis Services Projects).
Web local: http://localhost:5087
Chạy web từ thư mục project: dotnet run --project Web/DssInventoryMvc --launch-profile http
Web đọc phương án đã lưu trong SQL SIM. Khi bấm Tìm phương án mà chưa có kết quả, web lấy checkpoint ROP đã xác minh của ngày biết đơn, chạy A1/A2/C/B song song rồi công bố kết quả vào SIM để web đọc lại. Không dựng lại hay công bố lại lịch sử ROP cho từng ngày nhập mới. Tối đa 4 tiến trình, mỗi lần giải trần 12 luồng; các lần thử ngày của B và tìm độ trễ của A2 vẫn tuần tự. Nếu A2 mở rộng kỳ đánh giá, các nhánh liên quan được tính lại trước khi lưu đồng bộ. Web xử lý lần lượt từng đơn; log nằm trong _local/web-jobs/.

CHECKPOINT NỀN ROP
Chuẩn bị một lần cho hai lượt ROP đã có: .venv\Scripts\python.exe -B Tools/cube_pipeline/rop_checkpoints.py build
Mỗi ngày chụp sau nhận hàng và nhận diện đơn, trước giao hàng và quyết định sản xuất. Bộ tạo đối chiếu toàn bộ tồn kho/ngày và sự kiện với archive ROP đã xác minh; chỉ sau khi khớp mới công bố registry trong một giao dịch.
SIM chỉ thêm bảng cxsim.ROPDecisionCheckpoint gồm 6 cột: BaseRunKey, DecisionDate, InputIdentity, CheckpointPath, FileSHA256, ManifestSHA256. Không thêm planning run, inquiry hoặc ghi lại fact lịch sử. File nén và bằng chứng đối chiếu nằm trong _local/rop-checkpoints/; đường dẫn trong SQL là tương đối với checkout.
Khi ACT snapshot, baseline hay phiên bản thực thi thay đổi, bộ checkpoint cũ không được dùng lẫn. Có thể chạy lại lệnh chuẩn bị; nếu bộ hiện hành đã đủ ngày thì tái sử dụng. Luồng web có thể chuẩn bị cả bộ một lần nếu chưa có; không chuẩn bị riêng và nạp lại lịch sử theo từng đơn.
Dữ liệu checkpoint hỏng hoặc sai kịch bản/ngày bị từ chối. Không sửa file checkpoint đã đăng ký. Script cài bảng: Database/Setup/ROPDecisionCheckpoint.sql; refresh SIM SQL cũng cài bảng nếu chưa tồn tại.


CẤU TRÚC
Database/, SSIS/, CompanyX.Split.Integration/: nguồn và ETL/điều phối.
Warehouse/: cấu trúc hai warehouse ACT/SIM.
MOLAP/: project cube ACT và XMLA; SIM chỉ dùng SQL warehouse.
DSS/, Tools/cube_pipeline/: Python mô phỏng/tối ưu và bộ nối SQL/SSAS.
Web/: giao diện ASP.NET Core MVC. PowerBI_Nhom11.pbix: báo cáo nhóm.
KetQua/Demo_01/: bốn đầu vào đóng băng cần tái chạy; không chứa log kiểm thử.
RuntimeData/: cấu hình, dự báo và baseline-reference.zip cần tái chạy.
_local/: trạng thái, request, kết quả và log phát sinh; không đưa lên Git.

TECH STACK / MÁY CHẠY
Windows x64; SQL Server 2022 Developer; SSIS 2022; SSAS 2022 Multidimensional/MOLAP.
Python 3.11 x64 + Gurobi/CPLEX theo requirements DSS; .NET SDK 10 cho web; Power BI Desktop.
ODBC Driver 17, MSOLEDBSQL 18, MSOLAP, SQLCMD, DTExec 2022.
Máy đã dùng: i7-14700F, RAM 64 GiB; chưa xác định cấu hình tối thiểu.
SQL localhost; SSAS localhost\COMPANYXOLAP. Hai SQL warehouse ACT/SIM và một SSAS cube ACT có hậu tố _20261107.

CHUYỂN MÁY
1. Tạo .venv và cài DSS/requirements-base.txt cùng requirements bộ giải phù hợp.
2. Chạy: .venv\Scripts\python.exe -B Tools/configure_checkout.py
   Công cụ cập nhật đường dẫn theo nơi clone, kiểm checksum và giải nén baseline trong project.
3. Giữ license Gurobi tại E:\Gurobi\gurobi.lic trên máy demo; máy khác cấu hình GRB_LICENSE_FILE. Không commit license.
4. Khôi phục nguồn CompanyX_Demo và hai warehouse bằng bộ dữ liệu bàn giao, rồi deploy/process cube ACT.
   Git không chứa MDF/LDF/BAK hoặc kết quả SQL. Chỉ clone source chưa có dữ liệu demo trên SQL.
5. Trước lượt DSS mới, dùng gói 70 để chuẩn bị snapshot ACT qua MDX; gói 80_DSS_to_SIM_Warehouse chạy DSS và refresh SQL SIM;
   gói 90_Refresh_SIM_SQL làm mới cache và active scope SQL cho web; gói 00_ACT_DSS_SIM chạy nguyên luồng. Request JSON đặt trong _local; đổi RequestID cho lượt mới.
Không sao chép .venv như bộ cài. Log/kiểm thử/bằng chứng cũ không cần để chạy và bị ignore.
