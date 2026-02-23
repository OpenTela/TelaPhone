@echo off
chcp 65001 >nul
echo.
echo ==========================================
echo   Building Release APK...
echo ==========================================
echo.

flutter build apk --release

if %ERRORLEVEL% neq 0 (
    echo.
    echo [X] Build failed!
    pause
    exit /b 1
)

echo.
echo ==========================================
echo   [OK] Build complete!
echo ==========================================
echo.
echo APK: %CD%\build\app\outputs\flutter-apk\app-release.apk
echo.

pause
