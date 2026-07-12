@echo off
if exist lua54.dll goto run
for /f "delims=" %%i in ('where odin') do set "ODIN_BIN=%%i"
for %%i in ("%ODIN_BIN%") do set "ODIN_DIR=%%~dpi"
copy /Y "%ODIN_DIR%vendor\lua\5.4\windows\lua54.dll" lua54.dll >nul
:run
odin run . -debug
