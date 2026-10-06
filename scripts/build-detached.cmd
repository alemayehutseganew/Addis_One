@echo off
REM Detached build: the sandbox tears down a foreground command's process tree
REM after roughly a minute, and a cold TypeScript compile of the backend takes
REM longer than that. Launching this with Start-Process (no -Wait) puts the
REM compiler in a separate process group, so it survives and the caller can poll
REM the marker file instead.
cd /d C:\Users\alexo\Desktop\File\Code\AddisTransport\backend
echo START %TIME% > "%TEMP%\addis_build.txt"
del /q tsconfig.tsbuildinfo 2>nul
npx tsc -p tsconfig.build.json >> "%TEMP%\addis_build.txt" 2>&1
echo EXIT=%ERRORLEVEL% >> "%TEMP%\addis_build.txt"
if exist dist\main.js (
  findstr /C:"assertValidConfig" /C:"SwaggerModule" dist\main.js >nul && echo HAS_NEW_CODE=YES >> "%TEMP%\addis_build.txt" || echo HAS_NEW_CODE=NO >> "%TEMP%\addis_build.txt"
  if exist dist\modules\auth\policy.js (echo POLICY_JS=YES >> "%TEMP%\addis_build.txt") else (echo POLICY_JS=NO >> "%TEMP%\addis_build.txt")
  if exist dist\config\validate-env.js (echo VALIDATE_ENV_JS=YES >> "%TEMP%\addis_build.txt") else (echo VALIDATE_ENV_JS=NO >> "%TEMP%\addis_build.txt")
) else (
  echo MAIN_JS=MISSING >> "%TEMP%\addis_build.txt"
)
echo DONE >> "%TEMP%\addis_build.txt"