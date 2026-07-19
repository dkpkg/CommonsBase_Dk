@echo off
setlocal EnableExtensions
@REM Activate the MSVC environment, then dune-build dk0 (Shell.exe) under it.
@REM DkML's OCaml is MSVC, so the compiler/linker need an active vcvars.
@REM %1=vswhere.exe  %2=arch (x64/x86)
set "VSW=%~1"
set "VSDIR="
for /f "usebackq delims=" %%I in (`"%VSW%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%I"
if not defined VSDIR ( echo Error: no Visual Studio with VC tools found 1>&2 & exit /b 1 )
call "%VSDIR%\VC\Auxiliary\Build\vcvarsall.bat" %~2 >nul || ( echo Error: vcvarsall %~2 failed 1>&2 & exit /b 1 )
cd s || ( echo Error: missing staged source directory s 1>&2 & exit /b 1 )
dune build --profile=release src/DkZero_Exec/Shell.exe
exit /b %ERRORLEVEL%
