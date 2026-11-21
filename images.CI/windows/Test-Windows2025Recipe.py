"""Validate matched arms and protection of the established AL-Go recipe."""
import json
import re
import subprocess
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
base = 'b9953709dd23ce6a92afc42a671d726cc6fdfb0d'
def old(path): return subprocess.check_output(['git','show',f'{base}:{path}'], cwd=repo).decode('utf-8-sig').replace('\r\n','\n')
def current(path): return (repo/path).read_text(encoding='utf-8-sig')
def check(value, message):
    if not value: raise AssertionError(message)
    print('PASS:',message)

template='images/windows/templates/build.windows-2022-algo.pkr.hcl'
a=current(template)
b=current(template.replace('2022','2025'))
b=b.replace('2025','2022').replace('win25','win22')
check(a[a.index('build {'):]==b[b.index('build {'):], '2022/2025 provisioner bodies, order, environments and telemetry are identical after OS/name substitution')
original=old(template)
blocks=lambda text: re.findall(r'(?ms)^  provisioner "windows-restart" \{.*?^  \}',text)
check(blocks(a)==blocks(original),'all established restarts/readiness checks preserved')
pauses=lambda text: re.findall(r'(?m)^\s*pause_before\s*=.*$',text)
check(pauses(a)==pauses(original),'all established pauses preserved')
phase=lambda text: text[text.index('  # Phase 2:'):text.index('  # Phase 3:')]
check(phase(a)==phase(original),'payload upload, retries, extraction/count checks and error cleanup preserved')
scripts=lambda text: re.findall(r'"\$\{path.root\}/../scripts/([^"\n]+\.ps1)"',text)
new=scripts(a)
new=[x for x in new if x not in ('build/Set-BcPolicy-ALGo.ps1','build/Invoke-Sysprep-ALGo.ps1')]
new=[x.replace('Install-Docker-ALGo','Install-Docker').replace('Invoke-Cleanup-ALGo','Invoke-Cleanup').replace('Install-WindowsUpdates-ALGo','Install-WindowsUpdates') for x in new]
check(new==scripts(original),'all existing provisioning scripts remain in the tested ordering sequence')
for path in ('images/windows/scripts/build/Smoke-BcContainer.ps1',
             'images/windows/scripts/build/Install-ChocolateyPackages-ALGo.ps1',
             'images.CI/windows/Pack-ImagePayload-ALGo.ps1',
             'images/windows/templates/source.windows.pkr.hcl',
             'images/windows/templates/locals.windows.pkr.hcl',
             'images/windows/scripts/build/Configure-System.ps1',
             'images/windows/scripts/build/Configure-User-ALGo.ps1'):
    check(current(path)==old(path),f'protected implementation unchanged: {path}')
tool='images/windows/toolsets/toolset-2022-algo.json'
toolset=json.loads(current(tool)); control=json.loads(old(tool))
check(toolset==json.loads(current(tool.replace('2022','2025'))),'minimal toolsets identical')
control['docker']['images']=toolset['docker']['images']
check(toolset==control,'all toolset data except immutable generic reference preserved')
required='images/windows/scripts/tests/RunAll-ALGo-Tests.ps1'
names=lambda text: re.findall(r'^\s+"([^"\n]+)"',text,re.M)
expected=names(old(required))
actual=[x.replace('WindowsFeatures-ALGo','WindowsFeatures') for x in names(current(required)) if x!='BcPolicy-ALGo']
check(actual==expected,'all established curated test files retained; only minimal WSL2 contract is substituted')
features='images/windows/scripts/tests/WindowsFeatures'
check(current(features+'-ALGo.Tests.ps1').split('# AL-Go installs')[0].rstrip()==old(features+'.Tests.ps1').split('Describe "WSL2"')[0].rstrip(),'all original feature assertions except uninstalled WSL2 runtime retained')
print('Matched recipe regression checks complete; no provisioning performed.')
