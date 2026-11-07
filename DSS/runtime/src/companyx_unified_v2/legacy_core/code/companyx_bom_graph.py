# ĐỒ THỊ BOM VÀ CÁC PHÉP TÍNH SỐ LƯỢNG LINH KIỆN
#
# Cấu trúc file:
#   1. BOM: dựng quan hệ cha-con, kiểm tra đơn vị và phát hiện vòng lặp.
#   2. explode(): nổ BOM nhiều tầng để tính nhu cầu gộp của một đơn vị mã gốc.
#   3. immediate()/consume(): lượng linh kiện trực tiếp và tiện ích xuất vật tư.
#   4. edge() và Checks: dữ liệu nhỏ và các kiểm tra kỹ thuật của đồ thị.
#   5. __main__: lệnh xuất dữ liệu từ dự án cũ, không phải điểm chạy của gói này.
#
# children[cha] chứa các bộ (mã con, định mức, đơn vị). Mã con có thể là hàng tự
# sản xuất hoặc mua ngoài. Khóa (ProductID, UnitMeasureCode) giữ riêng đơn vị.
# Không tự đổi BOX sang EA hoặc cộng lượng của các đơn vị khác nhau.
#
# Phân biệt hai việc: explode() dùng cho nhu cầu gộp/thiết lập tham số, còn khi
# khởi công chỉ tiêu hao linh kiện trực tiếp. Nổ nhiều tầng để xuất kho ngay sẽ
# đếm trùng nguyên liệu đã nằm trong linh kiện trung gian.
# Gói chạy qua run.py và import lớp BOM, không thực thi khối __main__ cuối file.
"""Unit-aware BOM graph. Pure audit/quantity functions; no assumed unit conversions."""
from collections import defaultdict, Counter
from functools import lru_cache
from pathlib import Path
import json, csv, unittest
R=Path(__file__).resolve().parents[1]

# Lớp đồ thị chỉ xử lý quan hệ vật tư và số lượng. Không chứa lịch sản xuất hay quyết định giao hàng.
class BOM:
 # Dựng danh sách con từ các dòng BOM, bỏ dòng không có mã cha.
 # Từ chối định mức không dương, đơn vị không nhất quán và cấu trúc có vòng lặp.
 def __init__(self,edges):
  self.children=defaultdict(list);self.units={}
  for e in edges:
   a,c,q,u=e['ProductAssemblyID'],e['ComponentID'],e['PerAssemblyQty'],e['UnitMeasureCode']
   if a is None:continue
   if q<=0:raise ValueError('BOM coefficient must be positive')
   if c in self.units and self.units[c]!=u:raise ValueError('Conversion required for component '+str(c))
   self.units[c]=u;self.children[a].append((c,q,u))
  # Nổ thử từ mỗi cha ngay khi dựng đồ thị để phát hiện vòng lặp trước mô phỏng.
  for a in list(self.children):self.explode(a)
 # Tính nhu cầu gộp cho MỘT đơn vị root qua mọi đường BOM.
 # Ví dụ A cần 2 B, B cần 3 C thì đóng góp A -> B -> C là 6 C.
 # Nếu còn một đường khác tới C, lượng của đường đó được cộng thêm.
 # Kết quả được cache vì cấu trúc BOM cố định trong lượt chạy, chưa trừ tồn kho.
 @lru_cache(None)
 def explode(self,root):
  """Return per-root-unit gross descendant requirements, summing shared paths.
  Intermediate and leaf entries are separate products; never sum unlike units.
  This is gross explosion, not net replenishment or executed consumption.
  """
  out=Counter()
  # Đi sâu từng đường. scale là tích định mức trên đường đã đi, path dùng phát hiện vòng lặp.
  def walk(p,scale,path):
   if p in path:raise ValueError('Cyclic BOM')
   for c,q,u in self.children.get(p,[]):
    out[c,u]+=scale*q;walk(c,scale*q,path+(p,))
  walk(root,1,());return dict(out)
 # Tính lượng của các linh kiện trực tiếp để làm q đơn vị p. Không đi tiếp xuống tầng dưới.
 def immediate(self,p,q):return {(c,u):a*q for c,a,u in self.children.get(p,[])}
 # Tiện ích xuất đồng thời toàn bộ linh kiện trực tiếp: thiếu một loại thì không trừ loại nào.
 # Hàm này yêu cầu đủ cả vật tư mua ngoài trong stock. Bộ mô phỏng chính không gọi hàm này,
 # vì nó tự trừ linh kiện sản xuất và giả định vật tư mua ngoài luôn có sẵn.
 def consume(self,p,q,stock):
  """Atomic immediate consumption. All components, including purchased, must exist.
  External replenishment is a separate event, never a hidden negative balance.
  """
  req=self.immediate(p,q)
  if any(stock.get(k,0)+1e-9<v for k,v in req.items()):return False
  for k,v in req.items():stock[k]=stock.get(k,0)-v
  return True

