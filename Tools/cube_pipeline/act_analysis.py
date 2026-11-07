"""Business-only ACT presentation; source records and DSS input contract remain intact."""
import xml.etree.ElementTree as ET
from copy import deepcopy
from pathlib import Path
E='http://schemas.microsoft.com/analysisservices/2003/engine'
XS='http://www.w3.org/2001/XMLSchema'
MSDATA='urn:schemas-microsoft-com:xml-msdata'
REMOVED_DIMENSIONS={'Customer','Data Quality'}
REMOVED_TABLES={'OpsDimCustomer','OpsDimDataQuality'}
DQ_MEASURES={'Actual Sales DQ Line Count','Actual Purchase DQ Line Count','Actual WorkOrder DQ Count','Actual Operation DQ Count'}

def simplify_act_analysis(db,cube):
 if cube.findtext('{*}ID')!='CompanyX_ACT_20261107':raise ValueError('ACT-only cleanup')
 roles={d.findtext('{*}ID') for d in cube.findall('./{*}Dimensions/{*}Dimension') if d.findtext('{*}DimensionID') in REMOVED_DIMENSIONS}
 for parent in [cube.find('{*}Dimensions'),*cube.findall('./{*}MeasureGroups/{*}MeasureGroup/{*}Dimensions'),*cube.findall('./{*}Perspectives/{*}Perspective/{*}Dimensions')]:
  if parent is None:continue
  for d in list(parent):
   if (d.findtext('{*}CubeDimensionID') or d.findtext('{*}ID')) in roles:parent.remove(d)
 for d in list(db.find('{*}Dimensions')):
  if d.findtext('{*}ID') in REMOVED_DIMENSIONS:db.find('{*}Dimensions').remove(d)
 for parent in cube.findall('./{*}MeasureGroups/{*}MeasureGroup/{*}Measures')+cube.findall('./{*}Perspectives/{*}Perspective/{*}MeasureGroups/{*}MeasureGroup/{*}Measures'):
  for m in list(parent):
   if (m.findtext('{*}MeasureID') or m.findtext('{*}ID')) in DQ_MEASURES:parent.remove(m)
 for dsv in db.findall('./{*}DataSourceViews/{*}DataSourceView'):
  dataset=dsv.find('./{*}Schema/{'+XS+'}schema/{'+XS+'}element')
  choice=dataset.find('./{'+XS+'}complexType/{'+XS+'}choice')
  for table in list(choice):
   if table.get('name') in REMOVED_TABLES:choice.remove(table)
  for key in list(dataset):
   sel=key.find('{'+XS+'}selector')
   if sel is not None and sel.get('xpath','').split('/')[-1] in REMOVED_TABLES:dataset.remove(key)
  names={x.get('name') for x in dataset if x.tag in ('{'+XS+'}unique','{'+XS+'}key')}
  for key in list(dataset):
   if key.tag=='{'+XS+'}keyref' and key.get('refer','').split(':')[-1] not in names:dataset.remove(key)
  for parent in dsv.iter():
   for rel in list(parent):
    if rel.tag=='{'+MSDATA+'}Relationship' and any(rel.get('{'+MSDATA+'}'+side) in REMOVED_TABLES for side in ('parent','child')):parent.remove(rel)
 desc=cube.find('{*}Description')
 if desc is not None:desc.text='Actual sales, purchasing, inventory and production analytics; separate technical input contract for DSS.'

def apply_act_diagram(cube):
 """Load the saved native designer layout; it changes no cube relationships."""
 root=ET.parse(Path(__file__).with_name('ACT.business-diagram.xml')).getroot()
 ann=cube.find('{*}Annotations')
 if ann is None:ann=ET.SubElement(cube,'{'+E+'}Annotations')
 prefix='http://schemas.microsoft.com/DataWarehouse/Designer/1.0:'
 for a in list(ann):
  if a.findtext('{*}Name','').startswith(prefix):ann.remove(a)
 for a in root:ann.append(deepcopy(a))
 # The designer payload is unqualified XML inside the Analysis Services Value.
 for dds in ann.findall('./{*}Annotation/{*}Value/dds'):dds.set('xmlns','')
