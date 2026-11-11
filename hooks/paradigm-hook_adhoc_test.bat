@echo off
REM ============================================================================
REM Script Name:     paradigm-hook.bat
REM Description:     DBmaestro hook script that triggers PowerShell automation
REM                  for Azure DevOps pipeline execution
REM
REM Version:         1.0.1
REM Author:          DBmaestro
REM Creation Date:   2026-02-05
REM Last Modified:   2026-02-05
REM
REM Change Log:
REM   1.0.0 (2026-02-05) - Initial version with logging and error handling
REM
REM Usage:
REM   paradigm-hook.bat "path\to\package.json"
REM
REM Parameters:
REM   %1 - Path to JSON file containing package details
REM ============================================================================

:: Create logs folder if it doesn't exist
if not exist "%~dp0logs" mkdir "%~dp0logs"

:: Set log file path
set LOGFILE=%~dp0logs\%~n0.log

:: Log timestamp and input
echo. >> "%LOGFILE%"
echo === %date% %time% === >> "%LOGFILE%"
echo Input: %1 >> "%LOGFILE%"

REM echo %1

set x=%1

set x=%x:"=%

echo Launching PowerShell script with parameter: %x% 

echo Launching PowerShell script with parameter: %x% >> "%LOGFILE%"

Powershell -ExecutionPolicy Bypass -File "%~dp0paradigm-hook_adhoc_test.ps1" "%x%"  2>&1

if %ERRORLEVEL% neq 0 (
    echo Script failed with exit code %ERRORLEVEL% >> "%LOGFILE%"
    exit /b %ERRORLEVEL%
)

echo Script completed >> "%LOGFILE%"