# Tạo một cạnh BOM nhỏ để dùng trong các ví dụ/kiểm tra bên dưới.
def edge(a,c,q=1,u='EA'):return dict(ProductAssemblyID=a,ComponentID=c,PerAssemblyQty=q,UnitMeasureCode=u)
# Các kiểm tra sẵn có của BOM, không phải các lượt mô phỏng CompanyX.
class Checks(unittest.TestCase):
 # Kiểm tra linh kiện chung được cộng từ hai đường: 2*5 + 3*7 = 31.
 def test_shared_component_paths(self):
  b=BOM([edge(1,2,2),edge(1,3,3),edge(2,4,5),edge(3,4,7)])
  self.assertEqual(b.explode(1)[4,'EA'],31)
 # Kiểm tra làm A chỉ trừ B trực tiếp, không trừ thêm C đã dùng để tạo B.
 def test_immediate_not_recursive_consumption(self):
  b=BOM([edge(1,2,2),edge(2,3,5)]);s={(2,'EA'):4,(3,'EA'):100}
  self.assertTrue(b.consume(1,2,s));self.assertEqual(s,{(2,'EA'):0,(3,'EA'):100})
 # Kiểm tra thiếu một linh kiện không gây xuất dở các linh kiện còn lại.
 def test_atomic_shortage(self):
  b=BOM([edge(1,2,2),edge(1,3,3)]);s={(2,'EA'):2,(3,'EA'):2};before=dict(s)
  self.assertFalse(b.consume(1,1,s));self.assertEqual(s,before)
 # Kiểm tra lượng theo OZ và IN vẫn tách theo từng mã và đơn vị.
 def test_separate_units(self):
  b=BOM([edge(1,2,8,'OZ'),edge(1,3,40,'IN')]);self.assertEqual(b.immediate(1,2),{(2,'OZ'):16,(3,'IN'):80})
 # Kiểm tra BOM A -> B -> A bị từ chối.
 def test_cycle_rejected(self):
  with self.assertRaises(ValueError):BOM([edge(1,2),edge(2,1)])
 # Kiểm tra cùng một linh kiện có EA và BOX bị từ chối khi chưa có quy đổi.
 def test_inconsistent_units_rejected(self):
  with self.assertRaises(ValueError):BOM([edge(1,2,1,'EA'),edge(3,2,1,'BOX')])

# KHỐI TIỆN ÍCH CỦA DỰ ÁN GỐC, KHÔNG DÙNG ĐỂ CHẠY GÓI V1.
# Khối này cần các thư mục output cũ để xuất bảng hệ số. Dùng run.py ở thư mục gói.
# Muốn chạy riêng kiểm tra BOM mà không vào khối này: python -m unittest discover -s code -p companyx_bom_graph.py
if __name__=='__main__':
 suite=unittest.defaultTestLoader.loadTestsFromTestCase(Checks);result=unittest.TextTestRunner().run(suite)
 assert result.wasSuccessful()
 O=R/'output/companyx_bom_v1';b=BOM(json.loads((O/'active_edges.json').read_text(encoding='utf-8')))
 roots=[int(x['ProductID']) for x in csv.DictReader((R/'output/inventory_baselines_v2_workorder_median/product_roster_190.csv').open(encoding='utf-8-sig'))]
 rows=[dict(RootProductID=p,ComponentID=c,UnitMeasureCode=u,GrossQtyPerRootUnit=q) for p in roots for (c,u),q in sorted(b.explode(p).items())]
 with (O/'exploded_gross_coefficients.csv').open('w',encoding='utf-8-sig',newline='') as f:
  w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
 (O/'bom_unit_tests.json').write_text(json.dumps({'tests_run':result.testsRun,'passed':result.wasSuccessful(),'coefficient_rows':len(rows),'meaning':'Gross BOM quantities per root unit; not net production, not consumption results.'},indent=2),encoding='utf-8')
 print('Gross explosion rows:',len(rows))
