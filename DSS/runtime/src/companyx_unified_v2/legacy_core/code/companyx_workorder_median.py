# QUY TẮC XÁC ĐỊNH LƯỢNG YÊU CẦU SẢN XUẤT MỚI
#
# Cấu trúc file: import math -> release_qty() với ba nhánh MTO, (R,S), (s,Q).
# Tên file được giữ từ mã gốc. Bản trong gói chỉ chứa quy tắc bổ sung, không đọc
# WorkOrder và không tính lại trung vị. Lead time và tham số đã nằm trong data/.
#
# Đầu vào: policy là tên chính sách, ip là vị thế tồn kho tại lúc ra quyết định,
# param chứa R/S/s/Q đã hiệu chỉnh theo mã, t là ngày tính từ 0.
# Đầu ra: số đơn vị cần tạo yêu cầu mới. Hàm không xuất kho, không khởi công,
# không tạo WIP. Bộ máy mô phỏng thực hiện những bước đó sau khi kiểm tra vật tư.
#
# ATO được ánh xạ sang MTO hoặc periodic_S trong companyx_nonopt_mid2013.py.
# ROP được bổ sung bằng hàm release() trong run.py, không nằm ở ba nhánh dưới.
"""Portable release. Core functions copied unchanged from the completed experiment."""
import math


# Trả lượng yêu cầu mới theo chính sách. IP đã tính cả nguồn cung đang chờ/WIP và nhu cầu.
# MTO bù phần IP âm. (R,S) chỉ rà soát mỗi R ngày để đưa IP lên S.
# (s,Q) rà soát hàng ngày, khi IP <= s thì đặt số lô Q nguyên đủ vượt hoặc chạm ngưỡng.
# Tại IP = s vẫn đặt ít nhất một lô Q. Không nhầm quy tắc này với ROP có điều kiện IP < rp.
def release_qty(policy,ip,param,t):
 # MTO: IP âm thể hiện phần nhu cầu chưa được nguồn cung hiện có bao phủ.
 if policy=='MTO':return max(0,-ip)
 # (R,S): chỉ tạo yêu cầu ở ngày t chia hết cho R, kể cả t=0.
 if policy=='periodic_S':return max(0,param['S']-ip) if t%param['R']==0 else 0
 # (s,Q): làm tròn lên số lô cần đặt, tối thiểu một lô khi chạm ngưỡng.
 if policy=='s_Q':return max(1,math.ceil((param['s']-ip)/param['Q']))*param['Q'] if ip<=param['s'] else 0
 raise ValueError(policy)
