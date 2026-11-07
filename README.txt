COMPANYX — HAI WAREHOUSE / HAI CUBE MOLAP (07/11/2026)

MỞ PROJECT
Mở CompanyX.ACT_SIM.sln bằng Visual Studio 2022.
Solution gồm CompanyX.Split.Integration (SSIS), CompanyX.ACT.Analysis và CompanyX.SIM.Analysis (SSAS).
Hướng dẫn đọc cube và luồng chạy: HUONG_DAN_CUBE.txt.

CẤU TRÚC
MOLAP/                       Hai project cube ACT và SIM; XMLA triển khai.
CompanyX.Split.Integration/   Các gói SSIS của luồng mới.
Warehouse/Data/               File vật lý của hai SQL warehouse mới.
Warehouse/Split/              Hợp đồng v2 gồm 9 tập nghiệp vụ qua ACT MOLAP; script và nguồn tham chiếu.
Database/, SSIS/              Nguồn SQL và ETL hiện có; SSIS/SourceTemplate chỉ là mẫu.
DSS/runtime/, DSS/control/    Lõi Python hiện có và bộ nối xuất bản kết quả sang SIM.
KetQua/Demo_01/               Đầu vào/tham số đóng băng của mô hình hiện có.
Tools/cube_pipeline/          Điều phối Python, xuất MDX, triển khai và process cube.
.venv/                       Python 3.11 x64 của máy hiện tại.
Log, kiểm thử, cache, baseline và kết quả chạy: E:\Study-BKU\GPT (ngoài project này).

TECH STACK
SQL Server 2022 Developer; SSIS 2022 x64; SSAS 2022 Multidimensional/MOLAP.
Python 3.11 x64; bộ giải Gurobi/CPLEX theo cấu hình DSS hiện có.
Visual Studio 2022 + SQL Server Integration Services Projects + Analysis Services Projects.
Kết nối: ODBC Driver 17, MSOLEDBSQL 18, MSOLAP, SQLCMD, DTExec 2022.
Luồng chạy dùng SSIS và Python. Không có PowerShell, C/C# hay web framework bổ sung.
Power BI/Web chưa nằm trong phạm vi bản tách này.

MÁY ĐÃ KIỂM TRA
Windows 11 Home x64; Intel Core i7-14700F (20 nhân/28 luồng); RAM khoảng 64 GiB.
SQL Engine: localhost. SSAS Multidimensional: localhost\COMPANYXOLAP.
Warehouse: CompanyX_DW_ACT_20261107 và CompanyX_DW_SIM_20261107.
SSAS database: CompanyX_ACT_20261107 và CompanyX_SIM_20261107.

YÊU CẦU CHẠY
Các dịch vụ SQL/SSAS và provider x64 nói trên; tài khoản Windows có quyền trên hai kho/cube mới.
Nguồn OLTP CompanyX_Demo phải có trên SQL local để chạy ETL.
Máy khác: dựng lại .venv từ DSS/requirements-base.txt và requirements của bộ giải cần dùng;
license bộ giải phải hợp lệ. Không xem bản .venv sao chép là bộ cài portable.
Chuẩn bị hai warehouse từ bản sao lưu; cấu hình tên máy/đường dẫn trước khi chạy.
Đây là cấu hình đã kiểm tra trên máy 64 GiB; chưa đo mức RAM tối thiểu cho máy yếu hơn.
