"""Pure XML helpers for the isolated native SSAS projects. No database connection."""
from __future__ import annotations

import argparse
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import xml.etree.ElementTree as ET

E = 'http://schemas.microsoft.com/analysisservices/2003/engine'
XS = 'http://www.w3.org/2001/XMLSchema'
XSI = 'http://www.w3.org/2001/XMLSchema-instance'
MSDATA = 'urn:schemas-microsoft-com:xml-msdata'
MSPROP = 'urn:schemas-microsoft-com:xml-msprop'
for prefix, namespace in [('', E), ('xs', XS), ('xsi', XSI), ('msdata', MSDATA), ('msprop', MSPROP)]:
    ET.register_namespace(prefix, namespace)

IDENTIFIER = re.compile(r'^[A-Za-z_][A-Za-z_0-9]*$')



def add(parent, name, text=None, **attributes):
    element = ET.SubElement(parent, '{'+E+'}'+name, attributes)
    if text is not None:
        element.text = str(text)
    return element


def one(parent, name):
    found = parent.find('{'+E+'}'+name)
    return found if found is not None else add(parent, name)


def set_text(parent, name, value):
    one(parent, name).text = str(value)


def named(parent, name, value):
    return next((x for x in parent if x.findtext('{'+E+'}'+name) == value), None)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def safe_id(value):
    if not IDENTIFIER.fullmatch(value):
        raise ValueError('Unsafe SQL identifier: '+str(value))
    return value


def sql_columns(conn, table):
    safe_id(table)
    rows = conn.execute('''SELECT c.name,t.name,c.max_length,c.is_nullable
        FROM sys.columns c JOIN sys.types t ON t.user_type_id=c.user_type_id
        WHERE c.object_id=OBJECT_ID(?) ORDER BY c.column_id''', 'cxdetail.'+table).fetchall()
    if not rows:
        raise ValueError('Missing SQL view cxdetail.'+table)
    return {r[0]: {'sql_type': r[1], 'max_length': int(r[2]), 'nullable': bool(r[3])} for r in rows}


def types(column):
    sql = column['sql_type'].lower()
    if sql in ('int', 'smallint', 'tinyint'):
        return 'Integer', 'xs:int', None
    if sql == 'bigint':
        return 'BigInt', 'xs:long', None
    if sql in ('float', 'real', 'decimal', 'numeric', 'money', 'smallmoney'):
        return 'Double', 'xs:double', None
    if sql == 'bit':
        return 'Boolean', 'xs:boolean', None
    if sql in ('date', 'datetime', 'datetime2', 'smalldatetime'):
        return 'Date', 'xs:dateTime', None
    if sql in ('nvarchar', 'nchar', 'varchar', 'char', 'uniqueidentifier'):
        size = 36 if sql == 'uniqueidentifier' else column['max_length']
        if sql in ('nvarchar', 'nchar') and size > 0:
            size //= 2
        return 'WChar', 'xs:string', 4000 if size < 0 else size
    raise ValueError('Unsupported SQL type in cube contract: '+sql)


def data_item(parent, table, column, metadata, tag='Source'):
    data_type, _, size = types(metadata[table][column])
    item = add(parent, tag)
    add(item, 'DataType', data_type)
    if size:
        add(item, 'DataSize', size)
    add(item, 'NullProcessing', 'Preserve')
    binding = add(item, 'Source', **{'{'+XSI+'}type': 'ColumnBinding'})
    add(binding, 'TableID', table)
    add(binding, 'ColumnID', column)
    return item


def dimension_key_binding(parent, table, column, metadata, attribute):
    """SSAS requires FK bindings to use the dimension key's declared type.

    SQL fact columns may use bigint for a key whose dimension view casts to int.
    The source binding still names the fact column; only the SSAS DataItem type
    follows the referenced key, as required by the multidimensional schema.
    """
    keys=attribute.findall('./{*}KeyColumns/{*}KeyColumn')
    if len(keys)!=1:
        raise ValueError('Detail contract supports single-column dimension keys only')
    template=keys[0]
    target_type=template.findtext('{*}DataType')
    source_type=types(metadata[table][column])[0]
    numeric={'Integer','BigInt','SmallInt','TinyInt','UnsignedInt','UnsignedBigInt'}
    compatible=(source_type==target_type or (source_type in numeric and target_type in numeric))
    if not compatible:
        raise ValueError('Incompatible fact/dimension key types: '+table+'.'+column+' '+source_type+' -> '+str(target_type))
    item=deepcopy(template)
    binding=item.find('{*}Source')
    if binding is None or binding.get('{'+XSI+'}type')!='ColumnBinding':
        raise ValueError('Expected a ColumnBinding dimension key')
    set_text(binding,'TableID',table);set_text(binding,'ColumnID',column)
    parent.append(item)
    return item


