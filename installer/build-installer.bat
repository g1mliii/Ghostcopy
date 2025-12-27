@echo off
REM GhostCopy Installer Build Script
REM Builds the Flutter app and creates the Inno Setup installer

echo ============================================
echo   GhostCopy Installer Build Script
echo ============================================
echo.

REM Step 1: Clean previous build
echo [1/4] Cleaning previous build...
call flutter clean
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Flutter clean failed
    exit /b 1
)

REM Step 2: Get dependencies
echo.
echo [2/4] Getting dependencies...
call flutter pub get
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Flutter pub get failed
    exit /b 1
)

REM Step 3: Build Windows release
echo.
echo [3/4] Building Windows release...
call flutter build windows --release
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Flutter build failed
    exit /b 1
)

REM Step 4: Compile Inno Setup installer
echo.
echo [4/4] Compiling Inno Setup installer...

REM Try common Inno Setup installation paths
set INNO_PATH=""
if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" (
    set INNO_PATH="C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
) else if exist "C:\Program Files\Inno Setup 6\ISCC.exe" (
    set INNO_PATH="C:\Program Files\Inno Setup 6\ISCC.exe"
) else (
    echo ERROR: Inno Setup not found!
    echo Please install from: https://jrsoftware.org/isdl.php
    exit /b 1
)

REM Compile the installer
%INNO_PATH% installer\ghostcopy.iss
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Inno Setup compilation failed
    exit /b 1
)

echo.
echo ============================================
echo   Build Complete!
echo ============================================
echo.
echo Installer created at:
echo   build\installer\ghostcopy-setup-1.0.0.exe
echo.
echo File size:
dir build\installer\ghostcopy-setup-1.0.0.exe | find "ghostcopy-setup"
echo.
pause
