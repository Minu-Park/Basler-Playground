# Windows Installer Validation

This is a standalone Windows Sandbox harness for repeatable Qt Installer Framework validation. It never installs Playground on the host.

## Scenarios

- `CleanInstall`: install a candidate offline installer, verify IFW state and Windows registered size, smoke-start Playground, and purge it.
- `ComponentUpdate`: install a baseline, seed a stale 5 MiB Windows registered size, invoke MaintenanceTool against a candidate raw repository, verify every repository component version and repaired registered size, require installer-only prerequisites to stay out of the repository, smoke-start Playground, require a no-update result, and purge it.
- `ApplicationUpdate`: replace only the installed baseline executable with a beta-channel test probe, fetch local metadata through `UpdateChecker`, download and SHA256-verify a repository ZIP, traverse the Install Update callback, and apply the ordered candidate repository.
- `WindowsSdkDiagnostic`: run only the installer-only Windows SDK component with a 20-minute guard and preserve Visual Studio, Windows SDK, and CAPI2 trust logs for failure analysis.
- `FullFallback`: reserved for the verified backup/purge/reinstall bootstrap. The harness rejects this scenario until that workflow is implemented.

## Run

Run the complete application-path gate from the Basler-Playground wrapper checkout:

```powershell
.\installer-validation\Invoke-ApplicationUpdateValidation.ps1 `
  -PlaygroundRoot C:\Users\minwoo\Documents\Playground-ifw-components `
  -CloseExistingSandbox
```

The wrapper resolves the latest stable tag and defaults to the next patch `beta.1`. It builds a same-version beta-channel probe with test hooks, packages the candidate with hooks disabled, verifies display and IFW versions separately, runs `ApplicationUpdate`, and restores production updater options. Pass `-CandidateVersion MAJOR.MINOR.PATCH-beta.N` or a final stable version to select another candidate.

Run only the IFW engine layer when a candidate repository already exists:

```powershell
.\installer-validation\Invoke-Validation.ps1 `
  -Scenario ComponentUpdate `
  -CandidateRepository C:\artifacts\repository
```

When `BaselineInstaller` is omitted, the harness downloads the latest stable Windows installer once through `gh` and reuses it from `build/installer-validation/cache/<tag>/`. The Sandbox closes itself and the host command fails or succeeds from `result.json`, so no per-version validation session has to be created manually.

The host script generates a `.wsb` file under `build/installer-validation/`, maps inputs read-only, launches Windows Sandbox, and writes results to the generated run directory. Approve no host installation prompts; installation happens inside the disposable Sandbox.

The harness refuses to start while another Sandbox session is open. Automated runs may pass `-CloseExistingSandbox`; interactive runs should close an existing session explicitly to avoid losing disposable work.

Automated functional tests install under the Sandbox user profile, disable default optional components, and explicitly select the application component. Message prompts are rejected so optional MSVC/SDK prerequisite installers cannot block the updater test. Program Files elevation remains a separate final UAC acceptance gate.

`ComponentUpdate` validates IFW repository migration and MaintenanceTool behavior. It does not validate Playground's `latest.json` fetch, update decision, update dialog, or updater launch. The release gate still requires a strictly newer candidate exercised through the installed application path.

`ApplicationUpdate` compiles `PLAYGROUND_ENABLE_UPDATE_TEST_HOOKS=ON`. The hook accepts a local metadata URL, automatically invokes the existing Install Update callback, and records the detached MaintenanceTool exit code. Production configuration defaults this option to `OFF`; never publish validation artifacts, and always rebuild through the release wrapper after testing.

Use `-GenerateOnly` to inspect the generated configuration without launching Sandbox. Use `-KeepInstalled` only while debugging a running Sandbox.

Run the SDK-only diagnostic with:

```powershell
.\installer-validation\Invoke-Validation.ps1 `
  -Scenario WindowsSdkDiagnostic `
  -CloseExistingSandbox
```

On the Windows 11 Sandbox 26100 image, the current Microsoft component ID resolves correctly and its nested installer plans 87 MSI packages. The MSI payloads that start complete successfully, but each `msiexec.exe` Software Restriction Policy `WinVerifyTrust` call takes about 120 seconds even though the Microsoft Authenticode chain returns success. The Sandbox starts without a pending reboot and its Defender service is unavailable, so neither an invalid component ID, a reboot requirement, nor Defender real-time scanning explains the delay. This makes the full SDK component unsuitable as a required automated Sandbox gate; keep it installer-only and optional, and use the captured `capi2-operational.evtx` plus `visual-studio-logs` when the Microsoft/Sandbox behavior is retested.

## Acceptance

- `result.json` reports `passed: true`.
- `components-after.json` exactly matches the component names and versions in candidate `Updates.xml`; no legacy component may remain.
- `application-version-after.txt` matches the canonical candidate display version; `components-after.json` retains the ordered IFW version.
- `registered-size-after.json` keeps Windows `EstimatedSize` within 10% of the installed file total.
- Qt and pylon runtime files retain their required plugin/subdirectory layout, including `platforms/qwindows.dll`, `pylonCXP/bin/ProducerCXP.cti`, and `stereo-mini/ProducerBaslerStereoMini.cti`.
- `MSVCBuildTools`, `WindowsSDK`, and `DevelopmentPrerequisitesPayload` are absent from the update repository.
- Playground reaches its real main window; an error dialog or merely surviving process is not a successful smoke test.
- MaintenanceTool reports no update after the candidate is applied.

## Office Review

1. Run the complete application-path command above and open the newest `build/installer-validation/*-ApplicationUpdate/results/result.json` in this wrapper checkout.
2. Require `passed: true`, MaintenanceTool exit code `0`, all expected component versions, the candidate application version, a successful smoke window, and `no updates available` in `check-updates.log`.
3. Review the parent and DeployKit diffs, then compare the code changes with `docs/WINDOWS_IFW_UPDATE_PIPELINE.md`; validation hooks must remain disabled by default and installer-only prerequisites must not enter `Updates.xml`.
4. Perform one final installed UI check against a controlled HTTPS endpoint before publishing; the automated local-file hook proves the application decision and launch path but not public hosting, TLS, or the visible UAC interaction.

## Real Host HTTPS Gate

Run the isolated host test without modifying the normal Playground installation:

```powershell
.\installer-validation\Invoke-HostUpdateValidation.ps1 `
  -PlaygroundRoot C:\Users\minwoo\Documents\Playground-ifw-components
```

It installs the stable baseline under `%LOCALAPPDATA%\BaslerPlaygroundUpdaterValidation`, reads the public beta-channel metadata, verifies the repository over HTTPS, checks the exact component set and canonical executable version, smoke-starts, requires no remaining updates, and purges the isolated installation. It refuses to reuse an existing validation directory. This host gate does not prove Program Files elevation; the visible UAC test remains manual.

For the final visible Program Files and UAC gate, run:

```powershell
.\installer-validation\Start-ProgramFilesUpdateValidation.ps1
```

Approve the fixture-install UAC prompt, then choose **Help > Check for Updates... > Install Update** and approve the updater UAC prompt. Confirm the beta-channel version, then remove only the isolated fixture with:

```powershell
.\installer-validation\Start-ProgramFilesUpdateValidation.ps1 -Cleanup
```
