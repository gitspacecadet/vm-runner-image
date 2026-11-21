"""Prepare local files for a dedicated manual-only AL-Go test repository.

Does not create/push a GitHub repository, register a runner, or dispatch work.
Use a fresh destination for each phase and compare/review the generated diff.
"""
import argparse
import hashlib
import json
import re
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--destination', type=Path, required=True)
parser.add_argument('--artifact', required=True, help='Exact artifact URL from image cache metadata; different exact URL for a deliberate miss')
parser.add_argument('--runner-label', required=True, help='One experiment-specific label; register repo-scoped runner with --no-default-labels')
parser.add_argument('--generic', default='mcr.microsoft.com/businesscentral@sha256:ca688c497bc9189a9936c39e24cbcc55626f495d9dc1978a49e03300953835d2', help='Exact generic digest from the image metadata')
parser.add_argument('--phase', choices=['baseline','upgrade','negative','miss'], default='baseline')
args = parser.parse_args()
if not re.fullmatch(r'algo-prototype-[a-z0-9-]+',args.runner_label):
    parser.error('Use an experiment-specific algo-prototype-* label')
if not re.fullmatch(r'https://[A-Za-z0-9.-]+/sandbox/\d+\.\d+\.\d+\.\d+/[a-z]{2}/?',args.artifact):
    parser.error('An exact public Sandbox artifact URL without query credentials is required')
if not re.fullmatch(r'mcr\.microsoft\.com/businesscentral@sha256:[0-9a-f]{64}',args.generic):
    parser.error('An immutable MCR Business Central generic digest is required')
dest = args.destination.resolve()
if dest.exists() and any(dest.iterdir()):
    parser.error('Destination must be new or empty; never overwrite an existing repository')
dest.mkdir(parents=True,exist_ok=True)
template_sha='a874d1aa182fb6f827e30b0f5f7147db5a96f9f4'
actions_sha='176941c05ae3d0777a2f4dd74cb9d179a3b7974d'
sources={}
def write(name,text):
    path=(dest/name).resolve()
    if not path.is_relative_to(dest): raise ValueError('Path escaped fixture destination')
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(text,encoding='utf-8',newline='\n')
def write_json(name,value): write(name,json.dumps(value,indent=2)+'\n')
def download_workflow(name):
    if name in sources: return
    url=f'https://raw.githubusercontent.com/microsoft/AL-Go-PTE/{template_sha}/.github/workflows/{name}'
    raw=urllib.request.urlopen(url,timeout=60).read()
    sources[name]={'url':url,'sha256':hashlib.sha256(raw).hexdigest()}
    text=raw.decode('utf-8-sig').replace('\r\n','\n')
    if name=='CICD.yaml':
        text,count=re.subn(r'(?ms)^on:\n.*?(?=^defaults:)', 'on:\n  workflow_dispatch:\n\n', text, count=1)
        if count!=1: raise ValueError('Official workflow trigger contract changed')
        # Keep the standard BC build/test/analyzer/postprocessing route. This
        # isolated fixture has no delivery, deployment, docs or updater jobs.
        text=re.sub(r'(?ms)^  (?:CheckForUpdates|BuildPP|DeployALDoc|Deploy|Deliver):\n.*?(?=^  [A-Za-z][A-Za-z0-9]*:|\Z)','',text)
        text=text.replace('needs: [ Initialization, Build, BuildPP, Deploy, Deliver, DeployALDoc, CodeAnalysisUpload ]','needs: [ Initialization, Build, CodeAnalysisUpload ]')
    text=re.sub(r'(?m)^\s+needs: \[\s*\]\s*\n','',text)
    text=re.sub(r'(microsoft/AL-Go-Actions/[^\s@]+)@v9\.0',rf'\g<1>@{actions_sha}',text)
    for dependency in re.findall(r'uses:\s*\./\.github/workflows/([A-Za-z0-9_.-]+\.ya?ml)',text):
        download_workflow(dependency)
    write('.github/workflows/'+name,text)
