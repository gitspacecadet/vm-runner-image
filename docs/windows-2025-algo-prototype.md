# Windows Server 2025 AL-Go prototype

This experimental branch adds an ordinary Datacenter/Desktop Experience/x64/V1
build named `windows-2025-algo`. It is based on the tested BC-ordering recipe
`b9953709dd23ce6a92afc42a671d726cc6fdfb0d`, which is not assumed merged.
Use this same candidate SHA for the matched 2022 and 2025 arms. A separate
manual test of b9953709 is useful history, but is not the matched control for
the additional policy, checks and instrumentation here.

No prototype has passed a remote build, fresh boot or real AL-Go execution
merely because the local checks pass. Do not promote this branch or its images.

## Build contract

The deployed reusable product workflow at `v0.3.0-rc.3` hardcodes 2022. It cannot
honestly build this 2025 path from a recipe-variable change alone. The companion
product branch `feat/windows-2025-image-selector` must first be activated through
an explicitly approved product release/adoption route. Do not hand-edit the
deployment shim, change callers/identities, add triggers here, or dispatch the
disabled classic lane.

After that activation, the existing deployment BuildImage caller uses:

| Deployment variable | Control A | Treatment B | Separate treatment C |
|---|---|---|---|
| `VM_RUNNER_IMAGE_REF` | exact candidate SHA | same exact SHA | same exact SHA |
| `VM_RUNNER_IMAGE_OS` | `win22` (also default) | `win25` | `win25` |
| `VM_RUNNER_BC_GENERIC_IMAGE` | empty | empty | recorded immutable LTSC2025 reference |
| Gallery definition | configured ordinary 2022 definition | `2025-Datacenter-ALGo-Prototype-V1` | same prototype definition |

Both paths require a 256-GiB disk and preserve process isolation, bake/smoke,
artifact/action caches, required tooling, provisioning order, reboots and waits.
The product passes disk size explicitly; the templates reject an unintended
OS/disk contract. Upstream win25's 150-GiB default remains unchanged.

The toolsets select the same immutable LTSC2022 reference:

```text
mcr.microsoft.com/businesscentral@sha256:ca688c497bc9189a9936c39e24cbcc55626f495d9dc1978a49e03300953835d2
```

The separately observed LTSC2025 reference is:

```text
mcr.microsoft.com/businesscentral@sha256:c9d3ecbbd5684b66a5885a31edfdb8a79787dfd590569a429fe55d156ea39b1a
```

Re-query registry manifests/configurations when testing and record actual
helper/action/runtime versions. Do not pin BcContainerHelper. The persisted
machine helper configuration aligns generic selection and process defaults;
explicit caller overrides can still take precedence, so actual job container
inspection remains mandatory. Supported experimental process pairs are host
20348/base 20348, host 26100/base 20348 and host 26100/base 26100. See Microsoft's
[container compatibility matrix](https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/version-compatibility).

## Deliberate differences and costs

- A fork-owned Docker installer performs the configured generic pull and tests
  on both hosts; it does not inherit the upstream win25 pull skip. Readiness is
  conditional, with no additional healthy-path sleep.
- The minimal feature suite retains all previous checks except the WSL2 runtime
  assertion. This recipe installs no WSL2 runtime/distribution, and B4ms lacks
  nested virtualization. Optional-feature and WSL executable checks remain.
- Both arms omit optional win25 LZX compaction. It would be a separate CPU/IO
  treatment. Normal cleanup and every protected cache remain.
- The historical KB5034439 exclusion applies only to its 2022 host family.
  Required update failure detection is retained. CBS/WU reboot-required markers
  block BC bake; no reboot or required check is skipped.
- Sysprep must run through an administrator WinRM account, never SYSTEM. Process
  completion is bounded at 15 minutes plus a five-minute image-state deadline;
  nonzero exit/timeout fails capture. Successful diagnostics are exported after
  generalization without booting the generalized builder again. On a failure,
  inspect Packer's error/stage output and retained guest diagnostics before
  cleanup where possible; a failed Sysprep may prevent the subsequent download.
