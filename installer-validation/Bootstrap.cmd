@echo off
echo Validation bootstrap started at %DATE% %TIME%>C:\ValidationResults\bootstrap-started.txt
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ValidationHarness\Run-Scenario.ps1 -Config C:\ValidationConfig\scenario.json -Output C:\ValidationResults >C:\ValidationResults\bootstrap.log 2>&1
echo %ERRORLEVEL%>C:\ValidationResults\bootstrap-exit-code.txt