download_workflow('CICD.yaml')
settings={
    'type':'PTE','country':args.artifact.rstrip('/').split('/')[-1],
    'artifact':args.artifact.rstrip('/'),'cacheImageName':'my',
    'githubRunner':args.runner_label,'githubRunnerShell':'powershell',
    'skipUpgrade':False,'doNotRunTests':False,'doNotRunBcptTests':False,
    'enableCodeCop':True,'enableUICop':True,'enableCodeAnalyzersOnTestApps':True,
    'installTestRunner':True,'alwaysBuildAllProjects':True,
    'genericImageName':args.generic,'defaultNewContainerParameters':{'isolation':'process'}
}
write_json('.github/AL-Go-Settings.json',settings)
write_json('.AL-Go/settings.json',{'country':settings['country'],'appFolders':['App'],'testFolders':['Tests'],'bcptTestFolders':[]})
version={'baseline':'1.0.0.0','upgrade':'1.1.0.0','negative':'1.2.0.0','miss':'1.3.0.0'}[args.phase]
app_id='9dbbe92c-31c4-4912-9b30-ac5e272e0c80'
common={'publisher':'AL-Go Prototype','version':version,'brief':'Isolated runner image correctness fixture','description':'Controlled compile, publish, test and upgrade validation','privacyStatement':'','EULA':'','help':'','url':'','logo':'','dependencies':[],'screenshots':[],'platform':'29.0.0.0','application':'29.0.0.0','runtime':'13.0','target':'Cloud','features':['NoImplicitWith']}
write_json('App/app.json',{**common,'id':app_id,'name':'Runner Image Prototype','idRanges':[{'from':50100,'to':50149}]})
write_json('Tests/app.json',{**common,'id':'ff8c8f21-645d-4bce-8451-78f52cfe0025','name':'Runner Image Prototype Tests','idRanges':[{'from':50150,'to':50199}],'dependencies':[{'id':app_id,'name':'Runner Image Prototype','publisher':'AL-Go Prototype','version':version}]})
write('App/Counter.Table.al','''table 50100 "Prototype Counter"
{
    Caption = 'Prototype Counter';
    DataClassification = CustomerContent;
    fields
    {
        field(1; "Code"; Code[20]) { Caption = 'Code'; }
        field(2; "Value"; Integer) { Caption = 'Value'; }
    }
    keys { key(PK; "Code") { Clustered = true; } }
}
''')
write('App/Arithmetic.Codeunit.al','''codeunit 50101 "Prototype Arithmetic"
{
    procedure Add(Left: Integer; Right: Integer): Integer
    begin
        exit(Left + Right);
    end;
}
''')
expected=43 if args.phase=='negative' else 42
upgrade_test='''
    [Test]
    procedure UpgradeCodeRan()
    var
        Counter: Record "Prototype Counter";
    begin
        if not Counter.Get('UPGRADE') then
            Error('Required upgrade marker missing.');
        if Counter.Value <> 99 then
            Error('Required upgrade marker incorrect.');
    end;
''' if args.phase!='baseline' else ''
write('Tests/Correctness.Codeunit.al','''codeunit 50150 "Prototype Correctness"
{
    Subtype = Test;
    TestPermissions = Disabled;
    [Test]
    procedure ArithmeticIsCorrect()
    var
        Arithmetic: Codeunit "Prototype Arithmetic";
    begin
        if Arithmetic.Add(19, 23) <> '''+str(expected)+''' then
            Error('Controlled arithmetic assertion failed.');
    end;
'''+upgrade_test+'}\n')
if args.phase!='baseline':
    write('App/Upgrade.Codeunit.al','''codeunit 50102 "Prototype Upgrade"
{
    Subtype = Upgrade;
    trigger OnUpgradePerCompany()
    var
        Counter: Record "Prototype Counter";
    begin
        if not Counter.Get('UPGRADE') then begin
            Counter.Code := 'UPGRADE';
            Counter.Insert();
        end;
        Counter.Value := 99;
        Counter.Modify();
    end;
}
''')
write('.AL-Go/NewBcContainer.ps1','''Param([Hashtable] $parameters)
$ErrorActionPreference = 'Stop'
$metadata = Get-Content 'C:\\bcartifacts.cache\\bc-cache-metadata.json' -Raw | ConvertFrom-Json
if ((Get-BestGenericImageName) -ne $metadata.genericImage) { throw 'Actual AL-Go helper generic differs from the baked policy' }
if ($parameters.ContainsKey('isolation') -and $parameters.isolation -ne 'process') { throw 'Unexpected explicit isolation in AL-Go parameters' }
if ($parameters.ContainsKey('multitenant') -and -not $parameters.multitenant) { throw 'This fixture requires the matched multitenant workload' }
$parameters.isolation = 'process'
$parameters.multitenant = $true
$parameters.useGenericImage = $metadata.genericImage
$requested = ([uri]$parameters.artifactUrl).AbsolutePath.TrimEnd('/')
$hitExpected = $requested -eq ([uri]$metadata.artifactUrl).AbsolutePath.TrimEnd('/')
$watch = [Diagnostics.Stopwatch]::StartNew()
New-BcContainer @parameters
$raw = docker inspect $parameters.containerName --format '{{json .}}'
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect independent AL-Go job container' }
$container = $raw | ConvertFrom-Json
if ($container.HostConfig.Isolation -ne 'process') { throw 'Actual AL-Go container did not use process isolation' }
if ($hitExpected -and $container.Image -ne $metadata.dockerImageId) { throw 'Expected exact cache hit rebuilt or selected another image' }
if (-not $hitExpected -and $container.Image -eq $metadata.dockerImageId) { throw 'Deliberate miss incorrectly reused the baked image' }
$companies = Invoke-BcContainerApi -containerName $parameters.containerName -credential $parameters.Credential -APIVersion 'v2.0' -Query 'companies' -silent
if (-not @($companies.value).Count) { throw 'Authenticated BC API returned no companies' }
$record = @{ utc = [DateTime]::UtcNow.ToString('o'); container = $parameters.containerName; imageId = $container.Image; expectedBakedImageId = $metadata.dockerImageId; exactHitExpected = $hitExpected; actualBakedImage = ($container.Image -eq $metadata.dockerImageId); isolation = $container.HostConfig.Isolation; authenticatedApi = $true; artifactPath = $requested; generic = $metadata.genericImage; containerInitSeconds = $watch.Elapsed.TotalSeconds; helperVersion = (Get-Module BcContainerHelper).Version.ToString() }
Write-Host "[ALGO PROTOTYPE] $($record | ConvertTo-Json -Compress)"
Invoke-ScriptInBcContainer $parameters.ContainerName -scriptblock { $progressPreference = 'SilentlyContinue' }
''')
write_json('.prototype-fixture.json',{'phase':args.phase,'templateSha':template_sha,'actionsSha':actions_sha,'artifact':args.artifact,'generic':args.generic,'runnerLabel':args.runner_label,'sources':sources,'remoteExecuted':False})
print(f'Prepared {args.phase} fixture in {dest}; no remote repository/registration/dispatch.')
