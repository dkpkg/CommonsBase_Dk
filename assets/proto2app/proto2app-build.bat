@echo off
setlocal EnableExtensions
@REM Build the protoapp dune executable against a staged protolib dependency.
@REM %1=vswhere.exe  %2=arch (x64/x86)  %3=OCAMLPATH (abs dir holding protolib)  %4=output dir
set "VSW=%~1"
set "VSDIR="
for /f "usebackq delims=" %%I in (`"%VSW%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%I"
if not defined VSDIR ( echo Error: no Visual Studio with VC tools found 1>&2 & exit /b 1 )
call "%VSDIR%\VC\Auxiliary\Build\vcvarsall.bat" %~2 >nul || ( echo Error: vcvarsall %~2 failed 1>&2 & exit /b 1 )
cd s || ( echo Error: missing staged source directory s 1>&2 & exit /b 1 )
set "OCAMLPATH=%~3"
dune build protoapp.exe || exit /b 1
copy /y _build\default\protoapp.exe "%~4\protoapp.exe" >nul || ( echo Error: copy failed 1>&2 & exit /b 1 )
exit /b 0
