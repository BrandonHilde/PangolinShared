@echo off
rem Copies the shared sources into the app's src folder as shared_*.odin (one Odin package per folder).
rem Run from the app's root; build.bat does. The copies are ignored by git: edit them in this repo.
del /q src\shared_*.odin 2>nul
for %%f in (libs\shared\src\*.odin) do copy /Y "%%f" "src\shared_%%~nxf" >nul
