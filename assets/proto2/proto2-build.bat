@echo off
setlocal EnableExtensions
@REM Build the protolib dune package under MSVC (DkML's OCaml is MSVC).
@REM %1=vswhere.exe  %2=arch (x64/x86)  %3=absolute install prefix
set "VSW=%~1"
set "VSDIR="
for /f "usebackq delims=" %%I in (`"%VSW%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%I"
if not defined VSDIR ( echo Error: no Visual Studio with VC tools found 1>&2 & exit /b 1 )
call "%VSDIR%\VC\Auxiliary\Build\vcvarsall.bat" %~2 >nul || ( echo Error: vcvarsall %~2 failed 1>&2 & exit /b 1 )
cd s || ( echo Error: missing staged source directory s 1>&2 & exit /b 1 )
dune build -p protolib @install || exit /b 1
dune install --prefix "%~3" protolib || exit /b 1
exit /b 0
