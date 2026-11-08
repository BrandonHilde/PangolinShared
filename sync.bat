@echo off
rem Copies the shared sources into the app's src folder as shared_*.odin (one Odin package per folder).
rem It finds the app from its own location (this repo is the app's libs\shared), so it can be run from any folder;
rem build.bat runs it. The copies are ignored by git: edit them in this repo.
setlocal
set "shared=%~dp0"
for %%d in ("%shared%..") do set "libs=%%~fd"
for %%d in ("%shared%..\..") do set "app=%%~fd"
for %%d in ("%libs%") do set "libsname=%%~nxd"
if /i not "%libsname%"=="libs" goto notapp
if not exist "%app%\src\" goto notapp
del /q "%app%\src\shared_*.odin" 2>nul
rem The wildcard is unquoted (from inside the folder) so it matches even where a quoted one would not, such as Wine
pushd "%shared%src"
for %%f in (*.odin) do copy /Y "%%f" "%app%\src\shared_%%f" >nul
popd
exit /b 0

:notapp
echo sync.bat copies into an app: run the copy at libs\shared\sync.bat inside a Pangolin app, not this repo's own. 1>&2
exit /b 1