- Added checks, telemetry, report fields and an extra evidence download cost
  time that must be measured. No bake or CI/CD speed improvement is claimed.

## Local checks

Run from the recipe root under Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File images.CI/windows/Test-Windows2025Prototype-ALGo.ps1
python images.CI/windows/Test-Windows2025Recipe.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File images.CI/windows/Test-ToolsetResolvers.ps1 -ToolsetPath images/windows/toolsets/toolset-2025-algo.json
```

Also fully evaluate both selected HCL paths with Packer 1.16.2 and the recorded
Azure plugin, actual placeholder variable values and `os_disk_size_gb=256`.
Syntax-only validation does not qualify. Actual Azure/WinRM/Sysprep/container
behavior still requires the sequential image builds.

## Operator-owned remote execution

Wait for every active/queued build across all branches to finish, including
publication, verification and cleanup. Check actual build-RG contents and do
not cancel another run or use a branch to bypass its concurrency group.

Before each selection, save repository and image-build environment variable
values and `updated_at`, exact remote candidate SHA, active/queued runs, build-RG
inventory and current VMSS image pin. Set/read back exact SHA, then dispatch the
existing deployment `main` BuildImage with `skip_bc_cache=false`. Verify actual
checkout/provenance and output, not the caller's workflow headSha. Publish only
to the intended V1 definition, excluded from latest; verify replication and
cleanup. Restore only owned selections, after the whole workflow/cleanup, when
both value and metadata still match and no newer operator instruction exists.

Create the dedicated generalized Windows/x64/V1 2025 definition only in MPN,
under an explicit experiment ownership tag. Keep all active VMSS settings,
capacity, image pins and LIVE subscription resources untouched.

## Fresh boot and real AL-Go gates

Use fresh, isolated B4ms VMs with 256-GiB StandardSSD_LRS/ReadWrite disks, an
experiment-owned network/resource group, and no pool bootstrap/registration.
Record resource IDs/tags before changes and preserve diagnostic evidence before
deleting only resources owned by this experiment. Verify the Azure instance
view's actual V1 generation in addition to guest BIOS checks.

Copy and run `images.CI/windows/Test-FreshImage-ALGo.ps1` on each new VM, passing
the exact gallery-version ID and expected host build (20348 or 26100). It checks
MPN/image/size provenance, Desktop Experience, activation, Docker API/runtime,
immutable cache identity, marker/restart/process policy, and three sustained
healthy BC samples. It never recreates/starts containers. These checks are not
authenticated BC or real AL-Go success.

`images.CI/windows/New-IsolatedALGoFixture.py` prepares local manual-only files
for a separate controlled test repository. It creates no remote repository,
registration or run. Supply the actual exact artifact URL from image metadata
and one unique `algo-prototype-*` runner label. Register only a repo-scoped
runner with `--no-default-labels` and that label; never normal pool labels.

Run baseline -> version-upgrade -> controlled negative -> deliberately different
artifact/country miss. The upgrade fixture requires its upgrade-code marker;
the negative fixture deliberately fails an AL assertion. Keep CodeCop/UICop,
required tests and upgrade checks enabled. The container override preserves
normal AL-Go parameters, enforces/inspects process isolation, checks exact
cache-hit identity, and calls an authenticated BC companies API using in-memory
job credentials. It never emits those credentials. Compilation, publication,
test results, analyzer execution and upgrade logs must be inspected separately.

The small fixture is a first integration gate; it does not replace the rollout
matrix of representative multi-app/test-heavy workloads, supported artifacts,
countries and BCPT where applicable. A deliberate miss needs a verified real
artifact URL; local fixture generation alone proves no artifact availability.

Measure bake, updates/reboots, image construction, smoke, cleanup, Sysprep,
capture, publication, cold boot, container initialization and total AL-Go time
separately. Record artifact/platform/helper/action/runtime versions, VM/disk
settings, initial/ending CPU credits and CPU/disk/network observations. Start
with correctness and a small paired sample; no causal or percentile claim from
one run. Gen2/Trusted Launch/Flexible remain a separate infrastructure project.