def add_dsv_table(dsv, table, columns, primary_key=None):
    schema = dsv.find('./{*}Schema/{'+XS+'}schema')
    dataset = schema.find('{'+XS+'}element')
    choice = dataset.find('./{'+XS+'}complexType/{'+XS+'}choice')
    if any(x.get('name') == table for x in choice):
        raise ValueError('DSV table already exists: '+table)
    row = ET.SubElement(choice, '{'+XS+'}element', {
        'name': table, '{'+MSPROP+'}DbTableName': table,
        '{'+MSPROP+'}DbSchemaName': 'cxdetail', '{'+MSPROP+'}FriendlyName': table})
    sequence = ET.SubElement(ET.SubElement(row, '{'+XS+'}complexType'), '{'+XS+'}sequence')
    for name, meta in columns.items():
        _, xsd_type, size = types(meta)
        attrs = {'name': name}
        if meta['nullable']:
            attrs['minOccurs'] = '0'
        if size:
            col = ET.SubElement(sequence, '{'+XS+'}element', attrs)
            restriction = ET.SubElement(ET.SubElement(col, '{'+XS+'}simpleType'), '{'+XS+'}restriction', {'base':'xs:string'})
            ET.SubElement(restriction, '{'+XS+'}maxLength', {'value':str(size)})
        else:
            ET.SubElement(sequence, '{'+XS+'}element', dict(attrs, type=xsd_type))
    if primary_key:
        unique = ET.SubElement(dataset, '{'+XS+'}unique', {'name':'DetailPK_'+table,'{'+MSDATA+'}PrimaryKey':'true'})
        ET.SubElement(unique, '{'+XS+'}selector', {'xpath':'.//'+table})
        ET.SubElement(unique, '{'+XS+'}field', {'xpath':primary_key})


def create_dimension(spec, metadata):
    dimension = ET.Element('{'+E+'}Dimension')
    add(dimension, 'ID', spec['id'])
    add(dimension, 'Name', spec['id'])
    if spec.get('description'):
        add(dimension, 'Description', spec['description'])
    source = add(dimension, 'Source', **{'{'+XSI+'}type':'DataSourceViewBinding'})
    add(source, 'DataSourceViewID', 'CompanyXSourceView')
    errors = add(dimension, 'ErrorConfiguration')
    for name in ('KeyNotFound','KeyDuplicate','NullKeyConvertedToUnknown'):
        add(errors,name,'ReportAndStop')
    attributes = add(dimension,'Attributes')
    key_attr = add(attributes,'Attribute')
    add(key_attr,'ID',spec['id']); add(key_attr,'Name',spec['id']); add(key_attr,'Usage','Key')
    data_item(add(key_attr,'KeyColumns'),spec['table'],spec['key'],metadata,'KeyColumn')
    if types(metadata[spec['table']][spec['name']])[0]!='WChar':
        raise ValueError('Dimension caption must be a string column: '+spec['id'])
    data_item(key_attr,spec['table'],spec['name'],metadata,'NameColumn')
    if spec.get('attributes'):
        relationships = add(key_attr,'AttributeRelationships')
        for extra in spec['attributes']:
            rel = add(relationships,'AttributeRelationship')
            add(rel,'AttributeID',extra['id']); add(rel,'Name',extra['id'])
    for extra in spec.get('attributes',[]):
        attr = add(attributes,'Attribute')
        add(attr,'ID',extra['id']); add(attr,'Name',extra['id'])
        data_item(add(attr,'KeyColumns'),spec['table'],extra['column'],metadata,'KeyColumn')
        caption=extra.get('name_column',extra['column'])
        if types(metadata[spec['table']][caption])[0]=='WChar':
            data_item(attr,spec['table'],caption,metadata,'NameColumn')
        elif caption!=extra['column']:
            raise ValueError('Explicit attribute caption must be a string column: '+extra['id'])
        # SSAS requires NameColumn to be string. Without a separate label,
        # numeric/Boolean attributes use the key's built-in caption conversion.
    add(dimension,'AttributeAllMemberName','All '+spec['id'])
    return dimension


def cube_dimension(role, database_dimension):
    result = ET.Element('{'+E+'}Dimension')
    add(result,'ID',role); add(result,'Name',role)
    add(result,'DimensionID',database_dimension.findtext('{*}ID'))
    attrs = add(result,'Attributes')
    for attr in database_dimension.findall('./{*}Attributes/{*}Attribute'):
        add(add(attrs,'Attribute'),'AttributeID',attr.findtext('{*}ID'))
    if database_dimension.find('{*}Hierarchies') is not None:
        hierarchies = add(result,'Hierarchies')
        for hierarchy in database_dimension.findall('./{*}Hierarchies/{*}Hierarchy'):
            add(add(hierarchies,'Hierarchy'),'HierarchyID',hierarchy.findtext('{*}ID'))
    return result

