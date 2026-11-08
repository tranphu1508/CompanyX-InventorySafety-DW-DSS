"""Configure this checkout after cloning. Python standard library only; no SQL writes."""
from pathlib import Path
import argparse, hashlib, json, zipfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--sql-server', default='localhost')
    parser.add_argument('--ssas-server', default=r'localhost\COMPANYXOLAP')
    args=parser.parse_args()
    if args.sql_server!='localhost' or args.ssas_server!=r'localhost\COMPANYXOLAP':
        raise ValueError('This demo requires local SQL and localhost\\COMPANYXOLAP')
    base=ROOT/'RuntimeData'
    archive=base/'baseline-reference.zip'
    expected=json.loads((base/'baseline-reference.sha256.json').read_text())['sha256']
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=expected:
        raise ValueError('Baseline bundle checksum mismatch')
    target=base/'reference'
    if not target.exists():
        with zipfile.ZipFile(archive) as z:
            for item in z.infolist():
                resolved=(target/item.filename).resolve()
                if not resolved.is_relative_to(target.resolve()):raise ValueError('Unsafe archive path')
            z.extractall(target)
    # Refresh only machine paths/configuration; never edit the frozen evidence.
    old=r'E:\Study-BKU\New Inventory Safety'
    oldgpt=r'E:\Study-BKU\GPT'
    gpt=ROOT/'_local'
    for folder, patterns in [('CompanyX.Split.Integration',['*.dtsx','*.params']),('MOLAP',['*.dwproj'])]:
        for pattern in patterns:
            for f in (ROOT/folder).rglob(pattern):
                text=f.read_text(encoding='utf-8-sig')
                import re
                replacements={old:str(ROOT),oldgpt:str(gpt)}
                receipt=ROOT/'checkout.local.json'
                if receipt.exists():
                    prior=json.loads(receipt.read_text())
                    replacements.update({prior['root']:str(ROOT),prior['gpt']:str(gpt)})
                pattern='|'.join(re.escape(k) for k in sorted(replacements,key=len,reverse=True))
                text=re.sub(pattern,lambda match:replacements[match.group()],text)
                f.write_text(text,encoding='utf-8')
    # Set only the legacy SSIS project parameter defaults; no runtime data are edited.
    import re
    params=ROOT/'CompanyX.Split.Integration/Project.params'
    text=params.read_text(encoding='utf-8-sig')
    values={'PythonExecutable':str(ROOT/'.venv/Scripts/python.exe'),
            'GurobiLicenseFile':r'E:\Gurobi\gurobi.lic',
            'OutputFolder':str(gpt/'output/companyx-split-20261107/runs/UNSET'),
            'PackageRoot':str(ROOT/'SSIS/ACT')}
    for name,value in values.items():
        pattern=r'(<SSIS:Parameter SSIS:Name="'+name+r'">.*?<SSIS:Property SSIS:Name="Value">)(.*?)(</SSIS:Property>)'
        text,count=re.subn(pattern,lambda m:m[1]+value+m[3],text,flags=re.S)
        if count!=1:raise ValueError('Expected one SSIS parameter '+name)
    params.write_text(text,encoding='utf-8')
    # Existing SQL guards intentionally keep this demo on the local default instance.
    if args.sql_server!='localhost':raise ValueError('This isolated demo requires SQL localhost; change the guards explicitly for other servers')
    if args.ssas_server!=r'localhost\COMPANYXOLAP':raise ValueError('This demo currently requires localhost\\COMPANYXOLAP')
    settings=ROOT/'Web/DssInventoryMvc/appsettings.Development.json'
    settings.write_text(json.dumps({'ConnectionStrings':{'DssSqlServer':
        'Server='+args.sql_server+';Database=CompanyX_DW_SIM_20261107;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Application Name=DssInventoryMvc'}},indent=2))
    (gpt/'tmp/companyx-split-20261107').mkdir(parents=True,exist_ok=True)
    (ROOT/'checkout.local.json').write_text(json.dumps({'root':str(ROOT),'gpt':str(gpt)},indent=2))
    print('Checkout configured; immutable baseline references extracted inside RuntimeData/reference.')
    print('SQL/SSAS databases must be restored/deployed separately. No database was changed.')

if __name__=='__main__':main()
